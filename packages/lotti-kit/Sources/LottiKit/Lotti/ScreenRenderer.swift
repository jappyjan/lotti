import Foundation

/// The layout variants for testing choices ([design.md](../../../../docs/design.md) "The rail is
/// too narrow"). Switched with a debug setting on the phone; the winner becomes the only one.
public enum DisplayStyle: String, CaseIterable, Codable, Equatable, Sendable {
    /// Lotti's sentence left, choices in a 176 px column on the right (today).
    case rail
    /// A wider rail (240 px) with three choices instead of four.
    case wideRail
    /// The sentence across the whole display; the choices in one block underneath.
    case choicesBelow

    /// How many rail items the style shows. `rail` and `choicesBelow` keep all four; `wideRail`
    /// trades the fourth for wider items.
    public var maxRailItems: Int {
        switch self {
        case .rail, .choicesBelow: Rail.maxItems
        case .wideRail: 3
        }
    }
}

/// How much text fits on the lens. The G2 font is proportional with no size control; about 50
/// average characters × 10 lines fit on the full 576 × 288 display (g2-kit `ble/docs/text.md`).
/// The numbers are kept a little under that so the firmware doesn't wrap or add a scroll bar.
public struct TextLayout: Equatable, Sendable {
    public var fullWidthColumns: Int
    public var mainColumnsWithRail: Int
    public var railColumns: Int
    public var lines: Int

    public init(fullWidthColumns: Int = 46, mainColumnsWithRail: Int = 31, railColumns: Int = 13, lines: Int = 9) {
        self.fullWidthColumns = fullWidthColumns
        self.mainColumnsWithRail = mainColumnsWithRail
        self.railColumns = railColumns
        self.lines = lines
    }

    public static let g2 = TextLayout()

    /// `wideRail`: the sentence drops to ~26 characters a line, the rail to ~18 (240 px).
    public static let wideRail = TextLayout(fullWidthColumns: 46, mainColumnsWithRail: 26, railColumns: 20, lines: 9)
}

/// Turns a `Screen` into the two strings the glasses draw. Wraps text itself so nothing scrolls
/// off the lens: the sentence first, a blank line, then as many details as fit.
public struct ScreenRenderer: Sendable {
    public var style: DisplayStyle
    public var layout: TextLayout
    /// Marks the highlighted rail item. The lens can't dim single lines inside a container, so the
    /// highlight is a marker in front of the item.
    public static let highlightMarker = "> "
    public static let plainMarker = "  "

    /// Lines for the sentence when the choices sit below it (of the G2's 10).
    public static let choicesBelowMainLines = 6

    public init(style: DisplayStyle = .rail, layout: TextLayout = .g2) {
        self.style = style
        self.layout = layout
    }

    public func render(_ screen: Screen) -> GlassesFrame {
        if style == .choicesBelow { return renderBelow(screen) }
        let layout = style == .wideRail ? TextLayout.wideRail : self.layout
        let columns = screen.rail == nil ? layout.fullWidthColumns : layout.mainColumnsWithRail
        var lines = Self.wrap(screen.text, columns: columns)
        if lines.count > layout.lines {
            lines = Array(lines.prefix(layout.lines))
            lines[lines.count - 1] = Self.ellipsize(lines[lines.count - 1], columns: columns)
        }
        let details = screen.details.flatMap { Self.wrap($0, columns: columns) }
        if !details.isEmpty, lines.count + 1 + 1 <= layout.lines {
            lines.append("")
            lines += details.prefix(layout.lines - lines.count)
        }
        return GlassesFrame(main: lines.joined(separator: "\n"),
                            rail: screen.rail.map { renderRail($0, layout: layout) }, style: style)
    }

    /// The sentence takes the full width; the choices sit below it, one per line. Only works with
    /// short sentences: the sentence gets 6 of the 10 lines, the choices the rest. Without choices
    /// the sentence keeps the full height.
    private func renderBelow(_ screen: Screen) -> GlassesFrame {
        let columns = layout.fullWidthColumns
        let maxLines = screen.rail == nil ? layout.lines : Self.choicesBelowMainLines
        var lines = Self.wrap(screen.text, columns: columns)
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            lines[lines.count - 1] = Self.ellipsize(lines[lines.count - 1], columns: columns)
        }
        let details = screen.details.flatMap { Self.wrap($0, columns: columns) }
        if !details.isEmpty, lines.count + 1 + 1 <= maxLines {
            lines.append("")
            lines += details.prefix(maxLines - lines.count)
        }
        let rail = screen.rail.map { rail in
            let width = columns - Self.highlightMarker.count
            return rail.items.enumerated().map { index, item in
                let marker = index == rail.highlighted ? Self.highlightMarker : Self.plainMarker
                return marker + Self.ellipsize(item.title, columns: width)
            }.joined(separator: "\n")
        }
        return GlassesFrame(main: lines.joined(separator: "\n"), rail: rail, style: .choicesBelow)
    }

    func renderRail(_ rail: Rail, layout: TextLayout) -> String {
        let width = layout.railColumns - Self.highlightMarker.count
        return rail.items.enumerated().map { index, item in
            let marker = index == rail.highlighted ? Self.highlightMarker : Self.plainMarker
            return marker + Self.ellipsize(item.title, columns: width)
        }.joined(separator: "\n")
    }

    /// Greedy word wrap. Words longer than a line are cut. Existing line breaks are kept.
    public static func wrap(_ text: String, columns: Int) -> [String] {
        guard columns > 0 else { return [] }
        var result: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
                var word = String(word)
                while word.count > columns {
                    if !line.isEmpty { result.append(line); line = "" }
                    result.append(String(word.prefix(columns)))
                    word = String(word.dropFirst(columns))
                }
                if line.isEmpty {
                    line = word
                } else if line.count + 1 + word.count <= columns {
                    line += " " + word
                } else {
                    result.append(line)
                    line = word
                }
            }
            result.append(line)
        }
        while result.last == "" { result.removeLast() }
        return result
    }

    static func ellipsize(_ text: String, columns: Int) -> String {
        guard text.count > columns else { return text }
        return String(text.prefix(max(columns - 1, 0))) + "…"
    }
}
