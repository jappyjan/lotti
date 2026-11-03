import Foundation

/// Where the mascot's head should point, in degrees: a target the view eases to.
public struct HeadAngles: Equatable, Sendable {
    /// Nod. Positive is looking up.
    public var pitch: Double
    /// Tilt. Positive leans toward the +lateral side (see `HeadAngleMapper.Config`; sign unverified).
    public var roll: Double
    /// Always 0: gravity can't tell which way you face.
    public var yaw: Double

    public static let neutral = HeadAngles(pitch: 0, roll: 0, yaw: 0)

    public init(pitch: Double, roll: Double, yaw: Double = 0) {
        self.pitch = pitch
        self.roll = roll
        self.yaw = yaw
    }
}

/// Turns gravity samples into head angles for the mascot.
///
/// Axes (from `HeadUpDetector`, calibrated on a worn G2): **x tilts with the head**, so
/// nod = asin(x / |v|), positive when looking up, measured from the user's own straight-ahead
/// pitch (`HeadUpSettings.straightAhead`). Tilt (roll) is the lean around the forward direction,
/// atan2(lateral, vertical) in the other two axes. Which of y/z is lateral and the sign are
/// **not confirmed on hardware**; the defaults (y lateral, z vertical, +1) are a guess and
/// configurable. Yaw isn't observable from gravity and stays 0.
///
/// Pipeline per sample: reject bad data, low-pass filter the raw angles, subtract the neutral,
/// apply a dead zone (so noise at rest gives exactly 0), clamp.
public struct HeadAngleMapper: Sendable {
    public struct Config: Equatable, Sendable {
        public var pitchDeadZone: Double = 2
        public var rollDeadZone: Double = 2
        public var pitchLimit: Double = 20
        public var rollLimit: Double = 15
        /// Share of each new sample in the filtered value (1 = no filtering).
        public var smoothing: Double = 0.5
        /// Samples with |v| outside this range are not gravity alone (shaking, free fall): ignored.
        public var magnitudeRange: ClosedRange<Float> = 0.5...1.6
        public var rollLateral: HeadUpDetector.Axis = .y
        public var rollVertical: HeadUpDetector.Axis = .z
        public var rollSign: Double = 1
        public init() {}
    }

    public var config: Config
    public private(set) var angles = HeadAngles.neutral
    /// Seconds between samples, as measured (about 1 on the G2).
    public private(set) var sampleInterval: TimeInterval = 1
    private var rawPitch: Double?
    private var rawRoll: Double?
    private var lastTime: TimeInterval?

    public init(config: Config = Config()) {
        self.config = config
    }

    /// How long the view should take to ease to a new target: about one sample interval.
    public var suggestedDuration: TimeInterval { min(max(sampleInterval, 0.2), 1.5) }

    /// Feeds one sample. Returns the new target, or nil if the sample was unusable (NaN,
    /// infinite, too weak or too strong to be gravity); the target then stays as it was.
    @discardableResult
    public mutating func feed(_ s: IMUSample, straightAhead: Double, at time: TimeInterval) -> HeadAngles? {
        guard s.x.isFinite, s.y.isFinite, s.z.isFinite, straightAhead.isFinite else { return nil }
        let magnitude = (s.x * s.x + s.y * s.y + s.z * s.z).squareRoot()
        guard config.magnitudeRange.contains(magnitude) else { return nil }

        func axis(_ a: HeadUpDetector.Axis) -> Float {
            switch a {
            case .x: s.x
            case .y: s.y
            case .z: s.z
            }
        }
        let pitch = asin(Double(max(-1, min(1, axis(.x) / magnitude)))) * 180 / .pi
        let lateral = Double(axis(config.rollLateral)), vertical = Double(axis(config.rollVertical))
        // Nearly straight up or down, the lean has no meaning: keep the last value.
        let rollValid = (lateral * lateral + vertical * vertical).squareRoot() > 0.2
        let roll = config.rollSign * atan2(lateral, vertical) * 180 / .pi

        let a = min(max(config.smoothing, 0.01), 1)
        rawPitch = rawPitch.map { $0 + a * (pitch - $0) } ?? pitch
        if rollValid {
            // Avoid the +-180 wrap: lean is only ever near 0 for a head, so plain filtering is fine.
            rawRoll = rawRoll.map { $0 + a * (roll - $0) } ?? roll
        }

        if let last = lastTime, time > last {
            let dt = time - last
            if dt >= 0.05, dt <= 5 { sampleInterval = 0.7 * sampleInterval + 0.3 * dt }
        }
        lastTime = time

        angles = HeadAngles(
            pitch: Self.shape((rawPitch ?? 0) - straightAhead, deadZone: config.pitchDeadZone, limit: config.pitchLimit),
            roll: Self.shape(rawRoll ?? 0, deadZone: config.rollDeadZone, limit: config.rollLimit),
            yaw: 0)
        return angles
    }

    /// Forget the filter, e.g. when the feed stopped.
    public mutating func reset() {
        angles = .neutral
        rawPitch = nil
        rawRoll = nil
        lastTime = nil
    }

    /// Dead zone that starts at 0 (no jump at its edge), then clamp.
    static func shape(_ value: Double, deadZone: Double, limit: Double) -> Double {
        let magnitude = max(0, abs(value) - deadZone)
        return min(magnitude, limit) * (value < 0 ? -1 : 1)
    }
}
