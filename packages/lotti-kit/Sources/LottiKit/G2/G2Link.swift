import CoreBluetooth
import Foundation
import Observation

/// `GlassesLink` for Even Realities G2 glasses, talking to them directly over BLE.
///
/// A G2 is two BLE peripherals, one per arm. Both get connected and authenticated; commands go
/// to the right arm (the "command arm"), which also sends the replies and events.
///
/// Connection sequence (see docs/spikes/s1-ble.md):
/// 1. connect both arms, subscribe to the control notify characteristic
/// 2. auth on sid 0x80 (both arms), make the right arm the command arm, sync the clock
/// 3. session prelude on sid 0x01, then an EvenHub heartbeat every 4 s
/// 4. text: create a text page once (Cmd 0), then update its text (Cmd 5)
@MainActor
@Observable
public final class G2Link: NSObject, GlassesLink {
    public private(set) var status: GlassesStatus = .disconnected
    public private(set) var discovered: [DiscoveredGlasses] = []
    public private(set) var lastGlasses: DiscoveredGlasses?

    // GATT layout. All G2 characteristics share one UUID base.
    static let controlWrite = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E5401")
    static let controlNotify = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E5402")
    /// Services to look for among peripherals that are already connected to the phone, e.g. by the
    /// Even app (they don't advertise). Any match is then filtered by name.
    static let connectedServices = [
        "00002760-08C2-11E1-9073-0E8AC72E0000", "00002760-08C2-11E1-9073-0E8AC72E5450",
        "00002760-08C2-11E1-9073-0E8AC72E6450", "00002760-08C2-11E1-9073-0E8AC72E7450",
        "6E400001-B5A3-F393-E0A9-E50E24DCCA9E", "180A", "180F",
    ].map { CBUUID(string: $0) }

    private static let lastGlassesKey = "LottiKit.G2Link.lastGlasses"
    /// Arm ids seen per pair. The arms advertise intermittently, often not both in one scan, but
    /// iOS can connect to a known id directly and waits until that arm shows up.
    private static let knownArmsKey = "LottiKit.G2Link.knownArms"
    private static let containerID = 1
    private static let containerName = "lotti"  // max 14 characters

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var arms: [G2Side: Arm] = [:]
    @ObservationIgnored private var poweredOnActions: [() -> Void] = []
    @ObservationIgnored private var connectWaiters: [UUID: Waiter<Void>] = [:]
    @ObservationIgnored private var setupWaiters: [UUID: Waiter<Void>] = [:]
    @ObservationIgnored private var replyWaiters: [ReplyKey: Waiter<G2Message>] = [:]
    @ObservationIgnored private var armWaiter: (pairID: String, side: G2Side, waiter: Waiter<UUID>)?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var seq: UInt8 = 0
    @ObservationIgnored private var magic: UInt64 = 100
    @ObservationIgnored private var pageCreated = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        if let data = defaults.data(forKey: Self.lastGlassesKey) {
            lastGlasses = try? JSONDecoder().decode(DiscoveredGlasses.self, from: data)
        }
        // Creating the manager asks for Bluetooth permission on first launch.
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - GlassesLink

    public func startScan() {
        discovered = []
        whenPoweredOn { [self] in
            guard !isBusy else { return }
            status = .scanning
            for peripheral in central.retrieveConnectedPeripherals(withServices: Self.connectedServices) {
                log("already connected to phone: \(peripheral.name ?? "?") (\(peripheral.identifier))")
                record(peripheral, name: peripheral.name, rssi: nil)
            }
            central.scanForPeripherals(withServices: nil)
        }
    }

    public func stopScan() {
        if central.isScanning { central.stopScan() }
        if status == .scanning { status = .disconnected }
    }

    public func connect(_ glasses: DiscoveredGlasses) async {
        guard !isBusy else { return }
        guard glasses.leftArm != nil || glasses.rightArm != nil else {
            status = .failed(GlassesLinkError.incompleteGlasses.localizedDescription)
            return
        }
        stopScan()
        status = .connecting("Waiting for Bluetooth…")
        await poweredOn()
        do {
            // Connect the arm we know first; the other one may only show up after that.
            var glasses = glasses
            var connected: [G2Side: Arm] = [:]
            let order: [G2Side] = glasses.rightArm == nil ? [.left, .right] : [.right, .left]
            for side in order {
                if glasses.armID(side) == nil {
                    status = .connecting("Looking for the \(side) arm…")
                    glasses.setArmID(try await findArm(pairID: glasses.id, side: side), side)
                }
                status = .connecting("Connecting \(side) arm…")
                connected[side] = try await connectArm(glasses.armID(side)!, side: side)
            }
            status = .connecting("Authenticating…")
            try await handshake(right: connected[.right]!, left: connected[.left]!)
            remember(glasses)
            status = .connected(glasses)
            log("connected to \(glasses.name)")
        } catch {
            log("connect failed: \(error)")
            stopArmScan()
            tearDown()
            status = .failed(error.localizedDescription)
        }
    }

