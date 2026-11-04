import Foundation
import Observation

/// Something the backend told us that isn't the answer to a call of ours. Subscribe with
/// `BackendClient.events()`.
public enum BackendEvent: Equatable, Sendable {
    case connected(BackendWelcome)
    case disconnected
    case status(askId: String, text: String)
    /// The inbox changed (an `inbox` or `push` message); `BackendClient.inbox` is already updated.
    case inboxChanged
    /// A new item arrived (`push`). It is already in the inbox; this is never a reason to open a screen.
    case push(InboxItem)
    case catchup(Catchup)
    case locationAccess(LocationAccess)
    case message(ChatMessage)
    case conversation(id: String, event: String)
    case error(id: String?, message: String)
    /// A phone tool the backend called, and how it went.
    case toolCall(BackendToolCall, ToolResult)
}

/// The app's connection to Lotti Brain (docs/protocol.md): one live WebSocket that carries asks
/// and answers, the backend's calls to phone tools, the inbox, and presence.
///
/// - Reconnects by itself with backoff (`ReconnectPolicy`); `reconnectNow()` skips the wait and
///   also checks a socket that looks open. Call it on app launch, when the app becomes active
///   and when the glasses wake the app over BLE.
/// - Phone tools (`location`, `reminders`) run through the `Toolbox` with its rules: reads only,
///   arguments validated, a 10 s limit, and only the names in `allowedTools`.
/// - The inbox lives in `inbox`; the backend is the source of truth.
@MainActor
@Observable
public final class BackendClient {
    public enum State: Equatable, Sendable {
        case disconnected, connecting
        /// The socket is up and the backend said `welcome`.
        case connected
    }

    public private(set) var state: State = .disconnected
    public private(set) var welcome: BackendWelcome?
    /// Why the last connection attempt or call failed, for the status screen.
    public private(set) var lastError: String?
    public private(set) var lastCatchup: Catchup?
    /// The backend's inbox as this device knows it.
    @ObservationIgnored public let inbox: InboxStore
    /// Phone tools the backend may call.
    @ObservationIgnored public var allowedTools: Set<String> = ["location", "reminders"]

    /// Where to connect; nil means "not paired". Changing it reconnects.
    @ObservationIgnored public var configuration: BackendConfiguration? {
        didSet { if oldValue != configuration, running { connection?.close(); fireWake() } }
    }

    public var isReachable: Bool { state == .connected }

    @ObservationIgnored private let transport: any BackendTransport
    @ObservationIgnored private let toolbox: Toolbox
    @ObservationIgnored private let policy: ReconnectPolicy
    @ObservationIgnored private let toolTimeout: Duration
    @ObservationIgnored private let requestTimeout: Duration
    @ObservationIgnored private let firstFrameTimeout: Duration
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let broadcast = Broadcast<BackendEvent>()

    @ObservationIgnored private var loop: Task<Void, Never>?
    private var running: Bool { loop != nil }
    @ObservationIgnored private var connection: (any BackendConnection)?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var wake: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var wakeTimer: Task<Void, Never>?
    @ObservationIgnored private var requestCounter = 0
    @ObservationIgnored private var asks: [String: PendingAsk] = [:]
    @ObservationIgnored private var performs: [String: CheckedContinuation<BackendPerformed, Error>] = [:]
    /// `inbox_event`s that couldn't be sent yet; flushed after the next `welcome`.
    @ObservationIgnored private var outbox: [BackendRequest] = []
    /// Presence that happened without a socket: the latest of each kind, sent after the next
    /// `welcome` if it is still fresh (`presenceMaxAge`).
    @ObservationIgnored private var heldPresence: [PresenceEvent: (at: Date, detail: String?)] = [:]
    static let presenceMaxAge: TimeInterval = 30
    @ObservationIgnored private var outgoing: [(BackendRequest, (@MainActor (Error) -> Void)?)] = []
    @ObservationIgnored private var draining = false

    private struct PendingAsk {
        var status: @MainActor (String) -> Void
        var activity: @MainActor () -> Void
        var continuation: CheckedContinuation<BackendAnswer, Error>
        /// Closes the socket if the backend says nothing at all about the ask in time.
        var watchdog: Task<Void, Never>?
    }

