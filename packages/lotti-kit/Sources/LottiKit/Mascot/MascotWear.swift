import Foundation

/// What the mascot's glasses should look like.
public struct MascotPose: Equatable, Sendable {
    /// Whether the raccoon wears its glasses.
    public var glassesOn: Bool
    /// Whether the view should animate to this pose. False for the first one resolved, so the
    /// screen doesn't play an animation just because it appeared.
    public var animated: Bool

    public init(glassesOn: Bool, animated: Bool) {
        self.glassesOn = glassesOn
        self.animated = animated
    }
}

/// Maps wear state and link state to the mascot's pose. Glasses count as on only when connected
/// and reported worn: unknown and disconnected both mean off. A change must hold for `debounce`
/// seconds before it shows, so flapping wear reports don't make the mascot blink. The clock is
/// passed in (`at:`), so tests control time.
public struct MascotWearMapper: Sendable {
    public var debounce: TimeInterval
    public private(set) var pose: MascotPose?
    private var pending: (glassesOn: Bool, since: TimeInterval)?

    public init(debounce: TimeInterval = 1) {
        self.debounce = debounce
    }

    public static func target(wear: WearState, connected: Bool) -> Bool {
        connected && wear == .worn
    }

    /// When a pending change will be applied, so the caller can look again then.
    public var pendingDeadline: TimeInterval? {
        pending.map { $0.since + debounce }
    }

    @discardableResult
    public mutating func update(wear: WearState, connected: Bool, at time: TimeInterval) -> MascotPose {
        let target = Self.target(wear: wear, connected: connected)
        guard var current = pose else {
            let first = MascotPose(glassesOn: target, animated: false)
            pose = first
            return first
        }
        if target == current.glassesOn {
            pending = nil
            return current
        }
        let since = (pending?.glassesOn == target ? pending?.since : nil) ?? time
        pending = (target, since)
        if time - since >= debounce {
            current = MascotPose(glassesOn: target, animated: true)
            pose = current
            pending = nil
        }
        return current
    }
}