    /// Scans until the given arm of a pair advertises.
    private func findArm(pairID: String, side: G2Side, seconds: Double = 30) async throws -> UUID {
        defer { stopArmScan() }
        return try await wait("looking for the \(side) arm", seconds: seconds) { waiter in
            armWaiter = (pairID, side, waiter)
            central.scanForPeripherals(withServices: nil)
        }
    }

    private func stopArmScan() {
        armWaiter = nil
        if central.isScanning, status != .scanning { central.stopScan() }
    }

    public func disconnect() {
        tearDown()
        status = .disconnected
    }

    public func showText(_ text: String) async throws {
        guard status.isConnected, let right = arms[.right] else { throw GlassesLinkError.notConnected }
        let m = nextMagic()
        let payload = pageCreated
            ? G2Payload.textUpdate(magic: m, containerID: Self.containerID, containerName: Self.containerName, text: text)
            : G2Payload.createTextPage(magic: m, containerID: Self.containerID, containerName: Self.containerName, text: text)
        // A page can only be created once per session, even if its ack got lost.
        let creating = !pageCreated
        pageCreated = true
        _ = try await request(payload, sid: G2Service.evenHub, flag: G2Flag.request, magic: m, to: right,
                              step: creating ? "creating the text page" : "updating the text")
    }

    // MARK: - Connection steps

    private var isBusy: Bool {
        if case .connecting = status { return true }
        return status.isConnected
    }

    private func connectArm(_ id: UUID, side: G2Side) async throws -> Arm {
        guard let peripheral = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            throw GlassesLinkError.incompleteGlasses
        }
        peripherals[id] = peripheral
        peripheral.delegate = self
        let arm = Arm(side: side, peripheral: peripheral)
        arms[side] = arm

