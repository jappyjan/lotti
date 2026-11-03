import Foundation
import Testing
@testable import LottiKit

struct WakeWordMatcherTests {
    @Test(arguments: [
        "Hey Lotti", "hey, Lottie", "Hi Lotti", "Hallo Lotti", "Hey Lotty, wie spät ist es", "hey lodi", "Hei Loti",
        "okay hey Lotti what's up",
    ])
    func acceptsTheWakePhrase(_ text: String) {
        #expect(WakeWordMatcher.match(text) != nil, "\(text)")
    }

    @Test(arguments: [
        "a lotta", "Hey Lotte", "Lotto", "hey Otto", "Lotti", "Lotti, wie spät ist es", "hey Lola", "Hotel", "hey lotta fun",
        "", "hey", "hey Lotto", "hallo Lotta", "hi Lola", "hey Hotel", "hey lady", "hey Loki", "hey Lori", "hey Lolly",
    ])
    func rejectsWhatIsNotTheWakePhrase(_ text: String) {
        #expect(WakeWordMatcher.match(text) == nil, "\(text)")
    }

    @Test func stripsThePhrase() {
        #expect(WakeWordMatcher.match("Hey Lotti, wie spät ist es")?.command == "wie spät ist es")
        #expect(WakeWordMatcher.match("Hey Lotti.")?.command == "")
        #expect(WakeWordMatcher.match("hey lottie what's the weather?")?.command == "what's the weather?")
        #expect(WakeWordMatcher.match("Hey Lotti 5 minutes timer")?.command == "5 minutes timer")
        #expect(WakeWordMatcher.match("okay hey Lotti what's up")?.command == "what's up")
    }
}

struct WakeWordPartsTests {
    @Test func gateIgnoresQuietAndFollowsTheRoom() {
        var gate = EnergyGate()
        let quiet = [Int16](repeating: 20, count: 800)
        let loud = [Int16](repeating: 3000, count: 800)
        let results = [gate.process(quiet), gate.process(loud), gate.process(quiet)]
        #expect(results == [false, true, false])
        // Steady noise stops counting once the floor has risen to it (capped, so speech still passes).
        var noisy = EnergyGate()
        let hum = [Int16](repeating: 400, count: 800)
        let first = noisy.process(hum)
        for _ in 0..<20_000 { _ = noisy.process(hum) }
        let later = noisy.process(hum)
        let speech = noisy.process(loud)
        #expect(first && !later && speech)
    }

    @Test func rmsOfASquareWaveIsItsAmplitude() {
        #expect(abs(EnergyGate.rms([Int16](repeating: 16384, count: 100)) - 0.5) < 0.001)
        #expect(EnergyGate.rms([]) == 0)
    }

    @Test func ringKeepsTheNewestSamplesInOrder() {
        var ring = AudioRingBuffer(capacity: 5)
        ring.append([1, 2, 3])
        #expect(ring.last() == [1, 2, 3])
        ring.append([4, 5, 6, 7])
        #expect(ring.last() == [3, 4, 5, 6, 7])
        #expect(ring.last(2) == [6, 7])
        ring.append(Array(10...30).map { Int16($0) })
        #expect(ring.last() == [26, 27, 28, 29, 30])
        ring.removeAll()
        #expect(ring.last().isEmpty)
    }

    @Test func endpointerEndsOnSilenceAfterACommand() {
        var end = Endpointer(silence: .milliseconds(1500), noCommand: .seconds(5), cap: .seconds(15))
        end.feed(samples: 16_000, active: true)
        end.feed(samples: 16_000, active: false)
        #expect(end.outcome(hasCommand: true) == nil)
        end.feed(samples: 8_000, active: false)
        #expect(end.outcome(hasCommand: true) == .endOfSpeech)
        // Talking again starts the quiet over.
        end.feed(samples: 1_600, active: true)
        #expect(end.outcome(hasCommand: true) == nil)
    }

    @Test func endpointerGivesUpWithoutACommandAndCapsLongOnes() {
        var end = Endpointer(silence: .milliseconds(1500), noCommand: .seconds(5), cap: .seconds(15))
        end.feed(samples: 16_000 * 4, active: false)
        #expect(end.outcome(hasCommand: false) == nil)
        end.feed(samples: 16_000, active: false)
        #expect(end.outcome(hasCommand: false) == .noCommand)

        var long = Endpointer(silence: .milliseconds(1500), noCommand: .seconds(5), cap: .seconds(15))
        for _ in 0..<15 { long.feed(samples: 16_000, active: true) }
        #expect(long.outcome(hasCommand: true) == .cap)
    }

