import Foundation

/// Turns the glasses' gravity samples into head-up / head-down. Pitch is the angle between one
/// sensor axis and the horizontal plane: 0° with that axis level, positive when it tilts up.
///
/// Calibrated on a worn G2 (2026-11-01): the x axis tilts with the head. Straight ahead read 0–25°,
/// looking at the ceiling about +57°, at the floor about −75°.
/// Hysteresis (up above `upAngle`, down only below `downAngle`) plus a short hold keeps a nod or
/// a bump from flipping the state.
public struct HeadUpDetector: Sendable {
    public enum Axis: String, Sendable, CaseIterable {
        case x, y, z
    }

    public struct Config: Equatable, Sendable {
        /// The sensor axis that points forward out of the glasses.
        public var axis: Axis = .x
        /// +1 or −1: flips the axis if looking up gives negative pitch.
        public var sign: Float = 1
        /// Added to the measured pitch, for glasses that sit tilted on the nose.
        public var offset: Double = 0
        public var upAngle: Double = 40
        public var downAngle: Double = 30
        /// How long the pitch must stay past the threshold.
        public var upHold: TimeInterval = 0.2
        public var downHold: TimeInterval = 0.6

        public init(
            axis: Axis = .x, sign: Float = 1, offset: Double = 0, upAngle: Double = 40, downAngle: Double = 30,
            upHold: TimeInterval = 0.2, downHold: TimeInterval = 0.6
        ) {
            self.axis = axis
            self.sign = sign
            self.offset = offset
            self.upAngle = upAngle
            self.downAngle = downAngle
            self.upHold = upHold
            self.downHold = downHold
        }
    }

    public var config: Config
    public private(set) var isUp = false
    /// When the pitch first crossed the threshold towards the other state.
    private var crossedAt: TimeInterval?

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Pitch in degrees, or nil if the sample is too weak to tell (free fall, bad data).
    public func pitch(x: Float, y: Float, z: Float) -> Double? {
        let magnitude = (x * x + y * y + z * z).squareRoot()
        guard magnitude > 0.3 else { return nil }
        let component = switch config.axis {
        case .x: x
        case .y: y
        case .z: z
        }
        let ratio = Double(max(-1, min(1, config.sign * component / magnitude)))
        return asin(ratio) * 180 / .pi + config.offset
    }

    /// Feeds one sample taken at `time` (seconds, any monotonic clock). Returns `.headUp` or
    /// `.headDown` when the state changes.
    public mutating func feed(x: Float, y: Float, z: Float, at time: TimeInterval) -> InputEvent.Gesture? {
        guard let pitch = pitch(x: x, y: y, z: z) else { return nil }
        let crossing = isUp ? pitch < config.downAngle : pitch > config.upAngle
        guard crossing else {
            crossedAt = nil
            return nil
        }
        let since = crossedAt ?? time
        crossedAt = since
        guard time - since >= (isUp ? config.downHold : config.upHold) else { return nil }
        isUp.toggle()
        crossedAt = nil
        return isUp ? .headUp : .headDown
    }

    /// Forget the state, e.g. when tracking is turned off.
    public mutating func reset() {
        isUp = false
        crossedAt = nil
    }
}
