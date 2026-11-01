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

    @Test func tapOpensTheTodayViewAndDoubleTapClosesIt() async throws {
        press(.tap)
        #expect(conductor.mode == .today(byHead: false))
        try await eventually { link.frames.last?.main.contains("Your calendar is free today.") == true }
        press(.doubleTap)
        #expect(conductor.mode == .off)
        try await eventually { link.frames.last == .dark }
    }

    @Test func lookingUpOpensAndLookingDownCloses() async throws {
        press(.headUp)
        #expect(conductor.mode == .today(byHead: true))
        press(.headDown)
        #expect(conductor.mode == .off)
    }

    @Test func lookingDownKeepsATouchedTodayView() {
        press(.tap)
        press(.headDown)
        #expect(conductor.mode == .today(byHead: false))
    }

    @Test func touchedTodayViewGoesDarkWhenIdle() async throws {
        press(.tap)
        try await eventually(timeout: 2) { conductor.mode == .off }
    }

    @Test func railOpensWeatherAndDoubleTapGoesBack() async throws {
        press(.tap)
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
        #expect(brain.contexts.first?.contains("Weather now: 12°C, cloudy") == true)

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

    // MARK: Voice

    @Test func holdToTalkShowsYourWordsThenTheAnswer() async throws {
        speech.script = [Transcript("What's"), Transcript("What's on today", isFinal: true)]
        brain.answers = ["What's on today": Answer(sentence: "Nothing, enjoy your Sunday.")]
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
        press(.longPress)
        try await eventually { phoneMic.on }
        press(.longPressEnd)
        try await eventually { conductor.screen?.text == "Hi!" }
        #expect(conductor.microphoneSource == "phone")
        #expect(!phoneMic.on)
    }

    @Test func longPressIsOnlyTalk() async throws {
        press(.tap)
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
    func answer(_ message: String, context: String) async throws -> Answer {
        asked.append(message)
        contexts.append(context)
        if let delay { try await Task.sleep(for: delay) }
        return answers[message] ?? Answer(sentence: "?")
    }
    func endConversation() { ended += 1 }
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
