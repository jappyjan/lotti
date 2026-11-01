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
/// 4. display: create the page once (Cmd 0), then update texts (Cmd 5) or rebuild it (Cmd 7)
///    when the layout changes (see `G2PagePlanner`)
/// 5. mic (on demand): Cmd 15 on, LC3 packets on `…6402`, decoded to 16 kHz PCM
@MainActor
@Observable
public final class G2Link: NSObject, GlassesLink {
    public private(set) var status: GlassesStatus = .disconnected
    public private(set) var discovered: [DiscoveredGlasses] = []
    public private(set) var lastGlasses: DiscoveredGlasses?

    // GATT layout. All G2 characteristics share one UUID base.
    static let controlWrite = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E5401")
    static let controlNotify = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E5402")
    /// Microphone: raw LC3 packets, no frame header (see `G2Microphone`).
    static let micNotify = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E6402")
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
    @ObservationIgnored private var page = G2PagePlanner()
    // Head tracking (IMU). `imuField` is the envelope field that produced samples (20 or 22).
    @ObservationIgnored private var headTrackingWanted = false
    @ObservationIgnored private var lastFrame: GlassesFrame?
    @ObservationIgnored private var redraw: Task<Void, Never>?
    @ObservationIgnored private var imuArming = false
    @ObservationIgnored private var imuField: Int?
    @ObservationIgnored private var lastImuSample: TimeInterval?
    /// Seconds between `[IMU]` log lines (lower it to calibrate head-up).
    @ObservationIgnored public var imuLogInterval: TimeInterval = 1
    @ObservationIgnored private var lastImuLog: TimeInterval = 0
    @ObservationIgnored private var headUp = HeadUpDetector(config: HeadUpSettings().config)
    @ObservationIgnored private let inputBroadcast = Broadcast<InputEvent>()
    @ObservationIgnored private var deduplicator = InputDeduplicator()
    @ObservationIgnored private var microphone: MicSession?
    @ObservationIgnored private var strayMicPackets = 0

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
            if let right = arms[.right] {
                await send(G2Payload.headUpSetting(magic: nextMagic(), enabled: false), sid: G2Service.settings,
                           flag: G2Flag.request, to: right)
            }
            if headTrackingWanted { Task { await armImu() } }
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
        try await show(GlassesFrame(main: text))
    }

    public func inputs() -> AsyncStream<InputEvent> {
        inputBroadcast.stream()
    }

    public func show(_ frame: GlassesFrame) async throws {
        guard status.isConnected, let right = arms[.right] else { throw GlassesLinkError.notConnected }
        lastFrame = frame
        do {
            try await draw(frame, on: right)
        } catch PageError.gone {
            // The firmware closed our page (its own dashboard, or a reset). Start the session
            // again and create the page from scratch.
            print("[Glasses] page is gone, creating it again")
            page.reset()
            let prelude = try? await request(G2Payload.prelude(), sid: G2Service.appLaunch, flag: G2Flag.request,
                                             magic: G2Payload.preludeMagic, to: right, step: "session prelude", seconds: 3)
            log("prelude reply: \(prelude.map { hex($0.payload) } ?? "none")")
            try await draw(frame, on: right)
        }
    }

    private enum PageError: Error { case gone }

    private func draw(_ frame: GlassesFrame, on right: Arm) async throws {
        var pageChanged = false
        for command in page.plan(frame) {
            let m = nextMagic()
            do {
                switch command {
                case .create(let boxes):
                    pageChanged = true
                    _ = try await request(G2Payload.createPage(magic: m, boxes: boxes), sid: G2Service.evenHub,
                                          flag: G2Flag.request, magic: m, to: right, step: "creating the page")
                case .rebuild(let boxes):
                    pageChanged = true
                    // Untested live by the references, and an ack may not come: only an explicit
                    // failure counts.
                    let reply = try? await request(G2Payload.rebuildPage(magic: m, boxes: boxes), sid: G2Service.evenHub,
                                                   flag: G2Flag.request, magic: m, to: right,
                                                   step: "rebuilding the page", seconds: 2)
                    let result = reply.flatMap { G2Payload.rebuildResult($0.payload) }
                    let outcome = result.map { $0 == 6 ? "ok" : "result \($0)" } ?? "no ack"
                    print("[Glasses] rebuild \(boxes.map(\.name)): \(outcome)")
                    if result == 7 { throw PageError.gone }
                    if let result, result != 6 {
                        throw GlassesLinkError.timeout("rebuilding the page (result \(result))")
                    }
                case .update(let id, let name, let text):
                    _ = try await request(G2Payload.textUpdate(magic: m, containerID: id, containerName: name, text: text),
                                          sid: G2Service.evenHub, flag: G2Flag.request, magic: m, to: right,
                                          step: "updating \(name)")
                }
            } catch {
                // We no longer know what's on the glasses; the next frame rebuilds the page.
                print("[Glasses] \(command) failed: \(error)")
                page.markUnknown()
                throw error
            }
        }
        // IMU reporting lives inside the page: re-arm it after the page was (re)built.
        if pageChanged, headTrackingWanted, !imuArming { Task { await armImu() } }
    }

    /// The firmware switched to one of its own screens (dashboard, menu), which shuts our page
    /// down. Rebuild it with the last frame shortly after.
    private func pageTakenOver() {
        guard let frame = lastFrame else { return }
        page.markUnknown()
        redraw?.cancel()
        redraw = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, self.status.isConnected, self.lastFrame == frame else { return }
            print("[Glasses] page taken over, redrawing")
            try? await self.show(frame)
        }
    }

    public func startMicrophone() async throws -> AsyncStream<[Int16]> {
        guard status.isConnected, let right = arms[.right] else { throw GlassesLinkError.notConnected }
        guard right.mic != nil || arms[.left]?.mic != nil else { throw GlassesLinkError.missingCharacteristics }
        guard let decoder = LC3Decoder() else { throw GlassesLinkError.missingCharacteristics }
        endMicrophone()
        let (stream, continuation) = AsyncStream<[Int16]>.makeStream(bufferingPolicy: .bufferingNewest(100))
        microphone = MicSession(decoder: decoder, continuation: continuation)
        // Both arms stay subscribed to `…6402` from connect on (MentraOS). The firmware only
        // starts streaming on an off → on edge, so switch it off first.
        await send(G2Payload.audioControl(magic: nextMagic(), enabled: false), sid: G2Service.evenHub,
                   flag: G2Flag.request, to: right)
        try? await Task.sleep(for: .milliseconds(300))
        let m = nextMagic()
        do {
            _ = try await request(G2Payload.audioControl(magic: m, enabled: true), sid: G2Service.evenHub,
                                  flag: G2Flag.request, magic: m, to: right, step: "turning the mic on")
            log("[Mic] on (acked)")
        } catch {
            // What counts is audio arriving; the ack is only a hint.
            log("[Mic] on, no ack: \(error.localizedDescription)")
        }
        return stream
    }

    public func stopMicrophone() async {
        guard let mic = microphone else { return }
        log("[Mic] off after \(mic.packets) packets")
        endMicrophone()
        guard let right = arms[.right] else { return }
        let m = nextMagic()
        _ = try? await request(G2Payload.audioControl(magic: m, enabled: false), sid: G2Service.evenHub,
                               flag: G2Flag.request, magic: m, to: right, step: "turning the mic off", seconds: 2)
    }

    /// Finishes the mic stream without talking to the glasses (also used when the link drops).
    private func endMicrophone() {
        microphone?.continuation.finish()
        microphone = nil
    }

    private func receiveMicPacket(_ bytes: [UInt8], from side: G2Side) {
        guard let mic = microphone else {
            strayMicPackets += 1
            if strayMicPackets == 1 { log("[Mic] audio from the \(side) arm while off") }
            return
        }
        // Both arms may stream; use the one that sends first. Drop exact repeats (MentraOS).
        if mic.side == nil {
            mic.side = side
            log("[Mic] first packet from the \(side) arm: \(bytes.count) bytes, starts \(hex(Array(bytes.prefix(12))))")
        }
        guard mic.side == side, bytes != mic.last else { return }
        mic.last = bytes
        mic.packets += 1
        if mic.packets % 200 == 0 { log("[Mic] \(mic.packets) packets") }
        mic.continuation.yield(mic.decoder.decode(packet: bytes))
    }

    /// Tuning for head-up detection; see `HeadUpDetector.Config`.
    public var headUpSettings = HeadUpSettings() {
        didSet { headUp.config = headUpSettings.config }
    }
    public private(set) var headPitch: Double?

    public var headUpConfig: HeadUpDetector.Config {
        get { headUp.config }
        set { headUp.config = newValue }
    }

    public func setHeadTracking(_ enabled: Bool) async {
        headTrackingWanted = enabled
        headUp.reset()
        if enabled {
            await armImu()
        } else if status.isConnected, let right = arms[.right] {
            await send(G2Payload.imuControl(magic: nextMagic(), enable: false, field: imuField ?? 20),
                       sid: G2Service.evenHub, flag: G2Flag.request, to: right)
            print("[IMU] off")
        }
    }

    /// Turns IMU reporting on. The field number differs between references (20 in MentraOS, 22 in
    /// even-g2-protocol), so this tries 20 first and counts it as working once samples arrive.
    private func armImu() async {
        guard !imuArming, headTrackingWanted, status.isConnected else { return }
        imuArming = true
        defer { imuArming = false }
        // IMU needs a live EvenHub page; put up a dark one if nothing was shown yet.
        if !page.hasPage { try? await show(.dark) }
        for field in imuField.map({ [$0] }) ?? [20, 22] {
            guard headTrackingWanted, status.isConnected, let right = arms[.right] else { return }
            let sentAt = ProcessInfo.processInfo.systemUptime
            let m = nextMagic()
            let ack = try? await request(G2Payload.imuControl(magic: m, enable: true, pace: 200, field: field),
                                         sid: G2Service.evenHub, flag: G2Flag.request, magic: m, to: right,
                                         step: "IMU control", seconds: 1.5)
            if let ack { print("[IMU] control acked via field \(field): \(hex(ack.payload))") }
            for _ in 0..<12 {
                if let last = lastImuSample, last >= sentAt {
                    imuField = field
                    print("[IMU] samples arriving via field \(field)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            print("[IMU] no samples within 3 s via field \(field)")
        }
    }

    private func receiveImu(x: Float, y: Float, z: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        lastImuSample = now
        guard headTrackingWanted else { return }
        if now - lastImuLog >= imuLogInterval {
            lastImuLog = now
            let pitch = headUp.pitch(x: x, y: y, z: z).map { String(format: "%.0f°", $0) } ?? "?"
            print(String(format: "[IMU] x %.2f y %.2f z %.2f", x, y, z) + " pitch(\(headUp.config.axis)) \(pitch)")
        }
        if let pitch = headUp.pitch(x: x, y: y, z: z) { headPitch = pitch }
        if let gesture = headUp.feed(x: x, y: y, z: z, at: now) {
            print("[IMU] \(gesture.rawValue)")
            inputBroadcast.send(InputEvent(gesture, from: .imu))
        }
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

        page.reset()
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
        page.reset()
        lastFrame = nil
        redraw?.cancel()
        lastImuSample = nil
        headUp.reset()
        endMicrophone()
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
            if characteristic.uuid == Self.micNotify {
                arm.mic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
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
        if characteristic.uuid == Self.micNotify {
            log("[Mic] \(arm(for: peripheral)?.side.rawValue ?? "?") notify \(characteristic.isNotifying ? "on" : "off")\(error.map { ", error: \($0.localizedDescription)" } ?? "")")
            return
        }
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
        if characteristic.uuid == Self.micNotify, let data = characteristic.value {
            guard let arm = arm(for: peripheral) else { return }
            return receiveMicPacket([UInt8](data), from: arm.side)
        }
        guard characteristic.uuid == Self.controlNotify, let arm = arm(for: peripheral),
              let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        guard let message = arm.assembler.feed(bytes) else {
            log("rx \(arm.side) \(hex(bytes))")
            return
        }
        let event = G2Events.decode(message)
        // IMU reports come several times a second; receiveImu logs them once a second.
        if case .imu = event {} else { log("rx \(arm.side) \(hex(bytes))") }
        if let magic = message.magic {
            let key = ReplyKey(side: arm.side, sid: message.sid, magic: magic)
            replyWaiters.removeValue(forKey: key)?.resume(.success(message))
        }
        switch event {
        case .input(let input):
            let isNew = deduplicator.accept(input, at: ProcessInfo.processInfo.systemUptime)
            log("input \(input) from \(arm.side) arm\(isNew ? "" : " (repeat, dropped)")")
            if isNew { inputBroadcast.send(input) }
        case .imu(let x, let y, let z):
            receiveImu(x: x, y: y, z: z)
        case .info(let text):
            log("\(arm.side) arm: \(text)")
            if message.sid == G2Events.stateService, message.payload == G2Events.dashboardToggled, arm.side == .right {
                pageTakenOver()
            }
        case nil:
            break
        }
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
    var mic: CBCharacteristic?
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

/// An open mic stream: the LC3 decoder and where the PCM goes.
@MainActor
private final class MicSession {
    let decoder: LC3Decoder
    let continuation: AsyncStream<[Int16]>.Continuation
    var packets = 0
    /// The arm whose audio we use (the first to send).
    var side: G2Side?
    var last: [UInt8]?

    init(decoder: LC3Decoder, continuation: AsyncStream<[Int16]>.Continuation) {
        self.decoder = decoder
        self.continuation = continuation
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