    public init(
        transport: any BackendTransport = URLSessionBackendTransport(), toolbox: Toolbox = Toolbox(),
        configuration: BackendConfiguration? = nil, inbox: InboxStore = InboxStore(),
        policy: ReconnectPolicy = ReconnectPolicy(), toolTimeout: Duration = .seconds(10),
        requestTimeout: Duration = .seconds(30), firstFrameTimeout: Duration = .seconds(6),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.toolbox = toolbox
        self.configuration = configuration
        self.inbox = inbox
        self.policy = policy
        self.toolTimeout = toolTimeout
        self.requestTimeout = requestTimeout
        self.firstFrameTimeout = firstFrameTimeout
        self.now = now
    }

    // MARK: - Connection

    /// Starts connecting and keeps the socket up until `stop()`.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        fireWake()
        connection?.close()
        connection = nil
        setDisconnected()
    }

    /// Connect right now instead of after the backoff. When a socket looks open, ping it: a dead
    /// one is closed, which makes the loop reconnect. Also asks for a fresh inbox.
    public func reconnectNow() {
        guard running else { return start() }
        switch state {
        case .connected:
            guard let connection else { return }
            Task {
                let alive = await withTimeout(.seconds(5)) { (try? await connection.ping()) != nil }
                if alive == true {
                    self.fire(.inboxSync)
                } else {
                    connection.close()
                }
            }
        case .disconnected:
            attempt = 0
            fireWake()
        case .connecting:
            break
        }
    }

    private func run() async {
        while !Task.isCancelled {
            guard let configuration, let url = configuration.socketURL else {
                lastError = BackendError.notConfigured.errorDescription
                await sleep(policy.maximum)
                continue
            }
            state = .connecting
            do {
                let connection = try await transport.connect(to: url, token: configuration.token)
                guard !Task.isCancelled else { connection.close(); break }
                self.connection = connection
                try await connection.send(BackendRequest.hello(appVersion: configuration.appVersion, deviceName: configuration.deviceName,
                                                               apnsToken: configuration.apnsToken).json)
                while true { handle(try await connection.receive()) }
            } catch {
                if !Task.isCancelled { lastError = error.localizedDescription }
            }
            guard !Task.isCancelled else { break }
            connection?.close()
            connection = nil
            let wasConnected = state == .connected
            setDisconnected()
            if wasConnected { broadcast.send(.disconnected) }
            let delay = policy.delay(attempt: attempt)
            attempt += 1
            await sleep(delay)
        }
    }

    private func setDisconnected() {
        state = .disconnected
        welcome = nil
        let pending = asks
        asks = [:]
        for ask in pending.values {
            ask.watchdog?.cancel()
            ask.continuation.resume(throwing: BackendError.unreachable)
        }
        let performing = performs
        performs = [:]
        for continuation in performing.values { continuation.resume(throwing: BackendError.unreachable) }
    }

    /// Waits `delay`, or until `fireWake()`.
    private func sleep(_ delay: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wake = continuation
            wakeTimer = Task { [weak self] in
                try? await Task.sleep(for: delay)
                self?.fireWake()
            }
        }
    }

    private func fireWake() {
        wakeTimer?.cancel()
        wakeTimer = nil
        wake?.resume()
        wake = nil
    }

    // MARK: - Incoming

    func handle(_ text: String) {
        guard let message = BackendMessage.decode(text) else { return }
        switch message {
        case .welcome(let welcome):
            self.welcome = welcome
            state = .connected
            attempt = 0
            lastError = nil
            broadcast.send(.connected(welcome))
            for request in outbox { fire(request) }
            outbox = []
            flushPresence()
            // No `inbox_sync` here: the backend sends the whole inbox right after `welcome`.
        case .status(let id, let text):
            markAlive(id)
            asks[id]?.status(text)
            asks[id]?.activity()
            broadcast.send(.status(askId: id, text: text))
        case .answer(let answer):
            guard let ask = takeAsk(answer.id) else { return }
            var answer = answer
            answer.actions = validated(answer.actions)
            ask.continuation.resume(returning: answer)
        case .error(let id, let message):
            lastError = message
            if let id, let ask = takeAsk(id) {
                ask.continuation.resume(throwing: BackendError.server(message))
            } else if let id, let continuation = performs.removeValue(forKey: id) {
                continuation.resume(throwing: BackendError.server(message))
            }
            broadcast.send(.error(id: id, message: message))
        case .toolCall(let call):
            if let askId = call.askId {
                markAlive(askId)
                asks[askId]?.activity()
            }
            Task { await self.answer(call) }
        case .locationAccess(let access):
            broadcast.send(.locationAccess(access))
        case .performed(let performed):
            performs.removeValue(forKey: performed.id)?.resume(returning: performed)
        case .inbox(let full, let items, let removedIds):
            inbox.apply(full: full, items: items, removedIds: removedIds)
            broadcast.send(.inboxChanged)
        case .push(let item):
            inbox.upsert(item)
            broadcast.send(.push(item))
            broadcast.send(.inboxChanged)
        case .catchup(let catchup):
            lastCatchup = catchup
            broadcast.send(.catchup(catchup))
        case .conversation(let id, let event):
            broadcast.send(.conversation(id: id, event: event))
        case .message(let message):
            broadcast.send(.message(message))
        case .unknown:
            break
        }
    }

    /// Phone actions run only if the `Toolbox` knows the tool and the arguments fit. A brain's
    /// say-so is never enough.
    func validated(_ actions: [ProposedAction]) -> [ProposedAction] {
        actions.compactMap { action in
            guard action.target == .phone else { return action }
            guard var checked = toolbox.proposal(for: ToolCall(id: action.actionId ?? action.tool, tool: action.tool, arguments: action.arguments.values))
            else { return nil }
            if !action.title.isEmpty { checked.title = action.title }
            checked.actionId = action.actionId
            return checked
        }
    }

    /// Runs a phone tool the backend asked for and sends `tool_result`.
    private func answer(_ call: BackendToolCall) async {
        let result = await run(call)
        broadcast.send(.toolCall(call, result))
        try? await send(.toolResult(callId: call.callId, ok: result.ok, text: result.content))
    }

    func run(_ call: BackendToolCall) async -> ToolResult {
        guard allowedTools.contains(call.name) else {
            return ToolResult(id: call.callId, ok: false, content: "Jan doesn't share \(call.name) with you.")
        }
        let toolCall = ToolCall(id: call.callId, tool: call.name, arguments: call.args)
        let toolbox = self.toolbox
        let allowed = allowedTools
        let result = await withTimeout(toolTimeout) { await toolbox.run([toolCall], allowed: allowed).first }
        return (result ?? nil) ?? ToolResult(id: call.callId, ok: false, content: "\(call.name) took too long.")
    }

    // MARK: - Calls

    /// Unique across launches and devices (the backend keys running asks by id).
    private func newAskID() -> String { UUID().uuidString.lowercased() }

    private func nextID(_ prefix: String) -> String {
        requestCounter += 1
        return "\(prefix)\(requestCounter)"
    }

    private func send(_ request: BackendRequest) async throws {
        guard let connection else { throw BackendError.unreachable }
        try await connection.send(request.json)
    }

    /// Sends in the order called (separate tasks could reorder `ask` and `cancel`); errors go to
    /// `onError`, or are dropped.
    private func fire(_ request: BackendRequest, onError: (@MainActor (Error) -> Void)? = nil) {
        outgoing.append((request, onError))
        guard !draining else { return }
        draining = true
        Task {
            while !outgoing.isEmpty {
                let (next, onError) = outgoing.removeFirst()
                do { try await send(next) } catch { onError?(error) }
            }
            draining = false
        }
    }

    /// Asks Lotti. `status` gets the backend's short lines ("Suche Mails …"); `activity` fires on
    /// every sign of life. Cancelling the calling task sends `cancel`. Throws `.unreachable` when
    /// there is no socket (or it drops meanwhile), so the caller can use the offline brain.
    public func ask(
        _ text: String, channel: BackendChannel = .glasses, locale: String? = nil,
        status: @escaping @MainActor (String) -> Void = { _ in },
        activity: @escaping @MainActor () -> Void = {}
    ) async throws -> BackendAnswer {
        guard isReachable else { throw BackendError.unreachable }
        let id = newAskID()
        let locale = locale ?? (LocalPipeline.language(of: text) == "German" ? "de" : "en")
        let request = BackendRequest.ask(id: id, text: text, channel: channel, now: now(), locale: locale)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                asks[id] = PendingAsk(status: status, activity: activity, continuation: continuation,
                                      watchdog: watchdog(for: id))
                fire(request) { [self] error in failAsk(id, error) }
            }
        } onCancel: {
            Task { @MainActor in self.cancelAsk(id) }
        }
    }

    private func failAsk(_ id: String, _ error: Error) {
        takeAsk(id)?.continuation.resume(throwing: error)
    }

    private func takeAsk(_ id: String) -> PendingAsk? {
        guard let ask = asks.removeValue(forKey: id) else { return nil }
        ask.watchdog?.cancel()
        return ask
    }

    /// The backend acknowledged the ask (status, tool call, answer or error): the socket is alive.
    private func markAlive(_ id: String) {
        asks[id]?.watchdog?.cancel()
        asks[id]?.watchdog = nil
    }

    /// The backend answers every ask with a status line right away. If nothing at all comes for
    /// it within `firstFrameTimeout`, the socket is dead even if it looks open: fail the ask with
    /// `.unreachable` (so the caller answers offline) and close it, which makes the loop reconnect.
    private func watchdog(for id: String) -> Task<Void, Never> {
        let timeout = firstFrameTimeout
        return Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.asks[id] != nil else { return }
            self.lastError = "Lotti Brain didn't respond."
            self.failAsk(id, BackendError.unreachable)
            self.connection?.close()
        }
    }

    private func cancelAsk(_ id: String) {
        guard let ask = takeAsk(id) else { return }
        ask.continuation.resume(throwing: CancellationError())
        fire(.cancel(id: id))
    }

    /// Runs a server action from an answer (`target: "server"`): `perform {actionId}`.
    public func perform(actionId: String) async throws -> BackendPerformed {
        try await call { .perform(id: $0, actionId: actionId) }
    }

    /// Takes back an immediate action: `undo {undoId}`.
    public func undo(_ undoId: String) async throws -> BackendPerformed {
        try await call { .undo(id: $0, undoId: undoId) }
    }

    private func call(_ build: (String) -> BackendRequest) async throws -> BackendPerformed {
        guard isReachable else { throw BackendError.unreachable }
        let id = nextID("req-")
        let request = build(id)
        let timeout = Task {
            try await Task.sleep(for: requestTimeout)
            performs.removeValue(forKey: id)?.resume(throwing: BackendError.timeout)
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            performs[id] = continuation
            fire(request) { [self] error in performs.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }

    // MARK: - Inbox and presence

    /// Tells the backend what happened to an item, and updates the local inbox right away
    /// (`opened` → seen, `dismissed` → gone). Without a socket the event is kept and sent after
    /// the next `welcome`.
    public func inboxEvent(_ itemId: String, _ event: InboxEvent) {
        switch event {
        case .shown: break
        case .opened: inbox.setStatus(itemId, .seen)
        case .dismissed: inbox.setStatus(itemId, .dismissed)
        }
        let request = BackendRequest.inboxEvent(itemId: itemId, event: event)
        if isReachable {
            fire(request)
        } else {
            outbox.append(request)
            if outbox.count > 100 { outbox.removeFirst(outbox.count - 100) }
        }
        if event != .shown { broadcast.send(.inboxChanged) }
    }

    /// Asks for the whole inbox again.
    public func syncInbox() {
        if isReachable { fire(.inboxSync) }
    }

    /// Tells the backend what the glasses and the phone are doing. Without a socket the latest
    /// event of each kind is kept and sent after the next `welcome`, with its own time, if it is at
    /// most 30 s old: stale presence is worse than none.
    public func presence(_ event: PresenceEvent, detail: String? = nil) {
        guard isReachable else {
            heldPresence[event] = (now(), detail)
            return
        }
        fire(.presence(event, at: now(), detail: detail))
    }

    private func flushPresence() {
        let held = heldPresence
        heldPresence = [:]
        let fresh = held.filter { now().timeIntervalSince($0.value.at) <= Self.presenceMaxAge }
        for (event, value) in fresh.sorted(by: { $0.value.at < $1.value.at }) {
            fire(.presence(event, at: value.at, detail: value.detail))
        }
    }

    // MARK: - Streams

    /// Everything that isn't the answer to one of our calls. Each call returns a new stream.
    public func events() -> AsyncStream<BackendEvent> { broadcast.stream() }

    /// Catch-up briefs (`catchup`), for the phone chat. The glasses show them too, through the `Conductor`.
    public func catchups() -> AsyncStream<Catchup> {
        let events = events()
        return AsyncStream { continuation in
            let task = Task {
                for await event in events { if case .catchup(let catchup) = event { continuation.yield(catchup) } }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Location reads by the backend (`location_access`): show the location icon on the glasses
    /// between `start` and `end`, and log it.
    public func locationAccesses() -> AsyncStream<LocationAccess> {
        let events = events()
        return AsyncStream { continuation in
            let task = Task {
                for await event in events { if case .locationAccess(let access) = event { continuation.yield(access) } }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Turns mirrored from the other surface (`message`), for the phone chat.
    public func messages() -> AsyncStream<ChatMessage> {
        let events = events()
        return AsyncStream { continuation in
            let task = Task {
                for await event in events { if case .message(let message) = event { continuation.yield(message) } }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
