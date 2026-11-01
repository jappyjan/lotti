import Foundation

/// Where things go on the G2's 576 × 288 display, and roughly how much text fits.
///
/// The firmware has one fixed proportional font. g2-kit (`ble/docs/text.md`) measured a planning
/// grid of about 50 columns × 10 rows on a full-width container, so one "column" is ~11.5 px and
/// one row ~29 px. Narrow letters pack tighter, `W` and `M` wider, so the character counts below
/// leave a little room. Text that doesn't fit wraps at word boundaries and shows a scroll bar, but
/// the firmware never scrolls it: lay text out to fit.
public enum G2Layout {
    public static let width = 576
    public static let height = 288

    /// The gap between the sentence and the rail when they sit side by side.
    public static let gap = 16

    /// About how many average characters fit on one line, for the `.rail` style.
    public static let charsPerLineFullWidth = 46
    public static let charsPerLineWithRail = 31
    public static let charsPerLineRail = 13
    /// Lines that fit on the display (all columns are full height).
    public static let lines = 10

    /// Six lines above the choices block in `.choicesBelow` (one line ≈ 29 px).
    public static let choicesBelowMainHeight = 174
    /// The choices block in `.choicesBelow`, under the sentence.
    public static let choicesBelowRailY = 174
    public static let choicesBelowRailHeight = 114

    /// The width of Lotti's text when the rail sits next to it.
    public static func mainWidth(_ style: DisplayStyle) -> Int {
        switch style {
        case .rail: 384
        case .wideRail: 320
        case .choicesBelow: width
        }
    }

    /// The rail's left edge and width when it sits next to the sentence.
    public static func railX(_ style: DisplayStyle) -> Int {
        switch style {
        case .rail: 400
        case .wideRail: 336
        case .choicesBelow: 0
        }
    }

    public static func railWidth(_ style: DisplayStyle) -> Int {
        switch style {
        case .rail: 176
        case .wideRail: 240
        case .choicesBelow: width
        }
    }

    public static func railY(_ style: DisplayStyle) -> Int {
        switch style {
        case .rail, .wideRail: 0
        case .choicesBelow: choicesBelowRailY
        }
    }

    public static func railHeight(_ style: DisplayStyle) -> Int {
        switch style {
        case .rail, .wideRail: height
        case .choicesBelow: choicesBelowRailHeight
        }
    }

    /// What a blank container gets. MentraOS blanks text in place with "\n" (keeps the page and
    /// the event pipeline alive); an empty Cmd 5 isn't confirmed to work.
    static let blank = "\n"
}

/// The page layouts Lotti uses.
public enum G2PageShape: Equatable, Sendable {
    /// One text container across the whole display.
    case fullWidth
    /// Lotti's text on the left, the rail on the right, with the style's widths.
    case withRail(DisplayStyle)
    /// The sentence on top, the choices in a block underneath.
    case choicesBelow
}

/// One text container on the page. Ids are the routing key for Cmd 5 updates (even-g2-protocol
/// found the name is only metadata); names must be ≤ 14 characters.
public struct G2TextBox: Equatable, Sendable {
    public var id: Int
    public var name: String
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    /// Only one container should capture touch events: text taps don't say which container they
    /// were on (g2-kit `text.md`).
    public var capturesEvents: Bool
    public var text: String

    public static let mainID = 1
    public static let railID = 2

    static func main(_ text: String, shape: G2PageShape, style: DisplayStyle = .rail) -> G2TextBox {
        let width: Int = switch shape {
        case .fullWidth, .choicesBelow: G2Layout.width
        case .withRail(let style): G2Layout.mainWidth(style)
        }
        // Full-width screens keep the full height; only the choicesBelow shape shares it.
        let height: Int = shape == .choicesBelow ? G2Layout.choicesBelowMainHeight : G2Layout.height
        return G2TextBox(id: mainID, name: "main", x: 0, y: 0, width: width,
                         height: height, capturesEvents: true, text: text)
    }

    static func rail(_ text: String, style: DisplayStyle) -> G2TextBox {
        G2TextBox(id: railID, name: "rail", x: G2Layout.railX(style), y: G2Layout.railY(style),
                  width: G2Layout.railWidth(style), height: G2Layout.railHeight(style),
                  capturesEvents: false, text: text)
    }
}

/// Decides what to send to show a frame, given what the glasses show now. Pure, so the diffing is
/// testable without Bluetooth.
///
/// - First frame of a session: Cmd 0 CreateStartUpPage with the frame's shape.
/// - Same shape: Cmd 5 text updates, only for containers whose text changed.
/// - Other shape, or the page state is unknown after a failure: Cmd 7 RebuildPage.
public struct G2PagePlanner: Equatable, Sendable {
    public enum Command: Equatable, Sendable {
        case create([G2TextBox])
        case rebuild([G2TextBox])
        case update(id: Int, name: String, text: String)
    }

    private enum State: Equatable, Sendable {
        /// No page yet this session.
        case none
        case live(G2PageShape, texts: [Int: String])
        /// A page exists, but we don't know what it shows (a send failed).
        case unknown
    }

    private var state = State.none

    public init() {}

    /// Whether a page has been created this session. IMU and mic only work with a live page.
    public var hasPage: Bool { state != .none }

    public var shape: G2PageShape? {
        if case .live(let shape, _) = state { return shape }
        return nil
    }

    /// The commands that show `frame`, and assumes they all succeed. Call `markUnknown()` if one
    /// fails.
    public mutating func plan(_ frame: GlassesFrame) -> [Command] {
        let shape: G2PageShape = frame.rail == nil
            ? .fullWidth
            : (frame.style == .choicesBelow ? .choicesBelow : .withRail(frame.style))
        var boxes = [G2TextBox.main(Self.text(frame.main), shape: shape, style: frame.style)]
        if let rail = frame.rail, shape != .fullWidth {
            boxes.append(.rail(Self.text(rail), style: frame.style))
        }
        let texts = Dictionary(uniqueKeysWithValues: boxes.map { ($0.id, $0.text) })

        let commands: [Command]
        switch state {
        case .none:
            commands = [.create(boxes)]
        case .live(let current, let shown) where current == shape:
            commands = boxes.filter { shown[$0.id] != $0.text }
                .map { .update(id: $0.id, name: $0.name, text: $0.text) }
        case .live, .unknown:
            commands = [.rebuild(boxes)]
        }
        state = .live(shape, texts: texts)
        return commands
    }

    /// A send failed: the next frame rebuilds the page instead of updating it. A page can only be
    /// created once per session, so this never goes back to `create`.
    public mutating func markUnknown() {
        if state != .none { state = .unknown }
    }

    /// The session ended (disconnect): the next frame creates a new page.
    public mutating func reset() {
        state = .none
    }

    private static func text(_ text: String) -> String {
        text.isEmpty ? G2Layout.blank : text
    }
}
