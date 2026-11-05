import Foundation

/// One of Lotti's timers on the phone.
public struct PhoneTimer: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Counting down; rings at `ends`.
        case running(ends: Date)
        case ringing
    }

    public var id: UUID
    /// What it's for ("Pasta"); nil for a plain timer.
    public var label: String?
    public var state: State
    /// How long it was set for, if known: how full its dial is.
    public var duration: TimeInterval?

    public init(id: UUID, label: String? = nil, state: State, duration: TimeInterval? = nil) {
        self.id = id
        self.label = label
        self.state = state
        self.duration = duration
    }

    public var isRinging: Bool { state == .ringing }
}

/// The phone's timers, as far as the glasses care: which ones run or ring, and stopping one.
/// On the phone this is AlarmKit; stopping here stops it on the phone too.
@MainActor
public protocol Timers: AnyObject {
    /// All of Lotti's timers every time one changes: running ones soonest first, ringing ones in
    /// the order they started ringing. An empty list once there are none.
    func updates() -> AsyncStream<[PhoneTimer]>
    func stop(_ id: UUID) async throws
}
