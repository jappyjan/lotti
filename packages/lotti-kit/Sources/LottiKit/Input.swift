import Foundation

/// One gesture from the glasses' touchpads or the ring.
public struct InputEvent: Equatable, Sendable, CustomStringConvertible {
    public enum Gesture: String, Sendable {
        case tap, doubleTap, scrollUp, scrollDown, longPress, longPressEnd
        /// Head movement from the glasses' IMU (only while head tracking is on).
        case headUp, headDown
        /// Wear detection: the glasses were put on / taken off. Not a gesture; Lotti treats it as presence.
        case worn, removed
    }

    public enum Source: String, Sendable {
        case rightTouchpad, leftTouchpad, ring
        /// The glasses' motion sensor (head-up / head-down).
        case imu
        /// The glasses themselves (wear detection).
        case glasses
        /// The glasses reported the gesture without saying where it came from.
        case unknown
    }

    public var gesture: Gesture
    public var source: Source

    public init(_ gesture: Gesture, from source: Source) {
        self.gesture = gesture
        self.source = source
    }

    public var description: String { "\(gesture.rawValue) (\(source.rawValue))" }
}

/// Drops repeats of the same gesture that arrive within `window` seconds. Other clients report
/// that the glasses can send one touch several times (MentraOS debounces clicks by 100 ms). Our
/// G2 didn't in S2, so the window is short enough not to eat fast, deliberate scrolls.
public struct InputDeduplicator: Sendable {
    public var window: TimeInterval
    private var last: (gesture: InputEvent.Gesture, at: TimeInterval)?

    public init(window: TimeInterval = 0.15) {
        self.window = window
    }

    /// Returns true if `event` is new and should be delivered. `time` is in seconds, from any
    /// monotonic clock. The source is ignored on purpose: a repeat may carry a different source
    /// (e.g. "unknown" from the text container, "right touchpad" from the system event).
    public mutating func accept(_ event: InputEvent, at time: TimeInterval) -> Bool {
        if let last, last.gesture == event.gesture, time - last.at < window {
            return false
        }
        last = (event.gesture, time)
        return true
    }
}

/// Hands each value to every current subscriber. Each `stream()` call gets its own stream.
@MainActor
public final class Broadcast<Value: Sendable> {
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    public init() {}

    public func stream() -> AsyncStream<Value> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(32))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        return stream
    }

    public func send(_ value: Value) {
        for continuation in continuations.values { continuation.yield(value) }
    }
}
