import CoreBluetooth
import Foundation
import Observation

public enum RingStatus: Equatable, Sendable {
    case disconnected
    case scanning
    case connecting
    case connected(String)
    case failed(String)
}

/// A direct BLE connection from the phone to a ring. Separate from `GlassesLink` because the
/// ring is its own peripheral; when the ring is linked to the glasses, its gestures also arrive
/// through `GlassesLink.inputs()`.
@MainActor
public protocol RingLink: AnyObject, Observable {
    var status: RingStatus { get }
    /// Scan for a ring and connect to the first one found.
    func connect()
    func disconnect()
    func inputs() -> AsyncStream<InputEvent>
}

/// Gesture notifications sent by the R1 straight to the phone: `FF <type> <param>`.
/// Layout from MentraOS `controllers/R1.swift` (Apache-2.0).
public enum R1Gesture {
    public static func parse(_ bytes: [UInt8]) -> InputEvent.Gesture? {
        guard let start = bytes.firstIndex(of: 0xFF), start + 2 < bytes.count else { return nil }
        let type = bytes[start + 1], param = bytes[start + 2]
        switch type {
        case 0x03: return .longPress
        case 0x04: return param == 0x01 ? .tap : param == 0x02 ? .doubleTap : nil
        case 0x05: return param < 0x80 ? .scrollUp : .scrollDown
        default: return nil
        }
    }
}

/// `RingLink` for the Even Realities R1, over CoreBluetooth. Read-only: it subscribes and
/// listens, and never writes to the ring, so it can't disturb the ring's link to the glasses.
///
/// The ring advertises as `EVEN R1_<MAC tail>` with service `BAE80001-…` (g2-kit `ble/ring.ts`,
/// MentraOS `R1.swift`).
@MainActor
@Observable
public final class R1Link: NSObject, RingLink {
    public private(set) var status: RingStatus = .disconnected

    static let service = CBUUID(string: "BAE80001-4F05-4503-8E65-3AF1F7329D1F")
    private static let ringIDKey = "LottiKit.R1Link.ringID"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var ring: CBPeripheral?
    @ObservationIgnored private var wantsConnection = false
    @ObservationIgnored private var scanTimeout: Task<Void, Never>?
    @ObservationIgnored private let inputBroadcast = Broadcast<InputEvent>()
    @ObservationIgnored private var deduplicator = InputDeduplicator()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    public func connect() {
        guard status == .disconnected || isFailed else { return }
        wantsConnection = true
        status = .scanning
        if central.state == .poweredOn { start() }
    }

    public func disconnect() {
        wantsConnection = false
        stopScan()
        if let ring { central.cancelPeripheralConnection(ring) }
        ring = nil
        status = .disconnected
    }

    public func inputs() -> AsyncStream<InputEvent> {
        inputBroadcast.stream()
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private func start() {
        // A ring linked to the glasses may not advertise, but may already be connected to the
        // phone at the system level.
        for p in central.retrieveConnectedPeripherals(withServices: [Self.service]) {
            log("already connected to phone: \(p.name ?? "?") (\(p.identifier))")
        }
        if let id = defaults.string(forKey: Self.ringIDKey).flatMap(UUID.init(uuidString:)),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            log("known ring \(known.name ?? "?") (\(id)), state \(known.state.rawValue)")
        }
        log("scanning for a ring…")
        central.scanForPeripherals(withServices: nil)
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, self.status == .scanning else { return }
            self.stopScan()
            self.log("no ring advertised within 20 s")
            self.status = .failed("No ring found. It may be connected to the glasses.")
        }
    }

    private func stopScan() {
        scanTimeout?.cancel()
        scanTimeout = nil
        if central.isScanning { central.stopScan() }
    }

    private func log(_ message: String) {
        print("[R1] \(message)")
    }
}

extension R1Link: @MainActor CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, wantsConnection, status == .scanning { start() }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        guard let name, name.uppercased().contains("R1_"), status == .scanning else { return }
        let mfg = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map { hex([UInt8]($0)) }
        log("found \(name) (\(peripheral.identifier)) rssi \(RSSI) mfg \(mfg ?? "none")")
        stopScan()
        ring = peripheral
        peripheral.delegate = self
        status = .connecting
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("did connect \(peripheral.name ?? "?")")
        defaults.set(peripheral.identifier.uuidString, forKey: Self.ringIDKey)
        peripheral.discoverServices(nil)
    }

    public func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        log("failed to connect: \(String(describing: error))")
        ring = nil
        status = .failed(error?.localizedDescription ?? "Could not connect to the ring.")
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        log("disconnected: \(String(describing: error))")
        ring = nil
        if wantsConnection { status = .failed("The ring disconnected.") }
    }
}

extension R1Link: @MainActor CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        log("services: \(services.map(\.uuid.uuidString)) \(error.map { "error \($0)" } ?? "")")
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
        status = .connected(peripheral.name ?? "R1")
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        for c in service.characteristics ?? [] {
            log("char \(c.uuid.uuidString) props 0x\(String(c.properties.rawValue, radix: 16))")
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
            if c.uuid == CBUUID(string: "2A19") { peripheral.readValue(for: c) }  // battery
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?
    ) {
        log("notify \(c.uuid.uuidString): \(error.map { "error \($0)" } ?? "on")")
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        let bytes = [UInt8](c.value ?? Data())
        log("rx \(c.uuid.uuidString.suffix(4)) \(hex(bytes))")
        guard let gesture = R1Gesture.parse(bytes) else { return }
        let input = InputEvent(gesture, from: .ring)
        let isNew = deduplicator.accept(input, at: ProcessInfo.processInfo.systemUptime)
        log("input \(input)\(isNew ? "" : " (repeat, dropped)")")
        if isNew { inputBroadcast.send(input) }
    }
}
