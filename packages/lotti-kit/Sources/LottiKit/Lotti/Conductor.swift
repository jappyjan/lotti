import Foundation
import Observation

/// Runs Lotti on the glasses: turns gestures, head movement, speech and answers into screens.
///
/// Gestures (same on the ring and both touchpads):
/// - display off: double tap or look up → today view
/// - scroll moves the rail highlight, tap picks it
/// - double tap: back (from a screen opened from the rail), otherwise display off, which also
///   ends the offline conversation (the backend continues one conversation forever and is never reset)
/// - long press: talk to Lotti while held (nothing else is ever on long press). With the display
///   off, talking needs a double tap first (the today view opens), then the hold, so a stray hold
///   in your pocket or hair doesn't start listening.
@MainActor
@Observable
public final class Conductor {
    public struct Timing: Sendable {
        /// A screen you opened goes dark after this long without a gesture.
        public var idle: Duration
        /// A "Done"-style line goes away after this.
        public var done: Duration
        /// Give up on the offline brain after this: several model steps plus tools (S3 saw rare 20–60 s stalls).
        public var answer: Duration
        /// Wait this long for the final transcript after you let go.
        public var finalTranscript: Duration
        /// An offline conversation older than this starts fresh. The backend has no such threshold
        /// (it continues one conversation forever), so this never ends the backend chat.
        public var conversation: Duration
        /// The backend may research the web, so the timeout counts silence, not total time: any
        /// sign of life from it (status lines, tool calls) restarts the clock.
        public var remote: Duration
        /// The location icon stays this long after a location read ends.
        public var locationAfter: Duration

        public init(
            idle: Duration = .seconds(30), done: Duration = .seconds(2), answer: Duration = .seconds(25),
            finalTranscript: Duration = .seconds(3), conversation: Duration = .seconds(300),
            remote: Duration = .seconds(120), locationAfter: Duration = .seconds(3)
        ) {
            self.idle = idle
            self.done = done
            self.answer = answer
            self.finalTranscript = finalTranscript
            self.conversation = conversation
            self.remote = remote
            self.locationAfter = locationAfter
        }
    }

    public enum Mode: Equatable, Sendable {
        case off
        /// `byHead`: opened by looking up, so looking down closes it again.
        case today(byHead: Bool)
        case listening
        case working
        /// Lotti's answer or a screen from the rail.
        case showing
        case done
    }

    /// What the glasses show right now; nil when the display is off. The phone mirrors it.
    public private(set) var screen: Screen?
    public private(set) var mode: Mode = .off
    /// The last thing you said, for the phone's log.
    public private(set) var lastHeard: String?
    /// Where the last voice input came from ("glasses" / "phone"), for the status screen.
    public private(set) var microphoneSource: String?
    public private(set) var lastError: String?
    /// The backend's inbox. Pending items show as the attention indicator while the display is
    /// off, as a summary on the today view, and as a list behind it. Pushes never open a screen.
    @ObservationIgnored public let inbox: InboxStore
    /// True while a location read runs and briefly after: the glasses show the location icon.
    public private(set) var locationActive = false

    @ObservationIgnored private let link: any GlassesLink
    @ObservationIgnored private let brain: any Brain
    @ObservationIgnored private let remote: (any RemoteBrain)?
    @ObservationIgnored private let backend: BackendClient?
    @ObservationIgnored private let indicators: IndicatorRenderer
    @ObservationIgnored private let summary: InboxSummary
    @ObservationIgnored private let toolbox: Toolbox
    @ObservationIgnored private let speech: any SpeechRecognizer
    @ObservationIgnored private let phoneMicrophone: (any Microphone)?
    @ObservationIgnored private let todayProvider: any TodayProvider
    @ObservationIgnored private let composer: TodayComposer
    @ObservationIgnored private var renderer: ScreenRenderer
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private let now: @Sendable () -> Date

