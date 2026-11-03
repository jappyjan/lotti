import Foundation
import Testing
@testable import LottiKit

@MainActor
struct ConductorTests {
    let link = FakeGlassesLink()
    let brain = FakeBrain()
    let speech = FakeSpeech()
    let phoneMic = FakeMicrophone()
    let conductor: Conductor

    init() async {
        await link.connect(DiscoveredGlasses(id: "32", name: "G2"))
        conductor = Conductor(
            link: link, brain: brain, speech: speech, phoneMicrophone: phoneMic,
            today: FixedToday(info: TodayInfo(now: Date(), events: [], weather: Weather(temperature: 12, condition: "cloudy"))),
            timing: .init(idle: .milliseconds(300), done: .milliseconds(100), answer: .milliseconds(200),
                          finalTranscript: .milliseconds(200)))
    }

    func press(_ gesture: InputEvent.Gesture) { conductor.handle(InputEvent(gesture, from: .ring)) }

    // MARK: Today view

    @Test func doubleTapOpensTheTodayViewAndDoubleTapClosesIt() async throws {
        press(.doubleTap)
        #expect(conductor.mode == .today(byHead: false))
        try await eventually { link.frames.last?.main.contains("Your calendar is free today.") == true }
        press(.doubleTap)
        #expect(conductor.mode == .off)
        try await eventually { link.frames.last == .dark }
    }

    @Test func aSingleTapDoesNotWakeTheDisplay() {
        press(.tap)
        #expect(conductor.mode == .off)
        press(.tap)
        #expect(conductor.mode == .off)
    }

    @Test func lookingUpOpensAndLookingDownCloses() async throws {
        press(.headUp)
        #expect(conductor.mode == .today(byHead: true))
        press(.headDown)
        #expect(conductor.mode == .off)
    }

    @Test func lookingDownKeepsATouchedTodayView() {
        press(.doubleTap)
        press(.headDown)
        #expect(conductor.mode == .today(byHead: false))
    }

    @Test func touchedTodayViewGoesDarkWhenIdle() async throws {
        press(.doubleTap)
        try await eventually(timeout: 2) { conductor.mode == .off }
    }

    @Test func railOpensWeatherAndDoubleTapGoesBack() async throws {
        press(.doubleTap)
        try await eventually { conductor.screen?.rail?.items.map(\.title) == ["Weather"] }
        press(.tap)
        #expect(conductor.mode == .showing)
        #expect(conductor.screen?.text == "12° and cloudy.")
        press(.doubleTap)
        #expect(conductor.screen?.kind == .today)
        press(.doubleTap)
        #expect(conductor.mode == .off)
    }

    // MARK: Chat

    @Test func followUpFromTheRailAsksLotti() async throws {
        brain.answers = ["Rain?": Answer(sentence: "No rain today.", followUps: ["Tomorrow?", "Wind?"])]
        conductor.ask("Rain?")
        #expect(conductor.screen?.kind == .working)
        try await eventually { conductor.screen?.text == "No rain today." }
        #expect(conductor.screen?.rail?.items.map(\.title) == ["Tomorrow?", "Wind?"])
        #expect(brain.contexts.first?.hasPrefix("Now: ") == true)
        #expect(brain.contexts.first?.contains("Weather") == false)  // facts come from tools

        brain.answers["Wind?"] = Answer(sentence: "A light breeze.")
        press(.scrollDown)
        press(.tap)
        try await eventually { conductor.screen?.text == "A light breeze." }
        #expect(brain.asked == ["Rain?", "Wind?"])
    }

    @Test func dismissingEndsTheConversation() async throws {
        brain.answers = ["Hi": Answer(sentence: "Hi Jan!")]
        conductor.ask("Hi")
        try await eventually { conductor.mode == .showing }
        press(.doubleTap)
        #expect(brain.ended == 1)
    }