        if peripheral.state != .connected {
            try await wait("connecting the \(side) arm", seconds: 45) { waiter in
                connectWaiters[id] = waiter
                central.connect(peripheral)
            }
        }
        // Long timeout: iOS may show a pairing prompt when we subscribe.
        try await wait("setting up the \(side) arm", seconds: 40) { waiter in
            setupWaiters[id] = waiter
            peripheral.discoverServices(nil)
        }
        log("\(side) arm ready, max write \(peripheral.maximumWriteValueLength(for: .withoutResponse)) bytes")
        return arm
    }

    private func handshake(right: Arm, left: Arm) async throws {
        // Auth both arms. Only the right arm's reply is required; the left arm is often silent.
        let leftAuth = nextMagic()
        let leftReply = try? await request(G2Payload.auth(magic: leftAuth), sid: G2Service.deviceConfig,
                                           flag: G2Flag.deviceConfig, magic: leftAuth, to: left,
                                           step: "authenticating the left arm", seconds: 1.5)
        log("left auth reply: \(leftReply.map { hex($0.payload) } ?? "none")")

        let rightAuth = nextMagic()
        let rightReply = try await request(G2Payload.auth(magic: rightAuth), sid: G2Service.deviceConfig,
                                           flag: G2Flag.deviceConfig, magic: rightAuth, to: right,
                                           step: "authenticating the right arm", seconds: 5)
        log("right auth reply: \(hex(rightReply.payload))")

        status = .connecting("Starting session…")
        await send(G2Payload.rightArmIsCommandArm(magic: nextMagic()), sid: G2Service.deviceConfig,
                   flag: G2Flag.deviceConfig, to: right)
        let now = Date()
        for arm in [left, right] {
            await send(G2Payload.timeSync(magic: nextMagic(), date: now), sid: G2Service.deviceConfig,
                       flag: G2Flag.deviceConfig, to: arm)
        }

        let prelude = try? await request(G2Payload.prelude(), sid: G2Service.appLaunch, flag: G2Flag.request,
                                         magic: G2Payload.preludeMagic, to: right, step: "session prelude", seconds: 3)
        log("prelude reply: \(prelude.map { hex($0.payload) } ?? "none")")

        pageCreated = false
        startHeartbeat()
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled, let right = self.arms[.right] else { return }
                await self.send(G2Payload.heartbeat(magic: self.nextMagic()), sid: G2Service.evenHub,
                                flag: G2Flag.request, to: right)
            }
        }
    }

    private func tearDown() {
        heartbeat?.cancel()
        heartbeat = nil
        pageCreated = false
        let current = arms.values
        arms = [:]
        for arm in current {
            arm.failPendingWrites()
            fail(arm.peripheral.identifier, GlassesLinkError.notConnected)
            central.cancelPeripheralConnection(arm.peripheral)
        }
        for waiter in replyWaiters.values { waiter.resume(.failure(GlassesLinkError.notConnected)) }
        replyWaiters = [:]
    }

    private func fail(_ id: UUID, _ error: Error) {
        connectWaiters.removeValue(forKey: id)?.resume(.failure(error))
        setupWaiters.removeValue(forKey: id)?.resume(.failure(error))
    }

    private func remember(_ glasses: DiscoveredGlasses) {
        var stored = glasses
        stored.rssi = nil
        lastGlasses = stored
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.lastGlassesKey)
    }

    // MARK: - Sending

    private func nextSeq() -> UInt8 {
        seq &+= 1
        return seq
    }

    /// Request ids. The firmware only reliably acks magics below 256; 156 is the prelude's.
    private func nextMagic() -> UInt64 {
        magic = magic >= 255 ? 100 : magic + 1
        if magic == G2Payload.preludeMagic { magic += 1 }
        return magic
    }

    /// Frames `payload` and writes it to `arm`. Messages to one arm never interleave: the
    /// firmware reassembles by seq, and a stray packet in between corrupts a long message.
    private func send(_ payload: [UInt8], sid: UInt8, flag: UInt8, to arm: Arm) async {
        let size = arm.peripheral.maximumWriteValueLength(for: .withoutResponse)
        let packets = G2Frame.encode(payload: payload, sid: sid, flag: flag, seq: nextSeq(), maxPacketSize: size)
        let previous = arm.writeTail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            for (index, packet) in packets.enumerated() {
                if index > 0 { try? await Task.sleep(for: .milliseconds(20)) }
                await arm.waitUntilWritable()
                guard let characteristic = arm.write, arm.peripheral.state == .connected else { return }
                arm.peripheral.writeValue(Data(packet), for: characteristic, type: .withoutResponse)
                self?.log("tx \(arm.side) \(hex(packet))")
            }
        }
        arm.writeTail = task
        await task.value
    }

    /// Sends and waits for the reply that echoes `magic` on the same service.
    private func request(
        _ payload: [UInt8], sid: UInt8, flag: UInt8, magic: UInt64, to arm: Arm, step: String,
        seconds: Double = 3
    ) async throws -> G2Message {
        let key = ReplyKey(side: arm.side, sid: sid, magic: magic)
        defer { replyWaiters[key] = nil }
        return try await wait(step, seconds: seconds) { waiter in
            replyWaiters[key] = waiter
            Task { await self.send(payload, sid: sid, flag: flag, to: arm) }
        }
    }

    private func wait<T: Sendable>(_ step: String, seconds: Double, _ start: (Waiter<T>) -> Void) async throws -> T {
        let waiter = Waiter<T>()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(seconds))
            waiter.resume(.failure(GlassesLinkError.timeout(step)))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiter.continuation = continuation
            start(waiter)
        }
    }

    // MARK: - Scanning helpers

    private func whenPoweredOn(_ action: @escaping () -> Void) {
        if central.state == .poweredOn { action() } else { poweredOnActions.append(action) }
    }

    private func poweredOn() async {
        await withCheckedContinuation { continuation in
            whenPoweredOn { continuation.resume() }
        }
    }

    private func record(_ peripheral: CBPeripheral, name: String?, rssi: Int?) {
        guard let parsed = G2Name.parse(name ?? peripheral.name) else { return }
        peripherals[peripheral.identifier] = peripheral
        var known = (defaults.data(forKey: Self.knownArmsKey))
            .flatMap { try? JSONDecoder().decode([String: DiscoveredGlasses].self, from: $0) } ?? [:]
        var glasses = discovered.first { $0.id == parsed.pairID }
            ?? known[parsed.pairID]
            ?? DiscoveredGlasses(id: parsed.pairID, name: "Even G2 · \(parsed.pairID)")
        glasses.rssi = nil
        switch parsed.side {
        case .left: glasses.leftArm = peripheral.identifier
        case .right: glasses.rightArm = peripheral.identifier
        }
        if known[parsed.pairID] != glasses {
            known[parsed.pairID] = glasses
            defaults.set(try? JSONEncoder().encode(known), forKey: Self.knownArmsKey)
        }
        if let w = armWaiter, w.pairID == parsed.pairID, w.side == parsed.side {
            armWaiter = nil
            w.waiter.resume(.success(peripheral.identifier))
        }
        if let rssi { glasses.rssi = max(glasses.rssi ?? rssi, rssi) }
        if let index = discovered.firstIndex(where: { $0.id == glasses.id }) {
            if discovered[index] != glasses { discovered[index] = glasses }
        } else {
            log("found \(name ?? peripheral.name ?? "?") (\(peripheral.identifier))")
            discovered.append(glasses)
        }
    }

    private func log(_ message: String) {
        print("[G2] \(message)")
    }
}