    @ObservationIgnored private var backStack: [Screen] = []
    @ObservationIgnored private var today: TodayInfo?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var listening: Task<String, Never>?
    @ObservationIgnored private var thinking: Task<Void, Never>?
    @ObservationIgnored private var usingPhoneMic = false
    /// When Jan last asked anything: the offline brain's clock for `timing.conversation`.
    /// The backend has no such clock: it continues one conversation forever.
    @ObservationIgnored private var lastAsked: Date?
    @ObservationIgnored private var shownFrame: GlassesFrame?
    @ObservationIgnored private var drawing = false
    /// Shared demand for the IMU feed (head-up here, the mascot elsewhere).
    @ObservationIgnored public let imuDemand: IMUDemand
    @ObservationIgnored private var headUpToken: IMUDemand.Token?
    /// True while `syncHeadUpDemand` waits for the demand: later calls leave the change to it.
    @ObservationIgnored private var syncingHeadUp = false
    /// A catch-up brief that came while the glasses were off your face, shown when you put them on.
    @ObservationIgnored private var heldCatchup: (catchup: Catchup, received: Date)?
    /// The latest brief, kept so the today view can offer it as "Catch-up" for `catchupChoiceMaxAge`.
    @ObservationIgnored private var lastCatchup: (catchup: Catchup, received: Date)?
    static let catchupChoiceMaxAge: TimeInterval = 12 * 3600
    /// A held brief older than this is dropped instead of shown.
    static let heldCatchupMaxAge: TimeInterval = 2 * 3600
    /// When the backend last showed a sign of life, so the wait is for silence, not a fixed total time.
    @ObservationIgnored private var remoteActivity = ContinuousClock.now
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var locationCalls: Set<String> = []
    @ObservationIgnored private var locationHold: Task<Void, Never>?
    @ObservationIgnored private var shownReported: Set<String> = []
    @ObservationIgnored private var lastGesturePresence: Date?
    @ObservationIgnored private var indicatorCache: (key: IndicatorKey, images: [G2ImageBox])?

    private struct IndicatorKey: Equatable {
        var state: IndicatorState
        var attention: Bool
        var location: Bool
    }

