import Foundation
import LottiKit
import Observation

@MainActor
@Observable
final class AppModel {
    /// A gesture as it arrived, for the "last input" readout.
    struct ReceivedInput: Identifiable, Equatable {
        let id = UUID()
        let event: InputEvent
        let time: Date
    }

    let link: any GlassesLink
    let conductor: Conductor
    /// The connection to Lotti Brain (live socket: asks, inbox, presence, phone tools).
    let backend: BackendClient
    let store: BackendStore
    /// Every time the backend read this phone's location.
    let locationLog: LocationReadLog
    let phonePresence: PresenceMonitor
    /// The management API (HTTP ops behind the settings screens); nil until paired.
    private(set) var management: BackendManagementClient?
    /// Ops the backend offers (`GET /api/v1/ops`); empty until the first successful listing.
    private(set) var ops: [String: BackendOp] = [:]
    private(set) var isPairing = false
    var http: any BackendHTTP = URLSessionHTTP()
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private var announceAppOpen = false
    /// Newest first, at most `maxInputs`.
    private(set) var inputs: [ReceivedInput] = []
    static let maxInputs = 10
    /// How many times the link came back on its own since launch.
    private(set) var reconnects = 0

    /// You pressed Disconnect: don't reconnect until you connect again.
    private var stayDisconnected = false
    private var wasConnected = false

    init(link: any GlassesLink, conductor: Conductor, backend: BackendClient = BackendClient(),
         store: BackendStore = BackendStore(), locationLog: LocationReadLog = LocationReadLog(),
         deviceName: String = "iPhone", appVersion: String = "0.1") {
        self.link = link
        self.conductor = conductor
        self.backend = backend
        self.store = store
        self.locationLog = locationLog
        self.deviceName = deviceName
        self.appVersion = appVersion
        phonePresence = PresenceMonitor(backend: backend)
        applyConfiguration()
    }

    // MARK: - Lotti Brain

    private(set) var isPaired = false
    private(set) var baseURL: URL?

    /// Whether the backend offers `op`. True while the list is unknown, so screens try instead of hiding.
    func supports(_ op: String) -> Bool { ops.isEmpty || ops[op] != nil }

    /// Starts the live connection when paired, and watches the backend's events until cancelled.
    func startBackend() {
        phonePresence.start()
        guard store.isPaired else { return }
        backend.start()
    }

    /// Follows the backend's events for the app's own needs: the location read log, and what to
    /// tell it after (re)connecting. The chat and the glasses read the same stream themselves.
    func observeBackend() async {
        let events = backend.events()
        if backend.isReachable { await refreshOps() }
        for await event in events {
            switch event {
            case .connected:
                await refreshOps()
                if announceAppOpen {
                    announceAppOpen = false
                    backend.presence(.appOpen)
                }
                phonePresence.reportCurrent(force: true)
            case .locationAccess(let access):
                locationLog.record(access)
            default:
                break
            }
        }
    }

    /// The app came to the foreground: reconnect now and say so.
    func didBecomeActive() {
        guard store.isPaired else { return }
        if backend.isReachable {
            backend.presence(.appOpen)
        } else {
            announceAppOpen = true
        }
        backend.reconnectNow()
    }

    /// Trades a pairing code for a device token and connects.
    func pair(url: URL, code: String) async throws {
        isPairing = true
        defer { isPairing = false }
        let token = try await BackendManagementClient(baseURL: url, http: http).pair(code: code, deviceName: deviceName)
        store.url = url
        store.token = token
        applyConfiguration()
        backend.start()
    }

    /// Pairs from a `lotti://pair?url=…&code=…` link. Returns false if `text` isn't one.
    @discardableResult
    func pair(link text: String) async throws -> Bool {
        guard let link = PairingLink(text) else { return false }
        try await pair(url: link.url, code: link.code)
        return true
    }

    func unpair() {
        backend.stop()
        store.clear()
        applyConfiguration()
        ops = [:]
    }

    /// The APNs device token (hex); rides in the next `hello`, which reconnects once.
    func setAPNsToken(_ token: String?) {
        guard store.apnsToken != token else { return }
        store.apnsToken = token
        applyConfiguration()
    }