// MARK: - CoreBluetooth delegates (called on the main queue)

extension G2Link: @MainActor CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("bluetooth state \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            if case .bluetoothUnavailable = status { status = .disconnected }
            let actions = poweredOnActions
            poweredOnActions = []
            actions.forEach { $0() }
        case .poweredOff:
            tearDown()
            status = .bluetoothUnavailable("Bluetooth is off.")
        case .unauthorized:
            status = .bluetoothUnavailable("Lotti may not use Bluetooth. Allow it in Settings → Lotti.")
        case .unsupported:
            status = .bluetoothUnavailable("This device doesn't support Bluetooth LE.")
        default:
            break
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        record(peripheral, name: name, rssi: RSSI.intValue)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("did connect \(peripheral.name ?? "?")")
        connectWaiters.removeValue(forKey: peripheral.identifier)?.resume(.success(()))
    }

    public func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        log("failed to connect \(peripheral.name ?? "?"): \(String(describing: error))")
        fail(peripheral.identifier, error ?? GlassesLinkError.notConnected)
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        log("disconnected \(peripheral.name ?? "?"): \(String(describing: error))")
        fail(peripheral.identifier, error ?? GlassesLinkError.notConnected)
        guard arms.values.contains(where: { $0.peripheral === peripheral }) else { return }
        let wasConnected = status.isConnected
        tearDown()
        if wasConnected { status = .disconnected }
    }
}

extension G2Link: @MainActor CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let arm = arm(for: peripheral) else { return }
        let services = peripheral.services ?? []
        log("\(arm.side) services: \(services.map(\.uuid.uuidString))")
        if let error { return fail(peripheral.identifier, error) }
        arm.pendingServices = services.count
        if services.isEmpty { return fail(peripheral.identifier, GlassesLinkError.missingCharacteristics) }
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard let arm = arm(for: peripheral) else { return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.controlWrite { arm.write = characteristic }
            if characteristic.uuid == Self.controlNotify { arm.notify = characteristic }
        }
        arm.pendingServices -= 1
        guard arm.pendingServices == 0 else { return }
        guard arm.write != nil, let notify = arm.notify else {
            return fail(peripheral.identifier, GlassesLinkError.missingCharacteristics)
        }
        peripheral.setNotifyValue(true, for: notify)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard characteristic.uuid == Self.controlNotify else { return }
        if let error {
            fail(peripheral.identifier, error)
        } else {
            setupWaiters.removeValue(forKey: peripheral.identifier)?.resume(.success(()))
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard characteristic.uuid == Self.controlNotify, let arm = arm(for: peripheral),
              let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        log("rx \(arm.side) \(hex(bytes))")
        guard let message = arm.assembler.feed(bytes), let magic = message.magic else { return }
        let key = ReplyKey(side: arm.side, sid: message.sid, magic: magic)
        replyWaiters.removeValue(forKey: key)?.resume(.success(message))
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        arm(for: peripheral)?.resumeWriters()
    }

    private func arm(for peripheral: CBPeripheral) -> Arm? {
        arms.values.first { $0.peripheral === peripheral }
    }
}

// MARK: - Helpers

extension DiscoveredGlasses {
    func armID(_ side: G2Side) -> UUID? { side == .left ? leftArm : rightArm }

    mutating func setArmID(_ id: UUID, _ side: G2Side) {
        if side == .left { leftArm = id } else { rightArm = id }
    }
}

@MainActor
private final class Arm {
    let side: G2Side
    let peripheral: CBPeripheral
    var write: CBCharacteristic?
    var notify: CBCharacteristic?
    var assembler = G2FrameAssembler()
    var pendingServices = 0
    var writeTail: Task<Void, Never>?
    private var writableWaiters: [CheckedContinuation<Void, Never>] = []

    init(side: G2Side, peripheral: CBPeripheral) {
        self.side = side
        self.peripheral = peripheral
    }

    func waitUntilWritable() async {
        guard !peripheral.canSendWriteWithoutResponse, peripheral.state == .connected else { return }
        await withCheckedContinuation { writableWaiters.append($0) }
    }

    func resumeWriters() {
        let waiters = writableWaiters
        writableWaiters = []
        waiters.forEach { $0.resume() }
    }

    func failPendingWrites() {
        writeTail?.cancel()
        resumeWriters()
    }
}

private struct ReplyKey: Hashable {
    var side: G2Side
    var sid: UInt8
    var magic: UInt64
}

/// A continuation that can be resumed at most once (by a reply, a disconnect or a timeout).
@MainActor
private final class Waiter<T: Sendable> {
    var continuation: CheckedContinuation<T, Error>?

    func resume(_ result: Result<T, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}
