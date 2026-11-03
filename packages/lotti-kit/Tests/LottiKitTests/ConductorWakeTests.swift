import Foundation
import Testing
@testable import LottiKit

@MainActor
struct ConductorWakeTests {
    let link = FakeGlassesLink()
    let brain = FakeBrain()
    let speech = FakeSpeech()
    let phoneMic = FakeMicrophone()
    let classifier = FakeClassifier()
    let conductor: Conductor

    init() async {
        await link.connect(DiscoveredGlasses(id: "32", name: "G2"))
        conductor = Self.makeConductor(link: link, brain: brain, speech: speech, phoneMic: phoneMic, classifier: classifier)
    }

    static func makeConductor(
        link: FakeGlassesLink, brain: FakeBrain, speech: FakeSpeech, phoneMic: FakeMicrophone, classifier: FakeClassifier,
        watchdog: Duration = .seconds(30)
    ) -> Conductor {
        Conductor(
            link: link, brain: brain, speech: speech, phoneMicrophone: phoneMic,
            today: FixedToday(info: TodayInfo(now: Date())),
            timing: .init(idle: .milliseconds(300), done: .milliseconds(100), answer: .milliseconds(200),
                          finalTranscript: .milliseconds(200), wakeConfirm: .milliseconds(300),
                          wakeSilence: .milliseconds(100), wakeNoCommand: .milliseconds(200), wakeCap: .seconds(1),
                          micWatchdog: watchdog, micRetry: .milliseconds(20), micRetryMax: .milliseconds(100)),
            wakeDetector: WakeWordDetector(classifier: classifier))
    }

    func press(_ gesture: InputEvent.Gesture) { conductor.handle(InputEvent(gesture, from: .ring)) }

    func wakeOn() async throws {
        conductor.setWakeWord(enabled: true)
        try await eventually { conductor.wakeState == .listening }
    }

    /// One second and a bit of loud audio with the classifier's marker in it: a candidate.
    func sayHeyLotti() {
        for index in 0..<24 {
            var chunk = [Int16](repeating: 3000, count: 800)
            if index == 2 { chunk[0] = FakeClassifier.marker }
            link.sendAudio(chunk)
        }
    }

    func talk(_ chunks: Int) { for _ in 0..<chunks { link.sendAudio([Int16](repeating: 3000, count: 800)) } }
    func hush(_ chunks: Int) { for _ in 0..<chunks { link.sendAudio([Int16](repeating: 0, count: 800)) } }

    // MARK: Waking

    @Test(arguments: ["off", "today", "showing", "done", "working"])
    func aWakeInAnyModeListensAndAnswers(_ start: String) async throws {
        switch start {
        case "today": press(.doubleTap)
        case "showing":
            brain.answers = ["Hi": Answer(sentence: "Hi Jan!")]
            conductor.ask("Hi")
            try await eventually { conductor.mode == .showing }
        case "done":
            press(.doubleTap)
            press(.longPress)
            try await eventually { conductor.mode == .listening }
            press(.longPressEnd)
            try await eventually { conductor.mode == .done }
        case "working":
            brain.delay = .seconds(5)
            conductor.ask("Hi")
            try await eventually { conductor.mode == .working }
            brain.delay = nil
        default: break
        }
        speech.script = [Transcript("Hey Lotti, wie spät ist es")]
        brain.answers["wie spät ist es"] = Answer(sentence: "Es ist drei.")
        try await wakeOn()
        sayHeyLotti()
        try await eventually(timeout: 2) { conductor.mode == .listening }
        #expect(conductor.screen?.text == "wie spät ist es")
        hush(4)  // 200 ms quiet
        try await eventually(timeout: 2) { conductor.screen?.text == "Es ist drei." }
        #expect(brain.asked.last == "wie spät ist es")  // without the wake phrase
        #expect(conductor.lastHeard == "wie spät ist es")
        #expect(conductor.wakeLast?.contains("confirmed") == true)
    }

    @Test func aCommandCutOffByTheCapIsStillAnswered() async throws {
        speech.script = [Transcript("Hey Lotti, tell me a very long story")]
        brain.answers["tell me a very long story"] = Answer(sentence: "Once.")
        try await wakeOn()
        sayHeyLotti()
        try await eventually(timeout: 2) { conductor.mode == .listening }
        talk(24)  // 1.2 s of talking, over the 1 s cap
        try await eventually(timeout: 2) { conductor.screen?.text == "Once." }
    }

    @Test func noCommandTurnsTheDisplayOffQuietly() async throws {
        speech.script = [Transcript("Hey Lotti")]
        press(.doubleTap)
        try await wakeOn()
        sayHeyLotti()
        try await eventually(timeout: 2) { conductor.mode == .listening }
        #expect(conductor.screen?.text == "Listening…")
        hush(6)  // 300 ms > 200 ms
        try await eventually(timeout: 2) { conductor.mode == .off }
        try await eventually { link.frames.last == .dark }
        #expect(!link.shownTexts.contains { $0.contains("Sorry") })
        #expect(brain.asked.isEmpty)
    }

    @Test func doubleTapWhileWakeListeningCancels() async throws {
        speech.script = [Transcript("Hey Lotti, what")]
        try await wakeOn()
        sayHeyLotti()
        try await eventually(timeout: 2) { conductor.mode == .listening }
        press(.doubleTap)
        #expect(conductor.mode == .off)
        hush(10)
        try await Task.sleep(for: .milliseconds(100))
        #expect(brain.asked.isEmpty)
        #expect(conductor.mode == .off)
    }

