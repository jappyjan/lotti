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

    // MARK: Backend and offline

    func conductorWithRemote(_ remote: FakeRemote, tools: [any PhoneTool] = []) -> Conductor {
        Conductor(
            link: link, brain: brain, remote: remote, toolbox: Toolbox(tools), speech: speech, phoneMicrophone: phoneMic,
            today: FixedToday(info: TodayInfo(now: Date())),
            timing: .init(idle: .milliseconds(300), done: .milliseconds(100), answer: .milliseconds(200),
                          finalTranscript: .milliseconds(200), remote: .milliseconds(400)))
    }

    @Test func questionsGoToTheBackendAndSoDoTheirFollowUps() async throws {
        let remote = FakeRemote()
        let conductor = conductorWithRemote(remote)
        remote.answers = ["Tell me about the election": Answer(sentence: "Mostly about taxes.", followUps: ["Polls?"])]
        conductor.ask("Tell me about the election")
        try await eventually { conductor.screen?.text == "Mostly about taxes." }
        #expect(remote.contexts.first?.hasPrefix("Now: ") == true)
        #expect(remote.contexts.first?.contains("Calendar") == false)  // the backend asks for what it needs

        remote.answers["Polls?"] = Answer(sentence: "Close race.")
        conductor.handle(InputEvent(.tap, from: .ring))
        try await eventually { conductor.screen?.text == "Close race." }
        #expect(brain.asked.isEmpty)
        #expect(remote.asked == ["Tell me about the election", "Polls?"])

        conductor.handle(InputEvent(.doubleTap, from: .ring))
        #expect(brain.ended == 1)  // the offline conversation ends; the backend's goes on
    }

    @Test func simpleTasksGoToTheBackendToo() async throws {
        let remote = FakeRemote()
        let conductor = conductorWithRemote(remote)
        remote.answers = ["Brauche ich einen Schirm?": Answer(sentence: "Ja, ab 15 Uhr regnet es.")]
        conductor.ask("Brauche ich einen Schirm?")
        try await eventually { conductor.screen?.text == "Ja, ab 15 Uhr regnet es." }
        #expect(brain.asked.isEmpty)
    }

    @Test func whenTheBackendIsUnreachableTheOfflineBrainAnswers() async throws {
        let remote = FakeRemote()
        remote.isReachable = false
        let conductor = conductorWithRemote(remote)
        brain.answers = ["Timer 5 Minuten": Answer(sentence: "Bereit: Timer 5 min. Tipp zum Starten.")]
        conductor.ask("Timer 5 Minuten")
        try await eventually { conductor.screen?.text == "Bereit: Timer 5 min. Tipp zum Starten." }
        #expect(remote.asked.isEmpty)
    }

    @Test func whenTheSocketDropsMidQuestionTheOfflineBrainTakesOver() async throws {
        let remote = FakeRemote()
        remote.error = BackendError.unreachable
        let conductor = conductorWithRemote(remote)
        brain.answers = ["Hi": Answer(sentence: "Offline hi.")]
        conductor.ask("Hi")
        try await eventually { conductor.screen?.text == "Offline hi." }
        #expect(remote.asked == ["Hi"])
    }

    @Test func whenTheBackendFailsItSaysSoWithTryAgain() async throws {
        let remote = FakeRemote()
        remote.error = BackendError.server("The provider is down.")
        let conductor = conductorWithRemote(remote)
        conductor.ask("Tell me a joke")
        try await eventually { conductor.screen?.text == "The provider is down." }
        #expect(conductor.screen?.rail?.current?.action == .ask("Tell me a joke"))
    }

    @Test func whenTheBackendGoesQuietItSaysSo() async throws {
        let remote = FakeRemote()
        remote.delay = .seconds(5)
        let conductor = conductorWithRemote(remote)
        conductor.ask("Tell me a joke")
        try await eventually(timeout: 2) { conductor.screen?.text == "Lotti Brain is taking too long." }
        #expect(conductor.screen?.rail?.current?.action == .ask("Tell me a joke"))
    }

    @Test func whenTheBackendKeepsWorkingThePhoneWaits() async throws {
        let remote = FakeRemote()
        remote.delay = .milliseconds(500)
        remote.progressEvery = .milliseconds(50)
        remote.answers = ["Tell me a joke": Answer(sentence: "Why did the raccoon cross the road?")]
        let conductor = conductorWithRemote(remote)
        conductor.ask("Tell me a joke")
        try await eventually(timeout: 2) { conductor.screen?.text == "Why did the raccoon cross the road?" }
    }

    @Test func backendTrafficAloneKeepsThePhoneWaiting() async throws {
        let remote = FakeRemote()
        remote.delay = .milliseconds(500)
        remote.activityEvery = .milliseconds(50)
        remote.answers = ["Tell me a joke": Answer(sentence: "Why did the raccoon cross the road?")]
        let conductor = conductorWithRemote(remote)
        conductor.ask("Tell me a joke")
        try await eventually(timeout: 2) { conductor.screen?.text == "Why did the raccoon cross the road?" }
    }

    @Test func showsWhatTheBackendIsDoing() async throws {
        let remote = FakeRemote()
        remote.statuses = ["Suche Mails"]
        remote.delay = .milliseconds(200)
        let conductor = conductorWithRemote(remote)
        conductor.ask("Plan my week")
        try await eventually { conductor.screen?.text == "Suche Mails…" }
    }

    @Test func doubleTapWhileTheBackendThinksDropsTheQuestion() async throws {
        let remote = FakeRemote()
        remote.delay = .seconds(5)
        let conductor = conductorWithRemote(remote)
        conductor.ask("Plan my week")
        try await eventually { remote.asked.count == 1 }
        conductor.handle(InputEvent(.doubleTap, from: .ring))
        #expect(conductor.mode == .off)
        try await eventually { remote.cancelled == 1 }
    }

    @Test func anActionRunsOnlyWhenTapped() async throws {
        let timer = FakeTool.timer()
        let remote = FakeRemote()
        let conductor = conductorWithRemote(remote, tools: [timer])
        let action = try #require(Toolbox([timer]).proposal(for: ToolCall(id: "a", tool: "set_timer", arguments: ["minutes": 10])))
        remote.answers = ["Pasta timer": Answer(sentence: "Ten minutes for the pasta?", actions: [action])]
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
        let remote = FakeRemote()
        let conductor = conductorWithRemote(remote, tools: [timer])
        let action = try #require(Toolbox([timer]).proposal(for: ToolCall(id: "a", tool: "set_timer", arguments: ["minutes": 1])))
        remote.answers = ["Timer": Answer(sentence: "One minute?", actions: [action])]
        conductor.ask("Timer")
        try await eventually { conductor.screen?.text == "One minute?" }
        conductor.handle(InputEvent(.tap, from: .ring))
        try await eventually { conductor.screen?.text == "That didn't work: Alarms are off for Lotti." }
    }

    @Test func anImmediateActionOffersUndoAsTheLastChoice() async throws {
        let remote = FakeRemote()
        let conductor = conductorWithRemote(remote)
        remote.answers = ["Milch auf die Liste": Answer(sentence: "Milch ist auf der Liste.", followUps: ["Noch was?"],
                                                        undo: UndoAction(id: "u1", label: "Rückgängig"))]
        conductor.ask("Milch auf die Liste")
        try await eventually { conductor.screen?.text == "Milch ist auf der Liste." }
        #expect(conductor.screen?.rail?.items.map(\.title) == ["Noch was?", "Rückgängig"])
        #expect(conductor.screen?.rail?.items.last?.action == .undo(UndoAction(id: "u1", label: "Rückgängig")))
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
final class FakeRemote: RemoteBrain {
    var isReachable = true
    var answers: [String: Answer] = [:]
    var statuses: [String] = []
    var delay: Duration?
    /// Emits one status line and one activity pulse this often while waiting, like the backend's
    /// status messages and tool calls.
    var progressEvery: Duration?
    /// Pulses activity alone this often while waiting (nothing to show on the glasses, but the
    /// backend is clearly alive).
    var activityEvery: Duration?
    var error: Error?
    private(set) var asked: [String] = []
    private(set) var contexts: [String] = []
    private(set) var activities = 0
    private(set) var cancelled = 0

    func answer(
        _ message: String, context: String,
        status: @escaping @MainActor (String) -> Void,
        activity: @escaping @MainActor () -> Void
    ) async throws -> Answer {
        asked.append(message)
        contexts.append(context)
        do {
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
        } catch {
            cancelled += 1
            throw error
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
