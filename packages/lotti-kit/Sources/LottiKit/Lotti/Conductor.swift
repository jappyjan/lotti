import Foundation
import Observation

/// Runs Lotti on the glasses: turns gestures, head movement, speech and answers into screens.
///
/// Gestures (same on the ring and both touchpads):
/// - display off: tap or look up → today view
/// - scroll moves the rail highlight, tap picks it
/// - double tap: back (from a screen opened from the rail), otherwise display off, which also
///   ends the conversation
/// - long press: talk to Lotti while held (nothing else is ever on long press)
@MainActor
@Observable
public final class Conductor {
    public struct Timing: Sendable {
        /// A screen you opened goes dark after this long without a gesture.
        public var idle: Duration
        /// A "Done"-style line goes away after this.
        public var done: Duration
        /// Give up on the model after this (S3 saw rare 20–60 s stalls).
        public var answer: Duration
        /// Wait this long for the final transcript after you let go.
        public var finalTranscript: Duration
        /// A conversation older than this starts fresh.
        public var conversation: Duration
        /// Give up on Hermes after this. It may research the web; double tap cancels sooner.
        public var remote: Duration

        public init(
            idle: Duration = .seconds(30), done: Duration = .seconds(2), answer: Duration = .seconds(15),
            finalTranscript: Duration = .seconds(3), conversation: Duration = .seconds(300),
            remote: Duration = .seconds(120)
        ) {
            self.idle = idle
            self.done = done
            self.answer = answer
            self.finalTranscript = finalTranscript
            self.conversation = conversation
            self.remote = remote
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

    @ObservationIgnored private let link: any GlassesLink
    @ObservationIgnored private let brain: any Brain
    @ObservationIgnored private let hermes: (any RemoteBrain)?
    @ObservationIgnored private let toolbox: Toolbox
    @ObservationIgnored private let speech: any SpeechRecognizer
    @ObservationIgnored private let phoneMicrophone: (any Microphone)?
    @ObservationIgnored private let todayProvider: any TodayProvider
    @ObservationIgnored private let composer: TodayComposer
    @ObservationIgnored private let renderer: ScreenRenderer
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private let now: @Sendable () -> Date

    @ObservationIgnored private var backStack: [Screen] = []
    @ObservationIgnored private var today: TodayInfo?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var listening: Task<String, Never>?
    @ObservationIgnored private var thinking: Task<Void, Never>?
    @ObservationIgnored private var usingPhoneMic = false
    @ObservationIgnored private var lastAsked: Date?
    @ObservationIgnored private var shownFrame: GlassesFrame?
    @ObservationIgnored private var drawing = false
    /// The conversation moved to Hermes: follow-ups go there too, until it ends.
    @ObservationIgnored private var onHermes = false

    public init(
        link: any GlassesLink, brain: any Brain, hermes: (any RemoteBrain)? = nil, toolbox: Toolbox = Toolbox(),
        speech: any SpeechRecognizer, phoneMicrophone: (any Microphone)? = nil, today: any TodayProvider,
        composer: TodayComposer = TodayComposer(), renderer: ScreenRenderer = ScreenRenderer(),
        timing: Timing = Timing(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.link = link
        self.brain = brain
        self.hermes = hermes
        self.toolbox = toolbox
        self.speech = speech
        self.phoneMicrophone = phoneMicrophone
        self.todayProvider = today
        self.composer = composer
        self.renderer = renderer
        self.timing = timing
        self.now = now
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
        if link.status.isConnected { await link.setHeadTracking(enabled) }
    }

    /// Call after the glasses (re)connect: the page is new, so redraw, and turn head tracking on.
    public func glassesConnected() async {
        shownFrame = nil
        await link.setHeadTracking(headTracking)
        draw()
    }

    // MARK: - Gestures

    public func handle(_ event: InputEvent) {
        log("\(event) in \(mode)")
        switch event.gesture {
        case .longPress: startListening()
        case .longPressEnd: if mode == .listening { stopListening() }
        case .headUp: if mode == .off { showToday(byHead: true) }
        case .headDown: if mode == .today(byHead: true) { turnOff() }
        case .tap: tap()
        case .doubleTap: back()
        case .scrollDown: moveHighlight(down: true)
        case .scrollUp: moveHighlight(down: false)
        }
    }

    private func tap() {
        switch mode {
        case .off, .done: showToday(byHead: false)
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
        case .askHermes(let question):
            ask(question, onHermes: true)
        }
    }

    // MARK: - Screens

    private func showToday(byHead: Bool) {
        backStack = []
        mode = .today(byHead: byHead)
        let info = TodayInfo(now: now(), events: today?.events ?? [], weather: today?.weather)
        show(composer.screen(for: info), timeout: !byHead)
        Task {
            let fresh = await todayProvider.today(at: now())
            today = fresh
            // Redraw only if the today view is still up and the facts changed.
            guard case .today = mode, let current = screen, current.kind == .today else { return }
            var updated = composer.screen(for: fresh)
            if let rail = current.rail, let fresh = updated.rail, rail.items.map(\.title) == fresh.items.map(\.title) {
                updated.rail = Rail(fresh.items, highlighted: rail.highlighted)
            }
            if updated != current { show(updated, timeout: mode == .today(byHead: false)) }
        }
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
        hermes?.endConversation()
        onHermes = false
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

    /// Sends the newest frame. Frames that were overtaken while a send was running are skipped.
    private func draw() {
        guard !drawing else { return }
        drawing = true
        Task {
            defer { drawing = false }
            while true {
                let frame = screen.map(renderer.render) ?? .dark
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
        show(Screen(.listening, "Listening…"), timeout: false)
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
        show(Screen(.working, "Let me think…"), timeout: false)
        thinking = Task {
            await stopMicrophone()
            // The transcript stream ends once the recognizer has the final result.
            let heard = await withTimeout(timing.finalTranscript) { await listening.value } ?? lastPartial
            self.listening = nil
            guard !Task.isCancelled, mode == .working else { return }
            lastHeard = heard
            if heard.isEmpty {
                mode = .done
                show(Screen(.done, "Sorry, I didn't catch that."))
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

    /// Ask Lotti something (from voice or a rail follow-up). `onHermes` sends it straight to Hermes.
    public func ask(_ question: String, onHermes toHermes: Bool = false) {
        timer?.cancel()
        listening?.cancel()
        thinking?.cancel()
        backStack = []
        mode = .working
        show(Screen(.working, toHermes ? "Asking Hermes…" : "Let me think…"), timeout: false)
        thinking = Task { await answer(question, onHermes: toHermes) }
    }

    /// Routes a question: to Hermes when you asked for it ("Hermes, …", the rail's "Ask Hermes"),
    /// when the conversation is already there, or when the on-device brain hands it over;
    /// otherwise the on-device brain answers.
    private func answer(_ question: String, onHermes toHermes: Bool = false) async {
        if let lastAsked, now().timeIntervalSince(lastAsked) > Double(timing.conversation.components.seconds) {
            endConversation()
        }
        lastAsked = now()
        let info = await todayProvider.today(at: now())
        today = info
        if toHermes || onHermes { return await askHermes(question, info: info) }
        if let explicit = HermesRoute.explicitQuestion(question) { return await askHermes(explicit, info: info) }

        let context = composer.promptSummary(info)
        let brain = self.brain
        let result: Result<Answer, Error>? = await withTimeout(timing.answer) {
            do { return .success(try await brain.answer(question, context: context)) } catch { return .failure(error) }
        }
        guard !Task.isCancelled, mode == .working else { return }
        switch result {
        case .success(let answer):
            log("answer: \(answer.sentence) \(answer.followUps) actions: \(answer.actions.map(\.title)) handoff: \(answer.handoff ?? "-")")
            if let handoff = answer.handoff {
                guard hermes?.isConfigured == true else {
                    mode = .showing
                    return show(Screen(.says, "I can't look that up on my own, and Hermes isn't set up yet."))
                }
                return await askHermes(handoff, info: info)
            }
            mode = .showing
            show(Screen(.says, answer.sentence, rail: rail(for: answer, question: question, offerHermes: true)))
        case .failure(let error):
            mode = .showing
            lastError = error.localizedDescription
            log("brain failed: \(error.localizedDescription)")
            show(Screen(.says, "I can't think right now. \(error.localizedDescription)",
                        rail: Rail([RailItem("Try again", .ask(question))])))
        case nil:
            mode = .showing
            log("brain timed out")
            brain.endConversation()
            show(Screen(.says, "Sorry, I got stuck on that.", rail: Rail([RailItem("Try again", .ask(question))])))
        }
    }

    private func askHermes(_ question: String, info: TodayInfo) async {
        guard let hermes, hermes.isConfigured else {
            mode = .showing
            return show(Screen(.says, "Hermes isn't set up yet. Add it in the Lotti app."))
        }
        onHermes = true
        if mode == .working { show(Screen(.working, "Asking Hermes…"), timeout: false) }
        let context = composer.nowLine(info)
        let result: Result<Answer, Error>? = await withTimeout(timing.remote) { [weak self] in
            do {
                return .success(try await hermes.answer(question, context: context) { [weak self] status in
                    self?.working(status)
                })
            } catch {
                return .failure(error)
            }
        }
        guard !Task.isCancelled, mode == .working else { return }
        mode = .showing
        switch result {
        case .success(let answer):
            log("hermes: \(answer.sentence) \(answer.followUps) actions: \(answer.actions.map(\.title))")
            show(Screen(.says, answer.sentence, rail: rail(for: answer, question: question, offerHermes: false)))
        case .failure(let error):
            lastError = "Hermes: \(error.localizedDescription)"
            log("hermes failed: \(error.localizedDescription)")
            show(Screen(.says, (error as? HermesError)?.errorDescription ?? "I can't reach Hermes right now.",
                        rail: Rail([RailItem("Try again", .askHermes(question))])))
        case nil:
            log("hermes timed out")
            show(Screen(.says, "Hermes is taking too long.", rail: Rail([RailItem("Try again", .askHermes(question))])))
        }
    }

    /// A status line from a brain at work ("Checking your calendar…").
    private func working(_ status: String) {
        guard mode == .working else { return }
        let line = status.hasSuffix("…") || status.hasSuffix(".") ? status : status + "…"
        show(Screen(.working, line), timeout: false)
    }

    /// Actions first (Lotti's best guess), then follow-ups, then "Ask Hermes" if there's room.
    private func rail(for answer: Answer, question: String, offerHermes: Bool) -> Rail {
        var items = answer.actions.map { RailItem($0.title, .perform($0)) }
        items += answer.followUps.map { RailItem($0, .ask($0)) }
        if offerHermes, hermes?.isConfigured == true {
            items = Array(items.prefix(Rail.maxItems - 1)) + [RailItem("Ask Hermes", .askHermes(question))]
        }
        return Rail(items)
    }

    /// Runs an action you tapped, then says how it went.
    private func perform(_ action: ProposedAction) {
        timer?.cancel()
        thinking?.cancel()
        if let current = screen { backStack.append(current) }
        mode = .working
        show(Screen(.working, action.title + "…"), timeout: false)
        let toolbox = self.toolbox
        thinking = Task {
            let result = await toolbox.perform(action)
            guard !Task.isCancelled, mode == .working else { return }
            log("performed \(action.tool): \(result.ok ? "ok" : "failed") \(result.content)")
            if result.ok {
                backStack = []
                mode = .done
                show(Screen(.done, result.content))
            } else {
                lastError = result.content
                mode = .showing
                show(Screen(.says, "That didn't work: \(result.content)"))
            }
        }
    }

    private func log(_ message: String) {
        print("[Lotti] \(message)")
    }
}