    @Test func aCandidateTheRecognizerDoesNotConfirmChangesNothing() async throws {
        speech.script = [Transcript("a lotta stuff")]
        let frames = link.frames.count
        try await wakeOn()
        sayHeyLotti()
        try await eventually(timeout: 2) { conductor.wakeLast?.contains("rejected") == true }
        #expect(conductor.mode == .off)
        #expect(link.frames.count == frames)
        #expect(conductor.wakeState == .listening)
        // And it hears the next one.
        speech.script = [Transcript("Hey Lotti, hi")]
        hush(40)
        sayHeyLotti()
        try await eventually(timeout: 2) { conductor.mode == .listening }
    }

    @Test func nothingHeardWithinTheWindowRejectsToo() async throws {
        speech.script = []
        try await wakeOn()
        sayHeyLotti()
        try await eventually(timeout: 2) { conductor.wakeLast?.contains("rejected") == true }
        #expect(conductor.mode == .off)
    }

    @Test func wakeDetectionIsIgnoredWhileHoldToTalkIsListening() async throws {
        speech.script = [Transcript("Hey Lotti, what")]
        press(.doubleTap)
        try await wakeOn()
        press(.longPress)
        try await eventually { conductor.mode == .listening }
        sayHeyLotti()
        try await Task.sleep(for: .milliseconds(100))
        #expect(classifier.calls == 0)
        #expect(conductor.wakeLast == nil)
    }

    @Test func aCandidateIsIgnoredWhileTheNavigationScreenIsUp() async throws {
        speech.script = [Transcript("Hey Lotti, what")]
        link.displaySuspended = true
        try await wakeOn()
        sayHeyLotti()
        try await Task.sleep(for: .milliseconds(150))
        #expect(conductor.mode == .off)
        #expect(conductor.wakeLast == nil)
        // Navigation ends: the next one wakes.
        link.displaySuspended = false
        hush(40)
        sayHeyLotti()
        try await eventually(timeout: 2) { conductor.mode == .listening }
    }

    // MARK: The shared mic

    @Test func holdToTalkReusesTheOpenStream() async throws {
        speech.script = [Transcript("Wetter")]
        press(.doubleTap)
        try await wakeOn()
        #expect(link.microphoneStarts == 1)
        press(.longPress)
        try await eventually { conductor.microphoneSource == "glasses" }
        press(.longPressEnd)
        try await eventually(timeout: 2) { brain.asked == ["Wetter"] }
        #expect(link.microphoneStarts == 1)
        #expect(link.microphoneStops == 0)
        #expect(link.microphoneOn)
    }

    @Test func withWakeWordOffTheMicIsOnlyOnWhileHolding() async throws {
        speech.script = [Transcript("Wetter")]
        conductor.setWakeWord(enabled: false)
        press(.doubleTap)
        try await Task.sleep(for: .milliseconds(50))
        #expect(link.microphoneStarts == 0)
        #expect(conductor.wakeState == .off)
        press(.longPress)
        try await eventually { link.microphoneOn }
        press(.longPressEnd)
        try await eventually(timeout: 2) { brain.asked == ["Wetter"] }
        #expect(!link.microphoneOn)
        #expect(link.microphoneStarts == 1)
        #expect(link.microphoneStops == 1)
    }

    @Test func switchingWakeWordOffReleasesTheMic() async throws {
        try await wakeOn()
        conductor.setWakeWord(enabled: false)
        try await eventually { !link.microphoneOn }
        #expect(conductor.wakeState == .off)
    }

    @Test func reconnectingRestartsWakeListening() async throws {
        try await wakeOn()
        link.dropMicrophone()
        await conductor.glassesConnected()
        try await eventually(timeout: 2) { link.microphoneStarts >= 2 && conductor.wakeState == .listening }
        #expect(link.microphoneOn)
    }

    @Test func theWatchdogRestartsAMicThatWentQuiet() async throws {
        let conductor = Self.makeConductor(link: link, brain: brain, speech: speech, phoneMic: phoneMic,
                                           classifier: classifier, watchdog: .milliseconds(150))
        conductor.setWakeWord(enabled: true)
        try await eventually { conductor.wakeState == .listening }
        #expect(link.microphoneStarts == 1)
        // No packets: after 150 ms the mic is switched off and on again.
        try await eventually(timeout: 3) { link.microphoneStarts >= 2 }
        #expect(link.microphoneStops >= 1)
    }

    @Test func aMicThatWontStartShowsUnavailableAndIsRetried() async throws {
        link.microphoneError = GlassesLinkError.missingCharacteristics
        conductor.setWakeWord(enabled: true)
        try await eventually {
            if case .unavailable = conductor.wakeState { return true }
            return false
        }
        link.microphoneError = nil
        try await eventually(timeout: 2) { conductor.wakeState == .listening }
    }

    @Test func holdToTalkStillFallsBackToThePhoneMicWhenTheGlassesFail() async throws {
        link.microphoneError = GlassesLinkError.missingCharacteristics
        conductor.setWakeWord(enabled: true)
        speech.script = [Transcript("Wetter")]
        press(.doubleTap)
        press(.longPress)
        try await eventually(timeout: 2) { conductor.microphoneSource == "phone" }
        press(.longPressEnd)
        try await eventually(timeout: 2) { brain.asked == ["Wetter"] }
    }
}
