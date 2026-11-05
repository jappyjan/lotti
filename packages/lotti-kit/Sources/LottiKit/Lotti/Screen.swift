import Foundation

/// What a rail choice does when you tap it.
public enum RailAction: Equatable, Sendable {
    /// Send this to Lotti as your next message (a suggested follow-up).
    case ask(String)
    /// Show this text as Lotti's sentence, without asking the model (e.g. "Agenda" on the today view).
    case show(Screen)
    /// Turn the display off.
    case dismiss
    /// Run a phone action a brain prepared (timer, reminder). This tap is your approval.
    case perform(ProposedAction)
    /// Take back what Lotti just did (backend `undo`).
    case undo(UndoAction)
    /// The all-items list of the inbox, from item `page * 3`.
    case openInbox(page: Int)
    /// Open one inbox item in full (the original) and tell the backend it was opened.
    case openItem(String)
    /// Dismiss one inbox item (the backend is told).
    case dismissItem(String)
    /// Stop this ringing timer (on the phone too).
    case stopTimer(UUID)
}

public struct RailItem: Equatable, Sendable {
    public var title: String
    public var action: RailAction

    public init(_ title: String, _ action: RailAction) {
        self.title = title
        self.action = action
    }
}

/// The choices, one per line under Lotti's sentence. The highlight starts on Lotti's best guess (the first
/// item) and moves with scroll; it stops at the ends instead of wrapping around.
public struct Rail: Equatable, Sendable {
    public static let maxItems = 4

    public private(set) var items: [RailItem]
    public private(set) var highlighted: Int

    public init(_ items: [RailItem], highlighted: Int = 0, limit: Int = Self.maxItems) {
        self.items = Array(items.prefix(limit))
        self.highlighted = min(max(highlighted, 0), max(self.items.count - 1, 0))
    }

    public var isEmpty: Bool { items.isEmpty }
    public var current: RailItem? { items.indices.contains(highlighted) ? items[highlighted] : nil }

    public mutating func moveDown() { highlighted = min(highlighted + 1, max(items.count - 1, 0)) }
    public mutating func moveUp() { highlighted = max(highlighted - 1, 0) }
}

/// A small block of facts below the sentence: a timer, today's weather, one day of a forecast.
/// The title is its first line; the picture sits beside it (or, for a forecast day, under it).
public struct Card: Equatable, Sendable {
    public enum Art: Equatable, Sendable {
        case icon(LensIcon)
        /// A forecast day: its icon over a bar from its low to its high, on the scale of the
        /// whole forecast.
        case day(LensIcon, low: Int, high: Int, range: ClosedRange<Int>)
    }

    public var title: String
    public var lines: [String]
    public var art: Art?

    public init(_ title: String, _ lines: [String] = [], art: Art? = nil) {
        self.title = title
        self.lines = lines
        self.art = art
    }
}

/// A line along the top: something on the left (the date), something short on the right (the time).
public struct Header: Equatable, Sendable {
    public var left: String
    public var right: String

    public init(_ left: String, right: String = "") {
        self.left = left
        self.right = right
    }
}

/// One screen on the glasses: an optional header, Lotti's sentence, optional dim details below
/// it, optional cards in a row under that, and the choices (`rail`) at the bottom.
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
        /// The all-items list: pick one.
        case list
        /// An inbox item word for word, without Lotti's voice.
        case original
    }

    public var kind: Kind
    public var text: String
    /// Dim context lines under the sentence (time and date, agenda lines).
    public var details: [String]
    public var header: Header?
    /// A picture left of the sentence (the bell of a ringing timer, a check for "done").
    public var icon: LensIcon?
    public var cards: [Card]
    /// The choices under the sentence.
    public var rail: Rail?

    public init(_ kind: Kind, _ text: String, details: [String] = [], header: Header? = nil, icon: LensIcon? = nil,
                cards: [Card] = [], rail: Rail? = nil) {
        self.kind = kind
        self.text = text
        self.details = details
        self.header = header
        self.icon = icon
        self.cards = cards
        self.rail = rail.flatMap { $0.isEmpty ? nil : $0 }
    }
}
