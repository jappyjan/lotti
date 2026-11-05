import Foundation

/// Decides when a spoken command is over, without a gesture. Counts audio time, not wall time, so
/// it can be tested with plain sample counts. Feed it every chunk after the wake phrase.
public struct Endpointer: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The command is over: it went quiet for `silence`.
        case endOfSpeech
        /// Nothing followed the wake phrase within `noCommand`.
        case noCommand
        /// The command ran into the hard cap.
        case cap
    }

    public var silence: Double
    public var noCommand: Double
    public var cap: Double
    public private(set) var elapsed = 0.0
    /// How long it has been quiet at the end of the audio so far.
    public private(set) var quiet = 0.0

    public init(silence: Duration, noCommand: Duration, cap: Duration, sampleRate: Double = 16_000) {
        self.silence = silence.seconds
        self.noCommand = noCommand.seconds
        self.cap = cap.seconds
        self.sampleRate = sampleRate
    }

    private let sampleRate: Double

    /// `active`: whether the chunk is louder than the room (`EnergyGate`).
    public mutating func feed(samples: Int, active: Bool) {
        let seconds = Double(samples) / sampleRate
        elapsed += seconds
        quiet = active ? 0 : quiet + seconds
    }

    /// `hasCommand`: whether the transcript holds words after the wake phrase.
    public func outcome(hasCommand: Bool) -> Outcome? {
        if elapsed >= cap { return hasCommand ? .cap : .noCommand }
        if hasCommand { return quiet >= silence ? .endOfSpeech : nil }
        return elapsed >= noCommand ? .noCommand : nil
    }
}

extension Duration {
    public var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