    @Test func lc3RoundTripKeepsLengthAndCharacter() throws {
        let tone = (0..<16_000).map { Int16(8000 * sin(Double($0) * 2 * .pi * 440 / 16_000)) }
        let decoded = LC3Encoder.roundTrip(tone)
        #expect(decoded.count == tone.count)
        // Lossy, but a 440 Hz tone stays a loud 440 Hz tone.
        let tail = Array(decoded[8000..<16_000])
        #expect(EnergyGate.rms(tail) > 0.1)
        #expect(decoded != tone)
    }
}

/// Scores a window high if it holds the marker sample.
final class FakeClassifier: SoundClassifier, @unchecked Sendable {
    static let marker: Int16 = 7777
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func score(_ window: [Int16]) async -> Double {
        lock.withLock { count += 1 }
        return window.contains(Self.marker) ? 0.95 : 0.1
    }
}

@MainActor
struct WakeWordDetectorTests {
    let classifier = FakeClassifier()
    let detector: WakeWordDetector

    init() { detector = WakeWordDetector(classifier: classifier) }

    func chunk(marker: Bool = false, loud: Bool = true) -> [Int16] {
        var samples = [Int16](repeating: loud ? 3000 : 0, count: 800)
        if marker { samples[0] = FakeClassifier.marker }
        return samples
    }

    @Test func quietAudioNeverReachesTheClassifier() async {
        for _ in 0..<100 { #expect(await detector.process(chunk(loud: false), active: false) == nil) }
        #expect(classifier.calls == 0)
    }

    @Test func aHitInALoudWindowGivesACandidateWithPreRoll() async throws {
        var found: WakeCandidate?
        for index in 0..<60 where found == nil {
            found = await detector.process(chunk(marker: index == 35), active: true)
        }
        let candidate = try #require(found)
        #expect(candidate.score > 0.9)
        #expect(candidate.preRoll.count == 32_000)  // 2 s before the hit
        #expect(candidate.preRoll.contains(FakeClassifier.marker))
    }

    @Test func windowsOverlapByHalf() async {
        for _ in 0..<60 { _ = await detector.process(chunk(), active: true) }  // 3 s
        // First window at 1 s, then every 0.5 s.
        #expect(classifier.calls == 5)
    }

    @Test func theClassifierStopsOneWindowAfterTheSoundDoes() async {
        for _ in 0..<40 { _ = await detector.process(chunk(), active: true) }
        let busy = classifier.calls
        for _ in 0..<100 { _ = await detector.process(chunk(loud: false), active: false) }
        #expect(classifier.calls <= busy + 2)
        let settled = classifier.calls
        for _ in 0..<100 { _ = await detector.process(chunk(loud: false), active: false) }
        #expect(classifier.calls == settled)
    }
}

@MainActor
struct MicrophoneHubTests {
    let link = FakeGlassesLink()

    init() async { await link.connect(DiscoveredGlasses(id: "32", name: "G2")) }

    @Test func subscribersShareOneStreamAndTheMicStopsWithTheLast() async throws {
        let hub = MicrophoneHub(link: link)
        let first = try await hub.subscribe()
        let second = try await hub.subscribe()
        #expect(link.microphoneStarts == 1)
        link.sendAudio([1, 2, 3])
        var a = first.stream.makeAsyncIterator()
        var b = second.stream.makeAsyncIterator()
        #expect(await a.next() == [1, 2, 3])
        #expect(await b.next() == [1, 2, 3])
        await hub.unsubscribe(first)
        #expect(link.microphoneOn)
        await hub.unsubscribe(second)
        #expect(!link.microphoneOn)
        #expect(link.microphoneStops == 1)
    }

    @Test func keepOpenHoldsTheMicWithoutSubscribers() async throws {
        let hub = MicrophoneHub(link: link)
        await hub.setKeepOpen(true)
        let subscription = try await hub.subscribe()
        await hub.unsubscribe(subscription)
        #expect(link.microphoneOn)
        await hub.setKeepOpen(false)
        #expect(!link.microphoneOn)
    }

    @Test func failingToStartThrowsAndLeavesNothingOpen() async {
        link.microphoneError = GlassesLinkError.notConnected
        let hub = MicrophoneHub(link: link)
        await #expect(throws: GlassesLinkError.self) { _ = try await hub.subscribe() }
        #expect(!hub.isOpen)
    }
}
