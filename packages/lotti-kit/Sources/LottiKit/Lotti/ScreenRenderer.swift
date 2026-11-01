import Foundation

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
}

/// Turns a `Screen` into the two strings the glasses draw. Wraps text itself so nothing scrolls
/// off the lens: the sentence first, a blank line, then as many details as fit.
public struct ScreenRenderer: Sendable {
    public var layout: TextLayout
    /// Marks the highlighted rail item. The lens can't dim single lines inside a container, so the
    /// highlight is a marker in front of the item.
    public static let highlightMarker = "> "
    public static let plainMarker = "  "

    public init(layout: TextLayout = .g2) {
        self.layout = layout
    }

    public func render(_ screen: Screen) -> GlassesFrame {
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
        return GlassesFrame(main: lines.joined(separator: "\n"), rail: screen.rail.map(renderRail))
    }

    func renderRail(_ rail: Rail) -> String {
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
