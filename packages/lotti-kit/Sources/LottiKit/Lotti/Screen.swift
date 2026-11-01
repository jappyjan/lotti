import Foundation

/// What a rail choice does when you tap it.
public enum RailAction: Equatable, Sendable {
    /// Send this to Lotti as your next message (a suggested follow-up).
    case ask(String)
    /// Show this text as Lotti's sentence, without asking the model (e.g. "Agenda" on the today view).
    case show(Screen)
    /// Turn the display off.
    case dismiss
}

public struct RailItem: Equatable, Sendable {
    public var title: String
    public var action: RailAction

    public init(_ title: String, _ action: RailAction) {
        self.title = title
        self.action = action
    }
}

/// The column of choices on the right. The highlight starts on Lotti's best guess (the first
/// item) and moves with scroll; it stops at the ends instead of wrapping around.
public struct Rail: Equatable, Sendable {
    public static let maxItems = 4

    public private(set) var items: [RailItem]
    public private(set) var highlighted: Int

    public init(_ items: [RailItem], highlighted: Int = 0) {
        self.items = Array(items.prefix(Self.maxItems))
        self.highlighted = min(max(highlighted, 0), max(self.items.count - 1, 0))
    }

    public var isEmpty: Bool { items.isEmpty }
    public var current: RailItem? { items.indices.contains(highlighted) ? items[highlighted] : nil }

    public mutating func moveDown() { highlighted = min(highlighted + 1, max(items.count - 1, 0)) }
    public mutating func moveUp() { highlighted = max(highlighted - 1, 0) }
}

/// One screen on the glasses: Lotti's sentence, optional dim details below it, optional rail.
/// Hand-coded kinds for the MVP; the Actions list later reuses `Rail`.
public struct Screen: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The today view (look-up view).
        case today
        /// Lotti answers or tells you something.
        case says
        /// Your words while you hold.
        case listening
        /// Lotti is on it.
        case working
        /// One short line that goes away by itself.
        case done
    }

    public var kind: Kind
    public var text: String
    /// Dim context lines under the sentence (time and date, agenda lines).
    public var details: [String]
    public var rail: Rail?

    public init(_ kind: Kind, _ text: String, details: [String] = [], rail: Rail? = nil) {
        self.kind = kind
        self.text = text
        self.details = details
        self.rail = rail.flatMap { $0.isEmpty ? nil : $0 }
    }
}