    @Test func aStuckModelTimesOutWithTryAgain() async throws {
        brain.delay = .seconds(5)
        conductor.ask("Hi")
        try await eventually(timeout: 2) { conductor.screen?.text == "Sorry, I got stuck on that." }
        #expect(conductor.screen?.rail?.current?.action == .ask("Hi"))
    }

    @Test func doubleTapWhileWorkingCancels() async throws {
        brain.delay = .seconds(5)
        conductor.ask("Hi")
        press(.doubleTap)
        #expect(conductor.mode == .off)
    }

    // MARK: Tools and Hermes

    func conductorWithHermes(_ hermes: FakeHermes, tools: [any PhoneTool] = []) -> Conductor {
        Conductor(
            link: link, brain: brain, hermes: hermes, toolbox: Toolbox(tools), speech: speech, phoneMicrophone: phoneMic,
            today: FixedToday(info: TodayInfo(now: Date())),
            timing: .init(idle: .milliseconds(300), done: .milliseconds(100), answer: .milliseconds(200),
                          finalTranscript: .milliseconds(200), remote: .milliseconds(400)))
    }

    @Test func openQuestionsGoToHermesAndSoDoTheirFollowUps() async throws {
        let hermes = FakeHermes()
        let conductor = conductorWithHermes(hermes)
        hermes.answers = ["Tell me about the election": Answer(sentence: "Mostly about taxes.", followUps: ["Polls?"])]
        conductor.ask("Tell me about the election")
        try await eventually { conductor.screen?.text == "Mostly about taxes." }
        #expect(hermes.contexts.first?.hasPrefix("Now: ") == true)
        #expect(hermes.contexts.first?.contains("Calendar") == false)  // Hermes asks for what it needs

        hermes.answers["Polls?"] = Answer(sentence: "Close race.")
        conductor.handle(InputEvent(.tap, from: .ring))
        try await eventually { conductor.screen?.text == "Close race." }
        #expect(brain.asked.isEmpty)
        #expect(hermes.asked == ["Tell me about the election", "Polls?"])

        conductor.handle(InputEvent(.doubleTap, from: .ring))
        #expect(brain.ended == 1)  // the on-device conversation ends
    }

