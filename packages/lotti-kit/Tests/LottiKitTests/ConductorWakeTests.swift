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
        link: FakeGlassesLink, brain: FakeBrain, speech: any SpeechRecognizer, phoneMic: FakeMicrophone,
        classifier: FakeClassifier, watchdog: Duration = .seconds(30), idle: Duration = .milliseconds(300),
        done: Duration = .milliseconds(100), answer: Duration = .milliseconds(200)
    ) -> Conductor {
        Conductor(
            link: link, brain: brain, speech: speech, phoneMicrophone: phoneMic,
            today: FixedToday(info: TodayInfo(now: Date())),
            timing: .init(idle: idle, done: done, answer: answer,
                          finalTranscript: .milliseconds(200), wakeConfirm: .milliseconds(300),
                          wakeSilence: .milliseconds(100), wakeNoCommand: .milliseconds(200), wakeCap: .seconds(1),
                          micWatchdog: watchdog, micRetry: .milliseconds(20), micRetryMax: .milliseconds(100)),
            wakeDetector: WakeWordDetector(classifier: classifier))
    }

    func press(_ gesture: InputEvent.Gesture, on conductor: Conductor? = nil) {
        (conductor ?? self.conductor).handle(InputEvent(gesture, from: .ring))
    }

    func wakeOn(_ conductor: Conductor? = nil) async throws {
        let conductor = conductor ?? self.conductor
        conductor.setWakeWord(enabled: true)
        try await eventually { conductor.wakeState == .listening }
    }

    /// One second and a bit of loud audio with the classifier's marker in it: a candidate.
    func sayHeyLotti(chunks: Int = 24) {
        for index in 0..<chunks {
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
        // Screens stay up long enough that the wake really starts from `start`.
        let conductor = Self.makeConductor(link: link, brain: brain, speech: speech, phoneMic: phoneMic,
                                           classifier: classifier, idle: .seconds(10), done: .seconds(10), answer: .seconds(10))
        let expected: Conductor.Mode
        switch start {
        case "today":
            press(.doubleTap, on: conductor)
            expected = .today(byHead: false)
        case "showing":
            brain.answers = ["Hi": Answer(sentence: "Hi Jan!")]
            conductor.ask("Hi")
            try await eventually { conductor.mode == .showing }
            expected = .showing
        case "done":
            press(.doubleTap, on: conductor)
            press(.longPress, on: conductor)
            try await eventually { conductor.mode == .listening }
            press(.longPressEnd, on: conductor)
            try await eventually { conductor.mode == .done }
            expected = .done
        case "working":
            brain.delay = .seconds(5)
            brain.answers = ["Hi": Answer(sentence: "Hi Jan!")]
            conductor.ask("Hi")
            try await eventually { conductor.mode == .working && brain.asked == ["Hi"] }  // the slow call has started
            brain.delay = nil
            expected = .working
        default:
            expected = .off
        }
        speech.script = [Transcript("Hey Lotti, wie spät ist es")]
        brain.answers["wie spät ist es"] = Answer(sentence: "Es ist drei.")
        try await wakeOn(conductor)
        #expect(conductor.mode == expected)
        sayHeyLotti()
        try await eventually { conductor.mode == .listening }
        #expect(conductor.screen?.text == "wie spät ist es")
        hush(4)  // 200 ms quiet
        try await eventually { conductor.screen?.text == "Es ist drei." }
        #expect(brain.asked.last == "wie spät ist es")  // without the wake phrase
        #expect(conductor.lastHeard == "wie spät ist es")
        #expect(conductor.wakeLast?.contains("confirmed") == true)
        // The running answer was cancelled and the back stack cleared.
        #expect(!link.shownTexts.contains { $0.contains("Hi Jan!") } || start == "showing")
        press(.doubleTap, on: conductor)
        #expect(conductor.mode == .off)
    }

    @Test func aWakeWhileATimerRingsListensAndTheAnswerWaitsBehindTheAlert() async throws {
        speech.script = [Transcript("Hey Lotti, wie spät ist es")]
        brain.answers["wie spät ist es"] = Answer(sentence: "Es ist drei.")
        conductor.timersChanged([PhoneTimer(id: UUID(), label: "Pasta", state: .ringing)])
        #expect(conductor.mode == .alert)
        try await wakeOn()
        sayHeyLotti()
        try await eventually { conductor.mode == .listening }
        hush(4)
        try await eventually { brain.asked.last == "wie spät ist es" }
        // Like after a hold: the ringing timer comes first, the answer waits behind it.
        try await eventually { conductor.mode == .alert }
        press(.doubleTap)  // stops the timer, then the answer shows
        try await eventually { conductor.screen?.text == "Es ist drei." }
    }

    @Test func theSameBreathCommandReachesTheRecognizerThroughThePreRoll() async throws {
        let speech = RecordingSpeech()
        let conductor = Self.makeConductor(link: link, brain: brain, speech: speech, phoneMic: phoneMic, classifier: classifier)
        try await wakeOn(conductor)
        talk(40)  // 2 s of talk before the phrase, so the ring is full
        sayHeyLotti()
        try await eventually { !speech.chunks.isEmpty }
        // First in is the 2 s ring with the phrase in it, not just audio from the hit on.
        #expect(speech.chunks[0].count == 32_000)
        #expect(speech.chunks[0].contains(FakeClassifier.marker))
    }

    @Test func aCommandCutOffByTheCapIsStillAnswered() async throws {
        speech.script = [Transcript("Hey Lotti, tell me a very long story")]
        brain.answers["tell me a very long story"] = Answer(sentence: "Once.")
        try await wakeOn()
        sayHeyLotti()
        try await eventually { conductor.mode == .listening }
        talk(24)  // 1.2 s of talking, over the 1 s cap
        try await eventually { conductor.screen?.text == "Once." }
    }

    @Test func noCommandTurnsTheDisplayOffQuietly() async throws {
        speech.script = [Transcript("Hey Lotti")]
        press(.doubleTap)
        try await wakeOn()
        sayHeyLotti()
        try await eventually { conductor.mode == .listening }
        #expect(conductor.screen?.text == "Listening…")
        hush(6)  // 300 ms > 200 ms
        try await eventually { conductor.mode == .off }
        try await eventually { link.frames.last == .dark }
        #expect(!link.shownTexts.contains { $0.contains("Sorry") })
        #expect(brain.asked.isEmpty)
    }

    @Test func doubleTapWhileWakeListeningCancels() async throws {
        speech.script = [Transcript("Hey Lotti, what")]
        try await wakeOn()
        sayHeyLotti()
        try await eventually { conductor.mode == .listening }
        press(.doubleTap)
        #expect(conductor.mode == .off)
        hush(10)
        try await Task.sleep(for: .milliseconds(100))
        #expect(brain.asked.isEmpty)
        #expect(conductor.mode == .off)
        // The shared mic stays on and the next "Hey Lotti" works.
        #expect(link.microphoneStops == 0)
        #expect(conductor.wakeState == .listening)
        hush(40)
        sayHeyLotti()
        try await eventually { conductor.mode == .listening }
    }

    @Test func anotherHeyLottiDuringAWakeListenIsPartOfTheCommand() async throws {
        speech.script = [Transcript("Hey Lotti, wie spät ist es")]
        brain.answers["wie spät ist es"] = Answer(sentence: "Es ist drei.")
        try await wakeOn()
        sayHeyLotti()
        try await eventually { conductor.mode == .listening }
        let calls = classifier.calls
        sayHeyLotti(chunks: 8)  // no new candidate while one is running
        hush(4)
        try await eventually { conductor.screen?.text == "Es ist drei." }
        #expect(classifier.calls == calls)
        #expect(brain.asked == ["wie spät ist es"])
    }

    @Test func aCandidateTheRecognizerDoesNotConfirmChangesNothing() async throws {
        speech.script = [Transcript("a lotta stuff")]
        let frames = link.frames.count
        try await wakeOn()
        sayHeyLotti()
        try await eventually { conductor.wakeLast?.contains("rejected") == true }
        #expect(conductor.mode == .off)
        #expect(link.frames.count == frames)
        #expect(conductor.wakeState == .listening)
        // And it hears the next one.
        speech.script = [Transcript("Hey Lotti, hi")]
        hush(40)
        sayHeyLotti()
        try await eventually { conductor.mode == .listening }
    }

    @Test func nothingHeardWithinTheWindowRejectsToo() async throws {
        speech.script = []
        try await wakeOn()
        sayHeyLotti()
        try await eventually { conductor.wakeLast?.contains("rejected") == true }
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
        // After the hold, detection runs again.
        press(.longPressEnd)
        try await eventually { brain.asked == ["Hey Lotti, what"] }
        speech.script = [Transcript("Hey Lotti, hi")]
        sayHeyLotti()
        try await eventually { conductor.wakeLast?.contains("confirmed") == true }
    }

    @Test func aCandidateIsIgnoredWhileTheNavigationScreenIsUp() async throws {
        speech.script = [Transcript("Hey Lotti, what")]
        link.displaySuspended = true
        try await wakeOn()
        sayHeyLotti()
        try await eventually { conductor.wakeLast?.contains("navigation") == true }
        #expect(classifier.calls > 0)
        #expect(conductor.mode == .off)
        // Navigation ends: the next one wakes.
        link.displaySuspended = false
        hush(40)
        sayHeyLotti()
        try await eventually { conductor.mode == .listening }
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
        try await eventually { brain.asked == ["Wetter"] }
        #expect(link.microphoneStarts == 1)
        #expect(link.microphoneStops == 0)
        #expect(link.microphoneOn)
        #expect(conductor.wakeState == .listening)
    }

    @Test func aHoldLetGoBeforeTheMicStartedLeavesNoSubscriptionBehind() async throws {
        // Wake word off: the mic should be on only while holding. The glasses take 150 ms to start it.
        link.microphoneDelay = .milliseconds(150)
        speech.script = [Transcript("Wetter")]
        press(.doubleTap)
        press(.longPress)
        press(.longPressEnd)
        try await Task.sleep(for: .milliseconds(20))
        press(.longPress)  // again, while the first start is still pending
        try await eventually { link.microphoneOn }
        try await Task.sleep(for: .milliseconds(50))
        press(.longPressEnd)
        try await eventually { !link.microphoneOn }
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
        try await eventually { brain.asked == ["Wetter"] }
        #expect(!link.microphoneOn)
        #expect(link.microphoneStarts == 1)
        #expect(link.microphoneStops == 1)
    }

    @Test func switchingWakeWordOffReleasesTheMic() async throws {
        try await wakeOn()
        conductor.setWakeWord(enabled: false)
        try await eventually { !link.microphoneOn }
        #expect(conductor.wakeState == .off)
        // From then on, the old behaviour: on while holding, off after.
        speech.script = [Transcript("Wetter")]
        let (starts, stops) = (link.microphoneStarts, link.microphoneStops)
        press(.doubleTap)
        press(.longPress)
        try await eventually { link.microphoneOn }
        press(.longPressEnd)
        try await eventually { brain.asked == ["Wetter"] }
        #expect(!link.microphoneOn)
        #expect(link.microphoneStarts == starts + 1)
        #expect(link.microphoneStops == stops + 1)
        await conductor.glassesConnected()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!link.microphoneOn)
    }

    @Test func switchingWakeWordOffDuringAWakeListenGoesDark() async throws {
        speech.script = [Transcript("Hey Lotti, what")]
        try await wakeOn()
        sayHeyLotti()
        try await eventually { conductor.mode == .listening }
        conductor.setWakeWord(enabled: false)
        #expect(conductor.mode == .off)
        try await eventually { link.frames.last == .dark }
        #expect(brain.asked.isEmpty)
    }

    @Test func aMicThatStopsDuringAWakeListenAnswersWhatWasHeard() async throws {
        speech.script = [Transcript("Hey Lotti, wie spät ist es")]
        brain.answers["wie spät ist es"] = Answer(sentence: "Es ist drei.")
        try await wakeOn()
        sayHeyLotti()
        try await eventually { conductor.mode == .listening }
        link.dropMicrophone()
        try await eventually { conductor.screen?.text == "Es ist drei." }
        try await eventually { conductor.wakeState == .listening && link.microphoneOn }
    }

    @Test func reconnectingRestartsWakeListening() async throws {
        try await wakeOn()
        // The glasses drop: the stream ends and the listener stops (it doesn't retry while disconnected).
        link.disconnect()
        link.dropMicrophone()
        try await eventually { conductor.wakeState == .off }
        try await Task.sleep(for: .milliseconds(100))
        #expect(link.microphoneStarts == 1)
        await link.connect(DiscoveredGlasses(id: "32", name: "G2"))
        await conductor.glassesConnected()
        try await eventually { link.microphoneStarts == 2 && conductor.wakeState == .listening }
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

    @Test func theWatchdogLeavesAStreamingMicAlone() async throws {
        let conductor = Self.makeConductor(link: link, brain: brain, speech: speech, phoneMic: phoneMic,
                                           classifier: classifier, watchdog: .seconds(1))
        try await wakeOn(conductor)
        for _ in 0..<40 {  // 1.6 s of audio, a chunk every 40 ms
            hush(1)
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(link.microphoneStarts == 1)
        #expect(link.microphoneStops == 0)
    }

    @Test func retriesOfAMicThatWontStartBackOff() async throws {
        link.microphoneError = GlassesLinkError.missingCharacteristics
        conductor.setWakeWord(enabled: true)
        try await Task.sleep(for: .seconds(1))
        // 20, 40, 80, then every 100 ms: about 11 tries. Without backoff it would be about 50.
        #expect(link.microphoneAttempts >= 2)
        #expect(link.microphoneAttempts <= 16)
    }

    @Test func theDefaultsAreTheAgreedOnes() {
        let timing = Conductor.Timing()
        #expect(timing.wakeConfirm == .seconds(3))
        #expect(timing.wakeSilence == .milliseconds(1500))
        #expect(timing.wakeNoCommand == .seconds(5))
        #expect(timing.wakeCap == .seconds(15))
        #expect(timing.micWatchdog == .seconds(3))
        #expect(timing.micRetry == .seconds(1))
        #expect(timing.micRetryMax == .seconds(30))
        #expect(WakeWordDetector.defaultThreshold == 0.8)
    }

    @Test func aMicThatWontStartShowsUnavailableAndIsRetried() async throws {
        link.microphoneError = GlassesLinkError.missingCharacteristics
        conductor.setWakeWord(enabled: true)
        try await eventually {
            if case .unavailable = conductor.wakeState { return true }
            return false
        }
        link.microphoneError = nil
        try await eventually { conductor.wakeState == .listening }
    }

    @Test func holdToTalkStillFallsBackToThePhoneMicWhenTheGlassesFail() async throws {
        link.microphoneError = GlassesLinkError.missingCharacteristics
        conductor.setWakeWord(enabled: true)
        speech.script = [Transcript("Wetter")]
        press(.doubleTap)
        press(.longPress)
        try await eventually { conductor.microphoneSource == "phone" }
        press(.longPressEnd)
        try await eventually { brain.asked == ["Wetter"] }
    }
}

/// Keeps every chunk it gets, to see what the recognizer was fed.
@MainActor
final class RecordingSpeech: SpeechRecognizer {
    private(set) var chunks: [[Int16]] = []

    func prepare() async {}
    func transcribe(_ audio: AsyncStream<[Int16]>) -> AsyncThrowingStream<Transcript, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                for await chunk in audio { self.chunks.append(chunk) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
