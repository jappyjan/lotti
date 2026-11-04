import Foundation

/// Stage 1 of the wake word: scores a window of audio for "Hey Lotti". Cheap, and wrong
/// sometimes: a hit is only a candidate until the speech recognizer confirms it.
public protocol SoundClassifier: Sendable {
    /// Confidence 0...1 that `window` (16 kHz mono) holds "Hey Lotti".
    func score(_ window: [Int16]) async -> Double
}

/// A window the classifier liked, with the audio that led up to it.
public struct WakeCandidate: Sendable {
    public var score: Double
    /// The last couple of seconds before the hit, oldest first, so the recognizer hears the whole phrase.
    public var preRoll: [Int16]
}

/// Cuts the microphone stream into overlapping windows and runs the classifier on them, but only
/// while the energy gate says there is sound. Feed it every chunk, in order.
@MainActor
public final class WakeWordDetector {
    nonisolated public static let sampleRate = 16_000
    /// Classifier confidence for a candidate, unless Debug sets another.
    nonisolated public static let defaultThreshold = 0.8

    private let classifier: any SoundClassifier
    private var ring: AudioRingBuffer
    private let windowSamples: Int
    private let hopSamples: Int
    private let preRollSamples: Int
    private var sinceWindow = 0
    /// Samples left in which windows still run after the last loud chunk (the phrase's tail).
    private var holdover = 0

    /// A window scoring at least this is a candidate.
    public var threshold: Double
    /// The newest score, for the Debug screen.
    public private(set) var lastScore: Double?
    /// Audio seconds the classifier was awake for, to judge battery.
    public private(set) var classifiedSeconds = 0.0
    /// Windows scored and the highest score since the last `takeStats()`, for the log.
    private var windows = 0
    private var maxScore = 0.0

    public init(
        classifier: any SoundClassifier, threshold: Double = defaultThreshold, window: Duration = .seconds(1),
        overlap: Double = 0.5, preRoll: Duration = .seconds(2)
    ) {
        self.classifier = classifier
        self.threshold = threshold
        windowSamples = Int(window.seconds * Double(Self.sampleRate))
        hopSamples = max(Int(Double(windowSamples) * (1 - overlap)), 1)
        preRollSamples = Int(preRoll.seconds * Double(Self.sampleRate))
        ring = AudioRingBuffer(capacity: max(windowSamples, preRollSamples))
    }

    public func takeStats() -> (windows: Int, maxScore: Double) {
        defer { windows = 0; maxScore = 0 }
        return (windows, maxScore)
    }

    /// Forget buffered audio (after the stream was paused).
    public func reset() {
        ring.removeAll()
        sinceWindow = 0
        holdover = 0
    }

    public func process(_ chunk: [Int16], active: Bool) async -> WakeCandidate? {
        ring.append(chunk)
        if active { holdover = windowSamples }
        guard holdover > 0 else { return nil }
        holdover = max(holdover - chunk.count, 0)
        sinceWindow += chunk.count
        guard sinceWindow >= hopSamples, ring.count >= windowSamples else { return nil }
        sinceWindow = 0
        classifiedSeconds += Double(hopSamples) / Double(Self.sampleRate)
        let score = await classifier.score(ring.last(windowSamples))
        lastScore = score
        windows += 1
        maxScore = max(maxScore, score)
        guard score >= threshold else { return nil }
        // Start over, so the same phrase doesn't fire again on the next window.
        let preRoll = ring.last(preRollSamples)
        reset()
        return WakeCandidate(score: score, preRoll: preRoll)
    }
}