    /// Runs one management op (`POST /api/v1/ops/<name>`).
    func call(_ op: String, _ input: JSONValue = [:]) async throws -> JSONValue {
        guard let management else { throw BackendError.notConfigured }
        return try await management.call(op, input)
    }

    func refreshOps() async {
        guard let management, let list = try? await management.listOps() else { return }
        ops = Dictionary(list.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func applyConfiguration() {
        let configuration = store.configuration(deviceName: deviceName, appVersion: appVersion)
        backend.configuration = configuration
        management = configuration.map { BackendManagementClient(configuration: $0, http: http) }
        isPaired = configuration != nil
        baseURL = configuration?.baseURL
    }

    /// Reconnect to the glasses from last time, or start looking for some.
    func launch() async {
        if link.lastGlasses != nil {
            await link.reconnectToLast()
        } else {
            link.startScan()
        }
    }

    /// Notices connects and drops: redraws after a connect, and reconnects after a drop, with a
    /// growing pause between attempts. Runs until cancelled.
    func keepConnected(pollEvery: Duration = .seconds(2)) async {
        var attempt = 0
        while !Task.isCancelled {
            let connected = link.status.isConnected
            if connected && !wasConnected {
                print("[App] glasses connected")
                attempt = 0
                await conductor.glassesConnected()
                // The glasses woke the app (BLE): make sure Lotti Brain is reachable too.
                if store.isPaired { backend.reconnectNow() }
            }
            wasConnected = connected
            if shouldReconnect {
                attempt += 1
                let pause = min(30, 2 * attempt)
                print("[App] reconnecting (attempt \(attempt))")
                reconnects += 1
                await link.reconnectToLast()
                if !link.status.isConnected { try? await Task.sleep(for: .seconds(pause)) }
                continue
            }
            try? await Task.sleep(for: pollEvery)
        }
    }

    var shouldReconnect: Bool {
        guard !stayDisconnected, link.lastGlasses != nil else { return false }
        switch link.status {
        case .disconnected, .failed: return true
        default: return false
        }
    }

    func connect(_ glasses: DiscoveredGlasses) async {
        stayDisconnected = false
        await link.connect(glasses)
    }

    func disconnect() {
        stayDisconnected = true
        link.disconnect()
    }

    /// Collects gestures for the phone's readout until the stream ends. The conductor reads its
    /// own copy of the stream.
    func receiveInputs() async {
        for await event in link.inputs() {
            print("[Input] \(event)")
            inputs.insert(ReceivedInput(event: event, time: .now), at: 0)
            if inputs.count > Self.maxInputs { inputs.removeLast() }
        }
    }

    /// Debug launch arguments, so a run can be checked from the log without touching the glasses:
    /// `--ask "question"` asks Lotti once connected, `--today` opens the today view, `--listen`
    /// holds "talk" for 5 s (checks the mic and speech pipeline).
    func runLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) async {
        let wantsToday = arguments.contains("--today")
        let question = arguments.firstIndex(of: "--ask").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let wantsListen = arguments.contains("--listen")
        guard wantsToday || question != nil || wantsListen else { return }
        while !link.status.isConnected { try? await Task.sleep(for: .milliseconds(500)) }
        try? await Task.sleep(for: .seconds(1))
        if wantsToday { conductor.handle(InputEvent(.tap, from: .unknown)) }
        if wantsListen {
            if wantsToday { try? await Task.sleep(for: .seconds(4)) }
            print("[App] listening for 5 s")
            conductor.handle(InputEvent(.doubleTap, from: .unknown))
            try? await Task.sleep(for: .milliseconds(500))
            conductor.handle(InputEvent(.longPress, from: .unknown))
            try? await Task.sleep(for: .seconds(5))
            conductor.handle(InputEvent(.longPressEnd, from: .unknown))
            try? await Task.sleep(for: .seconds(6))
        }
        if let question {
            if wantsToday { try? await Task.sleep(for: .seconds(4)) }
            print("[App] asking: \(question)")
            conductor.ask(question)
        }
    }
}
