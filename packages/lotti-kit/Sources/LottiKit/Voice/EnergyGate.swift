import Foundation

/// Stage 0 of the wake word: tells loud audio from quiet, so the classifier only runs when
/// something is being said. The noise floor follows the room: it falls quickly to quiet levels
/// and rises only slowly while there is sound, so steady noise stops counting as activity.
public struct EnergyGate: Sendable {
    /// Activity means louder than this many times the noise floor...
    public var multiplier = 3.0
    /// ...and louder than this (RMS, 0...1) in any case.
    public var minimum = 0.008
    public private(set) var floor = 0.002
    /// RMS of the latest chunk.
    public private(set) var level = 0.0

    public init() {}

    /// RMS of 16-bit samples as 0...1.
    public static func rms(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        return (sum / Double(samples.count)).squareRoot() / 32768
    }

    public var threshold: Double { max(floor * multiplier, minimum) }

    /// Feeds one chunk; true if it is louder than the room.
    public mutating func process(_ samples: [Int16]) -> Bool {
        level = Self.rms(samples)
        let active = level > threshold
        let rate = active ? 0.0005 : 0.05
        floor = min(max(floor + (level - floor) * rate, 0.0005), 0.05)
        return active
    }
}