    /// - Parameters:
    ///   - brain: the offline brain, used when the backend can't be reached.
    ///   - remote: the backend as a brain (`BackendBrain`).
    ///   - backend: the backend connection: inbox sync, perform/undo, presence, catch-ups and
    ///     location-access events all come through it.
    ///   - inbox: defaults to the backend's own store.
    ///   - indicatorIcons: where the indicator pictures come from; the built-in set by default.
    ///   - inboxSummary: the language of the today summary ("2 Mails, Termin in 10 min").
    public init(
        link: any GlassesLink, brain: any Brain, remote: (any RemoteBrain)? = nil, backend: BackendClient? = nil,
        inbox: InboxStore? = nil, toolbox: Toolbox = Toolbox(),
        speech: any SpeechRecognizer, phoneMicrophone: (any Microphone)? = nil, today: any TodayProvider,
        composer: TodayComposer = TodayComposer(), renderer: ScreenRenderer = ScreenRenderer(),
        indicatorIcons: any IndicatorIconProvider = BuiltInIndicatorIcons(), inboxSummary: InboxSummary = .system,
        timing: Timing = Timing(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.link = link
        self.imuDemand = IMUDemand(link: link)
        self.brain = brain
        self.remote = remote
        self.backend = backend
        self.inbox = inbox ?? backend?.inbox ?? InboxStore()
        self.indicators = IndicatorRenderer(icons: indicatorIcons)
        self.summary = inboxSummary
        self.toolbox = toolbox
        self.speech = speech
        self.phoneMicrophone = phoneMicrophone
        self.todayProvider = today
        self.composer = composer
        self.renderer = renderer
        self.timing = timing
        self.now = now
        if let backend {
            let events = backend.events()
            eventsTask = Task { [weak self] in
                for await event in events { self?.handle(event) }
            }
        }
    }

    deinit {
        eventsTask?.cancel()
    }

    /// Handle gestures until the stream ends.
    public func run() async {
        brain.prewarm()
        Task { await speech.prepare() }
        for await event in link.inputs() {
            handle(event)
        }
    }

    /// Open the today view when you look up. On by default.
    public private(set) var headTracking = true

    public func setHeadTracking(_ enabled: Bool) async {
        headTracking = enabled
        await syncHeadUpDemand()
    }

    /// Head-up detection holds one `imuDemand` token while it is on. The mascot shares the same
    /// demand, so neither can cut the other's feed. Serialised: a call while an acquire or release
    /// is still running returns at once, and the running loop catches up with `headTracking`, so
    /// two quick calls never take two tokens.
    private func syncHeadUpDemand() async {
        guard !syncingHeadUp else { return }
        syncingHeadUp = true
        defer { syncingHeadUp = false }
        while true {
            if headTracking, headUpToken == nil {
                headUpToken = await imuDemand.acquire("headUp")
            } else if !headTracking, let token = headUpToken {
                headUpToken = nil
                await imuDemand.release(token)
            } else {
                return
            }
        }
    }

    /// Call after the glasses (re)connect: the page is new, so redraw, and turn head tracking on.
    public func glassesConnected() async {
        shownFrame = nil
        backend?.presence(.glassesConnected)
        await syncHeadUpDemand()
        await imuDemand.reassert()
        draw()
    }

    /// Call when the glasses disconnect.
    public func glassesDisconnected() {
        backend?.presence(.glassesDisconnected)
    }

    /// Redraw the glasses' indicators after the inbox changed outside the backend's events
    /// (the app edited `inbox` directly).
    public func refreshIndicators() { draw() }

    /// Switch the layout variant for the choices. The frame carries the style, so the link
    /// rebuilds the page geometry and the next answers build their rails to fit it.
    public func setDisplayStyle(_ style: DisplayStyle) {
        renderer.style = style
        draw()
    }

    // MARK: - Gestures

    public func handle(_ event: InputEvent) {
        log("\(event) in \(mode)")
        // The IMU can be on for the mascot alone: head-up only counts while head-up is switched on.
        if event.source == .imu, !headTracking, event.gesture == .headUp || event.gesture == .headDown { return }
        reportPresence(event)
        switch event.gesture {
        case .worn: showHeldCatchup()  // otherwise presence only; nothing to show
        case .removed: if mode != .off { turnOff() }
        case .longPress:
            // Display off: only "double tap, then hold" talks (the double tap opens today first).
            guard mode != .off else { return log("hold ignored: display off, no double tap first") }
            startListening()
        case .longPressEnd: if mode == .listening { stopListening() }
        case .headUp: if mode == .off { showToday(byHead: true) }
        case .headDown: if mode == .today(byHead: true) { turnOff() }
        case .tap: tap()
        case .doubleTap where mode == .off: showToday(byHead: false)
        case .doubleTap: back()
        case .scrollDown: moveHighlight(down: true)
        case .scrollUp: moveHighlight(down: false)
        }
    }

    private func tap() {
        switch mode {
        case .off, .done: break  // a single tap alone does nothing; a double tap opens today
        case .today, .showing:
            guard let item = screen?.rail?.current else { return restartIdleTimer() }
            pick(item.action)
        case .listening, .working: break
        }
    }

    private func back() {
        switch mode {
        case .listening:
            cancelListening()
            turnOff()
        case .working:
            thinking?.cancel()
            turnOff()
        case .showing where !backStack.isEmpty:
            let previous = backStack.removeLast()
            mode = previous.kind == .today ? .today(byHead: false) : .showing
            show(previous)
        default:
            turnOff()
        }
    }

    private func moveHighlight(down: Bool) {
        guard var current = screen, var rail = current.rail else { return }
        if down { rail.moveDown() } else { rail.moveUp() }
        current.rail = rail
        // Scrolling a head-up today view keeps it open like a touched one.
        if case .today = mode { mode = .today(byHead: false) }
        show(current)
    }

    private func pick(_ action: RailAction) {
        switch action {
        case .ask(let question):
            ask(question)
        case .show(let next):
            if let current = screen { backStack.append(current) }
            mode = .showing
            show(next)
        case .dismiss:
            turnOff()
        case .perform(let action):
            perform(action)
        case .undo(let undo):
            undoAction(undo)
        case .openInbox(let page):
            if let current = screen, current.kind != .list { backStack.append(current) }
            mode = .showing
            show(inboxScreen(page: page))
        case .openItem(let id):
            openItem(id)
        case .dismissItem(let id):
            dismissItem(id)
        }
    }

    /// Tells the backend what the glasses and you are doing. Scrolls don't count; other gestures
    /// at most every 5 s.
    private func reportPresence(_ event: InputEvent) {
        guard let backend else { return }
        switch event.gesture {
        case .worn: backend.presence(.glassesWorn)
        case .removed: backend.presence(.glassesRemoved)
        case .headUp: backend.presence(.headUp)
        case .headDown, .scrollUp, .scrollDown: break
        case .tap, .doubleTap, .longPress, .longPressEnd:
            let time = now()
            if let last = lastGesturePresence, time.timeIntervalSince(last) < 5 { return }
            lastGesturePresence = time
            backend.presence(.gesture, detail: event.gesture.rawValue)
        }
    }

    // MARK: - Screens

    private func showToday(byHead: Bool) {
        backStack = []
        mode = .today(byHead: byHead)
        let info = TodayInfo(now: now(), events: today?.events ?? [], weather: today?.weather)
        show(todayScreen(info), timeout: !byHead)
        Task {
            let fresh = await todayProvider.today(at: now())
            today = fresh
            // Redraw only if the today view is still up and the facts changed.
            guard case .today = mode, let current = screen, current.kind == .today else { return }
            var updated = todayScreen(fresh)
            if let rail = current.rail, let fresh = updated.rail, rail.items.map(\.title) == fresh.items.map(\.title) {
                updated.rail = Rail(fresh.items, highlighted: rail.highlighted)
            }
            if updated != current { show(updated, timeout: mode == .today(byHead: false)) }
        }
    }

    /// The today view with the inbox in it: a short summary of what's pending in front of
    /// Lotti's sentence, and a choice for the list of all items (first while something is pending).
    private func todayScreen(_ info: TodayInfo) -> Screen {
        var screen = composer.screen(for: info)
        // Catch-up after the today choices; on a short rail Agenda/Weather make room, not it or "All items".
        let catchup = lastCatchup.flatMap { brief in
            now().timeIntervalSince(brief.received) <= Self.catchupChoiceMaxAge ? [RailItem("Catch-up", .show(Screen(.says, brief.catchup.text)))] : nil
        } ?? []
        let active = inbox.active(at: now())
        let pending = active.filter { $0.status == .pending }
        let all = active.isEmpty ? [] : [RailItem(summary.german ? "Alle ansehen" : "All items", .openInbox(page: 0))]
        let (lead, tail) = pending.isEmpty ? ([RailItem](), catchup + all) : (all, catchup)
        guard !lead.isEmpty || !tail.isEmpty else { return screen }
        if !pending.isEmpty {
            screen.text = summary.line(pending, now: now()) + ". " + screen.text
            reportShown(pending)
        }
        let limit = renderer.style.maxRailItems
        let today = (screen.rail?.items ?? []).prefix(max(limit - lead.count - tail.count, 0))
        screen.rail = Rail(lead + today + tail, limit: limit)
        return screen
    }

    private static let inboxPageSize = 3

    /// The list of all items: three per page, "More" for the rest.
    private func inboxScreen(page: Int) -> Screen {
        let items = inbox.active(at: now())
        let start = min(max(page, 0) * Self.inboxPageSize, max(items.count - 1, 0))
        let slice = Array(items.dropFirst(start).prefix(Self.inboxPageSize))
        reportShown(slice)
        var rail = slice.map { RailItem("\(summary.label($0.kind)): \($0.title)", .openItem($0.id)) }
        if items.count > start + Self.inboxPageSize { rail.append(RailItem(summary.german ? "Mehr" : "More", .openInbox(page: page + 1))) }
        let text = items.isEmpty
            ? (summary.german ? "Nichts offen." : "Nothing waiting.")
            : (summary.german ? "\(items.count) offen." : "\(items.count) waiting.")
        return Screen(.list, text, rail: Rail(rail, limit: renderer.style.maxRailItems))
    }

    /// One item in full, word for word, with its actions and Dismiss.
    private func itemScreen(_ item: InboxItem) -> Screen {
        var rail = item.actions.map { RailItem($0.title, .perform($0)) }
        rail.append(RailItem(summary.german ? "Verwerfen" : "Dismiss", .dismissItem(item.id)))
        return Screen(.original, item.body.isEmpty ? item.summary : item.body,
                      details: ["\(summary.label(item.kind)) · \(item.title)"], rail: Rail(rail, limit: renderer.style.maxRailItems))
    }

    private func openItem(_ id: String) {
        guard let item = inbox.item(id) else { return }
        if let backend { backend.inboxEvent(id, .opened) } else { inbox.setStatus(id, .seen) }
        if let current = screen { backStack.append(current) }
        mode = .showing
        show(itemScreen(item))
        draw()
    }

    private func dismissItem(_ id: String) {
        if let backend { backend.inboxEvent(id, .dismissed) } else { inbox.setStatus(id, .dismissed) }
        backStack.removeAll { $0.kind == .list }
        if inbox.active(at: now()).isEmpty {
            backStack = []
            mode = .done
            show(Screen(.done, summary.german ? "Verworfen." : "Dismissed."))
        } else {
            mode = .showing
            show(inboxScreen(page: 0))
        }
        draw()
    }

    /// Tell the backend which items were put in front of you, once each.
    private func reportShown(_ items: [InboxItem]) {
        for item in items where !shownReported.contains(item.id) {
            shownReported.insert(item.id)
            backend?.inboxEvent(item.id, .shown)
        }
    }

    // MARK: - Backend events

    private func handle(_ event: BackendEvent) {
        switch event {
        case .inboxChanged, .push:
            // Never a screen: only the indicator changes (and only while the display is off).
            draw()
        case .locationAccess(let access):
            locationAccess(access)
        case .catchup(let catchup):
            showCatchup(catchup)
        default:
            break
        }
    }

    private func locationAccess(_ access: LocationAccess) {
        switch access.phase {
        case .start:
            locationHold?.cancel()
            locationCalls.insert(access.callId)
            locationActive = true
            draw()
        case .end:
            locationCalls.remove(access.callId)
            guard locationCalls.isEmpty else { return }
            locationHold?.cancel()
            locationHold = Task { [weak self, timing] in
                try? await Task.sleep(for: timing.locationAfter)
                guard !Task.isCancelled, let self else { return }
                self.locationActive = false
                self.draw()
            }
        }
    }

    /// A catch-up brief arrives as a short answer-like screen, but only while the display is off or
    /// shows the today view: it never interrupts a conversation. If the glasses are connected but
    /// known to be off your face, it waits for the next "worn" (at most `heldCatchupMaxAge`). An
    /// unknown wear state (not reported yet) shows it right away.
    private func showCatchup(_ catchup: Catchup) {
        lastCatchup = (catchup, now())
        if link.status.isConnected, link.wearState == .removed {
            heldCatchup = (catchup, now())
            log("catch-up held until the glasses are worn")
            return
        }
        heldCatchup = nil
        presentCatchup(catchup)
    }

    private func presentCatchup(_ catchup: Catchup) {
        switch mode {
        case .off, .today:
            backStack = []
            mode = .showing
            show(Screen(.says, catchup.text))
        default:
            break
        }
    }

    private func showHeldCatchup() {
        guard let held = heldCatchup else { return }
        heldCatchup = nil
        guard now().timeIntervalSince(held.received) <= Self.heldCatchupMaxAge else { return log("held catch-up too old, dropped") }
        presentCatchup(held.catchup)
    }

    private func turnOff() {
        let hadConversation = lastAsked != nil
        timer?.cancel()
        backStack = []
        mode = .off
        screen = nil
        draw()
        if hadConversation {
            lastAsked = nil
            endConversation()
            brain.prewarm()
        }
    }

    private func endConversation() {
        brain.endConversation()
    }

    private func show(_ next: Screen, timeout: Bool = true) {
        screen = next
        draw()
        if next.kind == .done {
            startTimer(timing.done)
        } else if timeout && next.kind != .listening && next.kind != .working {
            startTimer(timing.idle)
        } else {
            timer?.cancel()
        }
    }

    private func restartIdleTimer() {
        if screen != nil, mode != .listening, mode != .working, mode != .today(byHead: true) {
            startTimer(timing.idle)
        }
    }

    private func startTimer(_ duration: Duration) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            // An unanswered or timed-out screen goes dark; the conversation stays for a while.
            self.timer = nil
            self.backStack = []
            self.mode = .off
            self.screen = nil
            self.draw()
        }
    }

    /// What the glasses should show now: the screen, plus the indicators. The attention indicator
    /// shows only while the display is off (it is a mark, never a screen, and never over text);
    /// the location icon only when there are no choices in the way.
    private func currentFrame() -> GlassesFrame {
        var frame = screen.map(renderer.render) ?? .dark
        let key = IndicatorKey(
            state: IndicatorState(attention: inbox.pendingCounts(at: now()), locationActive: locationActive),
            attention: screen == nil, location: frame.rail == nil)
        if indicatorCache?.key != key {
            indicatorCache = (key, indicators.images(for: key.state, showAttention: key.attention, showLocation: key.location))
        }
        frame.images = indicatorCache?.images ?? []
        return frame
    }

    /// Sends the newest frame. Frames that were overtaken while a send was running are skipped.
    private func draw() {
        guard !drawing else { return }
        drawing = true
        Task {
            defer { drawing = false }
            while true {
                let frame = currentFrame()
                if frame == shownFrame || !link.status.isConnected { return }
                do {
                    try await link.show(frame)
                    shownFrame = frame
                } catch {
                    lastError = error.localizedDescription
                    log("show failed: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    // MARK: - Voice

    private func startListening() {
        guard mode != .listening else { return }
        timer?.cancel()
        thinking?.cancel()
        backStack = []
        mode = .listening
        show(Screen(.listening, say("Ich höre…", "Listening…")), timeout: false)
        lastPartial = ""
        micStopRequested = false
        listening = Task { await listen() }
    }

    private func listen() async -> String {
        let audio: AsyncStream<[Int16]>
        do {
            audio = try await link.startMicrophone()
            usingPhoneMic = false
            microphoneSource = "glasses"
        } catch {
            log("glasses mic failed (\(error.localizedDescription)), using the phone's")
            guard let phoneMicrophone, let phoneAudio = try? await phoneMicrophone.start() else {
                lastError = "No microphone: \(error.localizedDescription)"
                return ""
            }
            audio = phoneAudio
            usingPhoneMic = true
            microphoneSource = "phone"
        }
        if micStopRequested { await stopMicrophone() }
        var heard = ""
        do {
            for try await transcript in speech.transcribe(audio) {
                heard = transcript.text
                lastPartial = heard.trimmingCharacters(in: .whitespacesAndNewlines)
                if mode == .listening, !heard.isEmpty { show(Screen(.listening, heard), timeout: false) }
            }
        } catch {
            log("speech failed: \(error.localizedDescription)")
            lastError = "Speech: \(error.localizedDescription)"
        }
        return heard.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stopListening() {
        guard let listening else { return }
        mode = .working
        show(Screen(.working, say("Denke nach…", "Let me think…")), timeout: false)
        thinking = Task {
            await stopMicrophone()
            // The transcript stream ends once the recognizer has the final result.
            let heard = await withTimeout(timing.finalTranscript) { await listening.value } ?? lastPartial
            self.listening = nil
            guard !Task.isCancelled, mode == .working else { return }
            lastHeard = heard
            if heard.isEmpty {
                mode = .done
                show(Screen(.done, say("Das habe ich nicht verstanden.", "Sorry, I didn't catch that.")))
            } else {
                await answer(heard)
            }
        }
    }

    /// The latest partial transcript, used if the final one doesn't arrive in time.
    @ObservationIgnored private var lastPartial = ""
    /// Set when you let go (or cancel) before the microphone finished starting.
    @ObservationIgnored private var micStopRequested = false

    private func cancelListening() {
        listening?.cancel()
        listening = nil
        Task { await stopMicrophone() }
    }

    private func stopMicrophone() async {
        micStopRequested = true
        if usingPhoneMic { await phoneMicrophone?.stop() } else { await link.stopMicrophone() }
    }

    // MARK: - Chat

    /// Ask Lotti something (from voice or a rail follow-up).
    public func ask(_ question: String) {
        timer?.cancel()
        listening?.cancel()
        thinking?.cancel()
        backStack = []
        mode = .working
        show(Screen(.working, say("Denke nach…", "Let me think…")), timeout: false)
        thinking = Task { await answer(question) }
    }

    /// Routes a question (see `Router`): the backend answers whenever it can be reached, the
    /// offline brain otherwise (also when the backend drops while the question is out).
    private func answer(_ question: String) async {
        if let lastAsked, now().timeIntervalSince(lastAsked) > Double(timing.conversation.components.seconds) {
            endConversation()
        }
        lastAsked = now()
        // Only the clock goes in; calendar, weather and location come from tools when needed.
        let info = TodayInfo(now: now())
        let route = Router.route(backendReachable: remote?.isReachable == true)
        log("route: \(route)")
        switch route {
        case .backend: await askBackend(question, info: info)
        case .offline: await askOffline(question, info: info)
        }
    }

    /// The offline brain: timers, navigation, reminders, the local day; everything else is a
    /// short offline sentence.
    private func askOffline(_ question: String, info: TodayInfo) async {
        let context = composer.nowLine(info)
        let brain = self.brain
        let result: Result<Answer, Error>? = await withTimeout(timing.answer) { [weak self] in
            do {
                return .success(try await brain.answer(question, context: context) { status in self?.working(status) })
            } catch {
                return .failure(error)
            }
        }
        guard !Task.isCancelled, mode == .working else { return }
        switch result {
        case .success(let answer):
            log("answer: \(answer.sentence) \(answer.followUps) actions: \(answer.actions.map(\.title))")
            mode = .showing
            show(Screen(.says, answer.sentence, rail: rail(for: answer, question: question)))
        case .failure(let error):
            mode = .showing
            lastError = error.localizedDescription
            log("brain failed: \(error.localizedDescription)")
            show(Screen(.says, say("Ich kann gerade nicht nachdenken. ", "I can't think right now. ") + error.localizedDescription,
                        rail: Rail([RailItem(tryAgain, .ask(question))])))
        case nil:
            mode = .showing
            log("brain timed out")
            brain.endConversation()
            show(Screen(.says, say("Da bin ich hängen geblieben.", "Sorry, I got stuck on that."), rail: Rail([RailItem(tryAgain, .ask(question))])))
        }
    }

    /// The backend. It answers with its own tools and the phone's (`location`, `reminders`);
    /// its status lines show on the glasses, and any sign of life restarts the quiet clock, so a
    /// long answer isn't cut off while it keeps working. If the socket drops meanwhile, the
    /// offline brain takes over.
    private func askBackend(_ question: String, info: TodayInfo) async {
        guard let remote else { return await askOffline(question, info: info) }
        let context = composer.nowLine(info)
        remoteActivity = ContinuousClock.now
        let result: Result<Answer, Error>? = await withTimeout(timing.remote, activity: { [weak self] in
            self?.remoteActivity ?? ContinuousClock.now
        }) { [weak self] in
            do {
                return .success(try await remote.answer(question, context: context,
                                                        status: { [weak self] status in self?.working(status) },
                                                        activity: { [weak self] in self?.remoteActivity = ContinuousClock.now }))
            } catch {
                return .failure(error)
            }
        }
        guard !Task.isCancelled, mode == .working else { return }
        switch result {
        case .success(let answer):
            log("backend: \(answer.sentence) \(answer.followUps) actions: \(answer.actions.map(\.title)) undo: \(answer.undo?.id ?? "-")")
            mode = .showing
            show(Screen(.says, answer.sentence, rail: rail(for: answer, question: question)))
        case .failure(let error):
            if error as? BackendError == .unreachable {
                log("backend unreachable, answering offline")
                return await askOffline(question, info: info)
            }
            mode = .showing
            lastError = "Backend: \(error.localizedDescription)"
            log("backend failed: \(error.localizedDescription)")
            show(Screen(.says, (error as? BackendError)?.errorDescription ?? say("Ich erreiche Lotti Brain gerade nicht.", "I can't reach Lotti Brain right now."),
                        rail: Rail([RailItem(tryAgain, .ask(question))])))
        case nil:
            mode = .showing
            log("backend timed out")
            show(Screen(.says, say("Lotti Brain braucht zu lange.", BackendError.timeout.errorDescription!), rail: Rail([RailItem(tryAgain, .ask(question))])))
        }
    }

    /// A status line from a brain at work ("Checking your calendar…").
    private func working(_ status: String) {
        guard mode == .working else { return }
        let line = status.hasSuffix("…") || status.hasSuffix(".") ? status : status + "…"
        show(Screen(.working, line), timeout: false)
    }

    /// Actions first (Lotti's best guess), then follow-ups, and Undo last when the backend already
    /// did something: a stray tap on the best guess should not take it back. A delete can't be
    /// undone, so it goes after the follow-ups too instead of under the highlight. A short rail
    /// drops follow-ups, never an action.
    private func rail(for answer: Answer, question: String) -> Rail {
        let limit = renderer.style.maxRailItems
        let (destructive, actions) = (answer.actions.filter(\.isDestructive), answer.actions.filter { !$0.isDestructive })
        let room = max(limit - answer.actions.count - (answer.undo == nil ? 0 : 1), 0)
        var items = actions.map { RailItem($0.title, .perform($0)) }
        items += answer.followUps.prefix(room).map { RailItem($0, .ask($0)) }
        items += destructive.map { RailItem($0.title, .perform($0)) }
        if let undo = answer.undo {
            items = Array(items.prefix(limit - 1)) + [undoItem(undo)]
        }
        return Rail(items, limit: limit)
    }

    /// Runs an action you tapped, then says how it went. Phone actions run through the
    /// `Toolbox`, server actions through the backend's `perform`.
    private func perform(_ action: ProposedAction) {
        timer?.cancel()
        thinking?.cancel()
        if let current = screen { backStack.append(current) }
        mode = .working
        if action.target == .server {
            show(Screen(.working, say("Mache ich…", "Working…")), timeout: false)
            guard let backend, let id = action.actionId else { return finished(ToolResult(id: action.title, ok: false, content: notConnected), undo: nil) }
            thinking = Task {
                do {
                    let performed = try await backend.perform(actionId: id)
                    guard !Task.isCancelled, mode == .working else { return }
                    log("performed server action \(id): \(performed.ok ? "ok" : "failed") \(performed.text)")
                    finished(ToolResult(id: id, ok: performed.ok, content: performed.text), undo: performed.undo)
                } catch {
                    guard !Task.isCancelled, mode == .working else { return }
                    finished(ToolResult(id: id, ok: false, content: error.localizedDescription), undo: nil)
                }
            }
            return
        }
        let progress = toolbox.tool(named: action.tool)?.spec.progress ?? say("Mache ich…", "Working…")
        show(Screen(.working, progress), timeout: false)
        let toolbox = self.toolbox
        thinking = Task {
            let result = await toolbox.perform(action)
            guard !Task.isCancelled, mode == .working else { return }
            log("performed \(action.tool): \(result.ok ? "ok" : "failed") \(result.content)")
            finished(result, undo: nil)
        }
    }

    /// Takes back what the backend just did (the Undo choice).
    private func undoAction(_ undo: UndoAction) {
        timer?.cancel()
        thinking?.cancel()
        backStack = []
        mode = .working
        show(Screen(.working, say("Mache rückgängig…", "Undoing…")), timeout: false)
        guard let backend else { return finished(ToolResult(id: undo.id, ok: false, content: notConnected), undo: nil) }
        thinking = Task {
            do {
                let performed = try await backend.undo(undo.id)
                guard !Task.isCancelled, mode == .working else { return }
                log("undo \(undo.id): \(performed.ok ? "ok" : "failed") \(performed.text)")
                // The backend's text repeats its raw label ("Undone: Remove Milch again"): say it plainly.
                finished(ToolResult(id: undo.id, ok: performed.ok,
                                    content: performed.ok ? say("Rückgängig gemacht.", "Undone.") : performed.text), undo: nil)
            } catch {
                guard !Task.isCancelled, mode == .working else { return }
                finished(ToolResult(id: undo.id, ok: false, content: error.localizedDescription), undo: nil)
            }
        }
    }

    /// The end of a tap: a done line, or the backend's `undo` as a choice, or what went wrong.
    private func finished(_ result: ToolResult, undo: UndoAction?) {
        if result.ok {
            backStack = []
            if let undo {
                mode = .showing
                show(Screen(.says, result.content, rail: Rail([undoItem(undo)])))
            } else {
                mode = .done
                show(Screen(.done, result.content))
            }
        } else {
            lastError = result.content
            mode = .showing
            show(Screen(.says, say("Hat nicht geklappt: ", "That didn't work: ") + result.content))
        }
    }

    /// The Undo choice. The backend's label describes the inverse ("Remove Milch again"), which
    /// reads like a new action on the lens, so the choice just says Undo.
    private func undoItem(_ undo: UndoAction) -> RailItem {
        RailItem(say("Rückgängig", "Undo"), .undo(undo))
    }

    // MARK: - Language

    /// The glasses' own words follow the same language as the inbox summary.
    private func say(_ german: String, _ english: String) -> String { summary.german ? german : english }
    private var tryAgain: String { say("Nochmal", "Try again") }
    private var notConnected: String { say("Lotti Brain ist nicht verbunden.", "Lotti Brain isn't connected.") }

    private func log(_ message: String) {
        print("[Lotti] \(message)")
    }
}