    @Test func glassesOffEndsOnlyTheOnDeviceBrainAndKeepsTheHermesSession() async throws {
        let transport = ScriptedHermes([#"{"type":"answer","sentence":"One."}"#, #"{"type":"answer","sentence":"Two."}"#])
        let store = FakeHermesSessionStore()
        let hermes = HermesBrain(transport: transport, toolbox: Toolbox(), allowedReads: { [] }, isConfigured: { true },
                                 store: store)
        let conductor = Conductor(
            link: link, brain: brain, hermes: hermes, speech: speech, phoneMicrophone: phoneMic,
            today: FixedToday(info: TodayInfo(now: Date())),
            timing: .init(idle: .milliseconds(300), done: .milliseconds(100), answer: .milliseconds(200),
                          finalTranscript: .milliseconds(200), remote: .milliseconds(400)))
        conductor.ask("Tell me about the election", onHermes: true)
        try await eventually { conductor.screen?.text == "One." }
        let session = try #require(hermes.sessionID)
        conductor.handle(InputEvent(.doubleTap, from: .ring))
        #expect(conductor.mode == .off)
        #expect(brain.ended == 1)
        #expect(hermes.sessionID == session)

        conductor.ask("And the polls?", onHermes: true)
        try await eventually { conductor.screen?.text == "Two." }
        #expect(transport.sessions == [session, session])
    }

    @Test func theOnDeviceGapEndsOnlyTheOnDeviceConversation() async throws {
        let transport = ScriptedHermes([#"{"type":"answer","sentence":"One."}"#, #"{"type":"answer","sentence":"Two."}"#])
        let hermes = HermesBrain(transport: transport, toolbox: Toolbox(), allowedReads: { [] }, isConfigured: { true })
        let clock = ManualClock(Date(timeIntervalSince1970: 0))
        let conductor = Conductor(
            link: link, brain: brain, hermes: hermes, speech: speech, phoneMicrophone: phoneMic,
            today: FixedToday(info: TodayInfo(now: Date())),
            timing: .init(idle: .milliseconds(300), done: .milliseconds(100), answer: .milliseconds(200),
                          finalTranscript: .milliseconds(200), remote: .milliseconds(400)),
            now: { clock.now })
        conductor.ask("Tell me about the election", onHermes: true)
        try await eventually { conductor.screen?.text == "One." }
        clock.now = Date(timeIntervalSince1970: 301)  // past timing.conversation (300 s)
        conductor.ask("And the polls?", onHermes: true)
        try await eventually { conductor.screen?.text == "Two." }
        #expect(brain.ended == 1)
        #expect(transport.sessions.count == 2 && Set(transport.sessions).count == 1)  // Hermes continues
    }

    @Test func doubleTapWhileHermesThinksDropsTheQuestion() async throws {
        let transport = ScriptedHermes([#"{"type":"answer","sentence":"Too late."}"#])
        transport.delay = .milliseconds(150)
        let store = FakeHermesSessionStore()
        let hermes = HermesBrain(transport: transport, toolbox: Toolbox(), allowedReads: { [] }, isConfigured: { true },
                                 store: store)
        let conductor = Conductor(
            link: link, brain: brain, hermes: hermes, speech: speech, phoneMicrophone: phoneMic,
            today: FixedToday(info: TodayInfo(now: Date())),
            timing: .init(idle: .milliseconds(300), done: .milliseconds(100), answer: .milliseconds(200),
                          finalTranscript: .milliseconds(200), remote: .milliseconds(400)))
        conductor.ask("Tell me about the election", onHermes: true)
        try await eventually { conductor.mode == .working && !transport.requests.isEmpty }
        let session = try #require(hermes.sessionID)
        conductor.handle(InputEvent(.doubleTap, from: .ring))
        try await Task.sleep(for: .milliseconds(300))  // the answer would have arrived by now
        #expect(conductor.mode == .off)
        #expect(transport.replies.count == 1)  // the request was cancelled, not answered
        #expect(hermes.sessionID == session && store.stored == session)  // the session stays
    }

    @Test func simpleTasksGoToHermesToo() async throws {
        let hermes = FakeHermes()
        let conductor = conductorWithHermes(hermes)
        hermes.answers = ["Brauche ich einen Schirm?": Answer(sentence: "Ja, ab 15 Uhr regnet es.")]
        conductor.ask("Brauche ich einen Schirm?")
        try await eventually { conductor.screen?.text == "Ja, ab 15 Uhr regnet es." }
        #expect(hermes.asked == ["Brauche ich einen Schirm?"])
        #expect(brain.asked.isEmpty)
    }

    @Test func whenHermesFailsItSaysSoWithTryAgain() async throws {
        let hermes = FakeHermes()
        hermes.error = HermesError.http(502, "bad gateway")
        let conductor = conductorWithHermes(hermes)
        conductor.ask("Tell me a joke")
        try await eventually { conductor.screen?.text.contains("Hermes error 502") == true }
        #expect(conductor.screen?.rail?.current?.action == .askHermes("Tell me a joke"))
        #expect(brain.asked.isEmpty)
    }

    @Test func whenHermesGoesQuietItSaysSo() async throws {
        let hermes = FakeHermes()
        hermes.delay = .seconds(5)
        let conductor = conductorWithHermes(hermes)
        conductor.ask("Tell me a joke")
        try await eventually(timeout: 2) { conductor.screen?.text == "Hermes is taking too long." }
        #expect(conductor.screen?.rail?.current?.action == .askHermes("Tell me a joke"))
        #expect(brain.asked.isEmpty)
    }

    @Test func whenHermesKeepsWorkingThePhoneWaits() async throws {
        let hermes = FakeHermes()
        hermes.delay = .milliseconds(500)
        hermes.progressEvery = .milliseconds(50)
        hermes.answers = ["Tell me a joke": Answer(sentence: "Why did the raccoon cross the road?")]
        let conductor = conductorWithHermes(hermes)
        conductor.ask("Tell me a joke")
        try await eventually(timeout: 2) { conductor.screen?.text == "Why did the raccoon cross the road?" }
        #expect(brain.asked.isEmpty)  // the phone never had to stand in
    }

    @Test func hermesTrafficAloneKeepsThePhoneWaiting() async throws {
        // Answer tokens and keepalives are activity, not status lines: they must restart the
        // quiet clock just the same, or a long streaming answer gets cancelled.
        let hermes = FakeHermes()
        hermes.delay = .milliseconds(500)
        hermes.activityEvery = .milliseconds(50)
        hermes.answers = ["Tell me a joke": Answer(sentence: "Why did the raccoon cross the road?")]
        let conductor = conductorWithHermes(hermes)
        conductor.ask("Tell me a joke")
        try await eventually(timeout: 2) { conductor.screen?.text == "Why did the raccoon cross the road?" }
        #expect(brain.asked.isEmpty)
    }

    @Test func askingForHermesHasNoFallback() async throws {
        let hermes = FakeHermes()
        hermes.error = HermesError.http(401, "")
        let conductor = conductorWithHermes(hermes)
        conductor.ask("Hermes, plan my week")
        try await eventually { conductor.screen?.text == "Hermes didn't accept the key." }
        #expect(brain.asked.isEmpty)
    }

    @Test func withoutHermesThePhoneAnswersEverything() async throws {
        let hermes = FakeHermes()
        hermes.isConfigured = false
        let conductor = conductorWithHermes(hermes)
        brain.answers = ["Tell me a joke": Answer(sentence: "Okay.")]
        conductor.ask("Tell me a joke")
        try await eventually { conductor.screen?.text == "Okay." }
        #expect(hermes.asked.isEmpty)
    }

    @Test func sayingHermesSkipsTheOnDeviceBrain() async throws {
        let hermes = FakeHermes()
        let conductor = conductorWithHermes(hermes)
        hermes.answers = ["flights to Lisbon?": Answer(sentence: "From 89 € on Friday.")]
        conductor.ask("Hermes, flights to Lisbon?")
        try await eventually { conductor.screen?.text == "From 89 € on Friday." }
        #expect(brain.asked.isEmpty)
    }

    @Test func showsWhatHermesIsDoing() async throws {
        let hermes = FakeHermes()
        hermes.statuses = ["Checking your calendar"]
        hermes.delay = .milliseconds(200)
        let conductor = conductorWithHermes(hermes)
        conductor.ask("Hermes, plan my week")
        try await eventually { conductor.screen?.text == "Checking your calendar…" }
        #expect(conductor.mode == .working)
    }

    @Test func aSlowHermesTimesOutWithTryAgain() async throws {
        let hermes = FakeHermes()
        hermes.delay = .seconds(5)
        let conductor = conductorWithHermes(hermes)
        conductor.ask("Hermes, plan my week")
        try await eventually(timeout: 2) { conductor.screen?.text == "Hermes is taking too long." }
        #expect(conductor.screen?.rail?.current?.action == .askHermes("plan my week"))
    }

    @Test func anExplicitAskWithProgressKeepsWorking() async throws {
        let hermes = FakeHermes()
        hermes.delay = .milliseconds(500)
        hermes.progressEvery = .milliseconds(50)
        hermes.answers = ["plan my week": Answer(sentence: "Monday is wide open.")]
        let conductor = conductorWithHermes(hermes)
        conductor.ask("Hermes, plan my week")
        try await eventually(timeout: 2) { conductor.screen?.text == "Monday is wide open." }
        #expect(brain.asked.isEmpty)
    }

    @Test func withoutHermesTheHandoffSaysSo() async throws {
        let hermes = FakeHermes()
        hermes.isConfigured = false
        let conductor = conductorWithHermes(hermes)
        brain.answers = ["News?": Answer(sentence: "Let me ask Hermes.", handoff: "News?")]
        conductor.ask("News?")
        try await eventually { conductor.screen?.text.contains("Hermes isn't set up yet") == true }
        #expect(hermes.asked.isEmpty)
    }

    @Test func anActionRunsOnlyWhenTapped() async throws {
        let timer = FakeTool.timer()
        let hermes = FakeHermes()
        let conductor = conductorWithHermes(hermes, tools: [timer])
        let action = try #require(Toolbox([timer]).proposal(for: ToolCall(id: "a", tool: "set_timer", arguments: ["minutes": 10])))
        hermes.answers = ["Pasta timer": Answer(sentence: "Ten minutes for the pasta?", actions: [action])]
        conductor.ask("Pasta timer")
        try await eventually { conductor.screen?.text == "Ten minutes for the pasta?" }
        #expect(conductor.screen?.rail?.current?.title == "Timer 10 min")
        #expect(timer.runs.isEmpty)

        conductor.handle(InputEvent(.tap, from: .ring))
        try await eventually { conductor.screen?.text == "Timer set for 10 minutes." }
        #expect(conductor.mode == .done)
        #expect(timer.runs.count == 1)
    }

    @Test func aFailedActionSaysWhy() async throws {
        let timer = FakeTool.timer()
        timer.error = ToolError("Alarms are off for Lotti.")
        let hermes = FakeHermes()
        let conductor = conductorWithHermes(hermes, tools: [timer])
        let action = try #require(Toolbox([timer]).proposal(for: ToolCall(id: "a", tool: "set_timer", arguments: ["minutes": 1])))
        hermes.answers = ["Timer": Answer(sentence: "One minute?", actions: [action])]
        conductor.ask("Timer")
        try await eventually { conductor.screen?.text == "One minute?" }
        conductor.handle(InputEvent(.tap, from: .ring))
        try await eventually { conductor.screen?.text == "That didn't work: Alarms are off for Lotti." }
    }

    // MARK: Voice

    @Test func holdToTalkShowsYourWordsThenTheAnswer() async throws {
        speech.script = [Transcript("What's"), Transcript("What's on today", isFinal: true)]
        brain.answers = ["What's on today": Answer(sentence: "Nothing, enjoy your Sunday.")]
        press(.doubleTap)
        press(.longPress)
        #expect(conductor.mode == .listening)
        try await eventually { link.microphoneOn }
        link.sendAudio([0, 1, 2])
        try await eventually { conductor.screen?.text == "What's on today" }
        press(.longPressEnd)
        try await eventually { conductor.screen?.text == "Nothing, enjoy your Sunday." }
        #expect(!link.microphoneOn)
        #expect(conductor.lastHeard == "What's on today")
        #expect(conductor.microphoneSource == "glasses")
    }

    @Test func silenceSaysSorry() async throws {
        press(.doubleTap)
        press(.longPress)
        try await eventually { link.microphoneOn }
        press(.longPressEnd)
        try await eventually { conductor.screen?.text == "Sorry, I didn't catch that." }
        try await eventually(timeout: 2) { conductor.mode == .off }
    }

    @Test func fallsBackToThePhoneMicrophone() async throws {
        link.microphoneError = GlassesLinkError.missingCharacteristics
        speech.script = [Transcript("Hello", isFinal: true)]
        brain.answers = ["Hello": Answer(sentence: "Hi!")]
        press(.doubleTap)
        press(.longPress)
        try await eventually { phoneMic.on }
        press(.longPressEnd)
        try await eventually { conductor.screen?.text == "Hi!" }
        #expect(conductor.microphoneSource == "phone")
        #expect(!phoneMic.on)
    }

    @Test func withTheDisplayOffAHoldAloneDoesNothing() {
        press(.longPress)
        #expect(conductor.mode == .off)
        press(.longPressEnd)
        #expect(conductor.mode == .off)
    }

    @Test func withTheDisplayOffDoubleTapThenHoldTalks() {
        press(.doubleTap)
        #expect(conductor.mode == .today(byHead: false))  // the double tap opens today
        press(.longPress)
        #expect(conductor.mode == .listening)
    }

    @Test func longPressIsOnlyTalk() async throws {
        press(.doubleTap)
        press(.longPress)
        #expect(conductor.mode == .listening)
    }
}

// MARK: - Fakes

@MainActor
final class FakeBrain: Brain {
    var answers: [String: Answer] = [:]
    var delay: Duration?
    private(set) var asked: [String] = []
    private(set) var contexts: [String] = []
    private(set) var ended = 0

    func prewarm() {}
    func answer(_ message: String, context: String, status: @escaping @MainActor (String) -> Void) async throws -> Answer {
        asked.append(message)
        contexts.append(context)
        if let delay { try await Task.sleep(for: delay) }
        return answers[message] ?? Answer(sentence: "?")
    }
    func endConversation() { ended += 1 }
}

@MainActor
final class FakeHermes: RemoteBrain {
    var isConfigured = true
    var answers: [String: Answer] = [:]
    var statuses: [String] = []
    var delay: Duration?
    /// Emits one status line and one activity pulse this often while waiting, like Hermes's
    /// progress events and stream traffic.
    var progressEvery: Duration?
    /// Pulses activity alone this often while waiting, like answer tokens and keepalives
    /// (nothing to show on the glasses, but Hermes is clearly alive).
    var activityEvery: Duration?
    var error: Error?
    private(set) var asked: [String] = []
    private(set) var contexts: [String] = []
    private(set) var activities = 0

    func answer(
        _ message: String, context: String,
        status: @escaping @MainActor (String) -> Void,
        activity: @escaping @MainActor () -> Void
    ) async throws -> Answer {
        asked.append(message)
        contexts.append(context)
        for line in statuses { status(line); activity() }
        if let progressEvery, let delay {
            let end = ContinuousClock.now.advanced(by: delay)
            while ContinuousClock.now < end {
                try await Task.sleep(for: progressEvery)
                status("Working…")
                activities += 1
                activity()
            }
        } else if let activityEvery, let delay {
            let end = ContinuousClock.now.advanced(by: delay)
            while ContinuousClock.now < end {
                try await Task.sleep(for: activityEvery)
                activities += 1
                activity()
            }
        } else if let delay {
            try await Task.sleep(for: delay)
        }
        if let error { throw error }
        activities += 1
        activity()
        return answers[message] ?? Answer(sentence: "?")
    }
}

/// Yields `script` once audio arrives (or right away), and finishes when the audio ends.
@MainActor
final class FakeSpeech: SpeechRecognizer {
    var script: [Transcript] = []

    func prepare() async {}
    func transcribe(_ audio: AsyncStream<[Int16]>) -> AsyncThrowingStream<Transcript, Error> {
        let script = script
        return AsyncThrowingStream { continuation in
            let task = Task {
                for transcript in script { continuation.yield(transcript) }
                for await _ in audio {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
final class FakeMicrophone: Microphone {
    private(set) var on = false
    private var continuation: AsyncStream<[Int16]>.Continuation?

    func start() async throws -> AsyncStream<[Int16]> {
        on = true
        let (stream, continuation) = AsyncStream<[Int16]>.makeStream()
        self.continuation = continuation
        return stream
    }
    func stop() async {
        on = false
        continuation?.finish()
    }
}

struct FixedToday: TodayProvider {
    var info: TodayInfo
    func today(at now: Date) async -> TodayInfo { TodayInfo(now: now, events: info.events, weather: info.weather) }
}

struct TimedOut: Error {}

/// Polls `condition` until it holds, failing after `timeout` seconds.
@MainActor
func eventually(timeout: Double = 1, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { Issue.record("condition not met in \(timeout) s"); throw TimedOut() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// A settable clock for tests that move time forward.
final class ManualClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}
