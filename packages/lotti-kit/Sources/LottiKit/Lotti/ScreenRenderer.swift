import Foundation

/// How much text fits on the lens. The G2 font is proportional with no size control; about 50
/// average characters × 10 lines fit on the full 576 × 288 display (g2-kit `ble/docs/text.md`).
/// The numbers are kept a little under that so the firmware doesn't wrap or add a scroll bar.
public struct TextLayout: Equatable, Sendable {
    public var fullWidthColumns: Int
    public var lines: Int

    public init(fullWidthColumns: Int = 46, lines: Int = 9) {
        self.fullWidthColumns = fullWidthColumns
        self.lines = lines
    }

    public static let g2 = TextLayout()

    /// Characters that fit in a box this many pixels wide, at the same density as a full line.
    func columns(width: Int) -> Int { max(width * fullWidthColumns / G2Layout.width, 1) }
    /// Lines that fit in a box this many pixels high.
    func lines(height: Int) -> Int { max(height / G2Layout.lineHeight, 1) }
}

/// Turns a `Screen` into text boxes on the lens. Wraps text itself so nothing scrolls off.
/// Choices always sit below, one per line, across the full width (decided 2026-11-01, see
/// design.md "The rail is too narrow").
///
/// A plain screen is the sentence (then a blank line and as many details as fit) in the top six
/// lines and the choices block under it; without choices the sentence gets the whole display. A
/// screen with a header or cards is stacked:
///
/// ```
/// Thu 5 Nov                                  14:05   header: date, clock
/// Dentist in 25 min.                                 sentence (+ details)
/// +2 more today
/// Pasta          12° cloudy      Later               cards, side by side
/// 4 min left     7° to 14°       16:00 Standup
/// Rings 14:09    Rain from 18:00 20:00 Pizza
/// > Agenda                                           choices, as many lines as there are
///   Weather
/// ```
public struct ScreenRenderer: Sendable {
    public var layout: TextLayout
    /// Marks the highlighted choice. The lens can't dim single lines inside a container, so the
    /// highlight is a marker in front of the item.
    public static let highlightMarker = "> "
    public static let plainMarker = "  "

    /// Lines for a plain sentence above the choices (of the G2's 10).
    public static let choicesBelowMainLines = 6
    static let clockWidth = 72
    static let gap = 4
    static let cardGap = 8
    /// Space between a picture and the text next to it.
    static let artGap = 10
    public static let maxCards = 5
    /// The clock in the header is drawn this big (5 × 7 font × 4 = 28 px tall).
    static let clockScale = 4
    static let bigHeaderHeight = 32
    /// Pictures get ids from here (text uses 1, 2 and 10+, the indicators 3 and 4).
    public static let firstImageID = 20
    /// The page holds 12 containers (text and images together).
    static let maxContainers = 12

    public init(layout: TextLayout = .g2) {
        self.layout = layout
    }

    public func render(_ screen: Screen) -> GlassesFrame {
        if screen.header != nil || !screen.cards.isEmpty, let frame = renderStacked(screen) { return frame }
        return renderPlain(screen)
    }

    /// A picture placed on the lens, before it becomes an image container.
    struct Art {
        var name: String
        var x: Int
        var y: Int
        var bitmap: MonoBitmap
    }

    /// Sentence on top (with the details, after its icon if it has one), choices in the fixed
    /// block underneath.
    func renderPlain(_ screen: Screen) -> GlassesFrame {
        var details = screen.details
        if let header = screen.header {
            details.insert([header.left, header.right].filter { !$0.isEmpty }.joined(separator: " · "), at: 0)
        }
        details += screen.cards.map { ([$0.title] + $0.lines).joined(separator: ", ") }
        let maxLines = screen.rail == nil ? layout.lines : Self.choicesBelowMainLines
        let rail = screen.rail.map(renderChoices)
        guard let icon = screen.icon else {
            let lines = Self.mainLines(screen.kind, screen.text, details: details, columns: layout.fullWidthColumns,
                                       maxLines: maxLines)
            return GlassesFrame(main: lines.joined(separator: "\n"), rail: rail)
        }
        let bitmap = LensArt.bitmap(icon)
        let x = bitmap.width + Self.artGap + 4
        let lines = Self.mainLines(screen.kind, screen.text, details: details,
                                   columns: layout.columns(width: G2Layout.width - x), maxLines: maxLines)
        var frame = GlassesFrame(main: "", rail: rail)
        frame.boxes[0].x = x
        frame.boxes[0].width = G2Layout.width - x
        frame.boxes[0].text = lines.joined(separator: "\n")
        return finish(frame.boxes, art: [Art(name: "icon", x: 4, y: 2, bitmap: bitmap)])
    }

    /// Header, sentence, a row of cards, then exactly as many choice lines as there are choices.
    /// Nil if the cards don't get at least two lines: then the plain layout lists them instead.
    func renderStacked(_ screen: Screen) -> GlassesFrame? {
        let width = G2Layout.width
        let line = G2Layout.lineHeight
        var boxes: [FrameBox] = []
        var art: [Art] = []
        var top = 0
        if let header = screen.header {
            if !header.right.isEmpty, header.right.allSatisfy({ LensArt.font[$0] != nil }) {
                // The time big, the way a glance wants it; the date beside it.
                let clock = LensArt.digits(header.right, scale: Self.clockScale)
                art.append(Art(name: "clock", x: 2, y: 2, bitmap: clock))
                let x = clock.width + 2 * Self.artGap
                boxes.append(FrameBox("date", x: x, y: 2, width: width - x, height: line, text: header.left))
                top = Self.bigHeaderHeight + Self.gap
            } else {
                let clock = header.right.isEmpty ? 0 : Self.clockWidth
                boxes.append(FrameBox("date", x: 0, y: 0, width: width - clock, height: line, text: header.left))
                if clock > 0 {
                    boxes.append(FrameBox("clock", x: width - clock, y: 0, width: clock, height: line, text: header.right))
                }
                top = line
            }
        }
        let choicesHeight = (screen.rail?.items.count ?? 0) * line
        let bottom = choicesHeight > 0 ? G2Layout.height - choicesHeight - Self.gap : G2Layout.height
        let space = bottom - top

        let cards = Array(screen.cards.prefix(Self.maxCards))
        var sentenceHeight = space
        if !cards.isEmpty {
            sentenceHeight = max(2 * line, min(3 * line, space - 3 * line - Self.gap))
            let cardHeight = space - sentenceHeight - Self.gap
            guard cardHeight >= 2 * line else { return nil }
            let y = top + sentenceHeight + Self.gap
            let cardWidth = (width - Self.cardGap * (cards.count - 1)) / cards.count
            for (index, card) in cards.enumerated() {
                let x = index * (cardWidth + Self.cardGap)
                let name = "card\(index + 1)"
                let maxLines = layout.lines(height: cardHeight)
                switch card.art {
                case .icon(let icon):
                    let bitmap = LensArt.bitmap(icon)
                    art.append(Art(name: "art\(index + 1)", x: x, y: y + 2, bitmap: bitmap))
                    let textX = x + bitmap.width + Self.artGap
                    let columns = layout.columns(width: x + cardWidth - textX)
                    // One fact per line: a long one is cut, not wrapped into the next.
                    let text = Self.mainLines(.says, card.title, details: card.lines.map { Self.ellipsize($0, columns: columns) },
                                              columns: columns, maxLines: maxLines, blankLine: false)
                    boxes.append(FrameBox(name, x: textX, y: y, width: x + cardWidth - textX, height: cardHeight,
                                          text: text.joined(separator: "\n")))
                case .day(let icon, let low, let high, let range):
                    // Title, then the picture where two blank lines leave room for it, then the numbers.
                    let bitmap = LensArt.day(icon, low: low, high: high, of: range, width: cardWidth)
                    let pictureLines = (bitmap.height + line - 1) / line
                    art.append(Art(name: "art\(index + 1)", x: x, y: y + line + 2, bitmap: bitmap))
                    let columns = layout.columns(width: cardWidth)
                    let lines = [ScreenRenderer.ellipsize(card.title, columns: columns)]
                        + Array(repeating: "", count: pictureLines)
                        + card.lines.flatMap { Self.wrap($0, columns: columns) }
                    boxes.append(FrameBox(name, x: x, y: y, width: cardWidth, height: cardHeight,
                                          text: lines.prefix(maxLines).joined(separator: "\n")))
                case nil:
                    let text = Self.mainLines(.says, card.title, details: card.lines, columns: layout.columns(width: cardWidth),
                                              maxLines: maxLines, blankLine: false)
                    boxes.append(FrameBox(name, x: x, y: y, width: cardWidth, height: cardHeight,
                                          text: text.joined(separator: "\n")))
                }
            }
        }
        var sentenceX = 0
        if let icon = screen.icon {
            let bitmap = LensArt.bitmap(icon)
            art.append(Art(name: "icon", x: 4, y: top + 2, bitmap: bitmap))
            sentenceX = bitmap.width + Self.artGap + 4
        }
        let sentence = Self.mainLines(screen.kind, screen.text, details: screen.details,
                                      columns: layout.columns(width: width - sentenceX),
                                      maxLines: layout.lines(height: sentenceHeight))
        boxes.insert(FrameBox("main", x: sentenceX, y: top, width: width - sentenceX, height: sentenceHeight,
                              text: sentence.joined(separator: "\n")), at: 0)
        if let rail = screen.rail {
            boxes.append(FrameBox("rail", x: 0, y: G2Layout.height - choicesHeight, width: width, height: choicesHeight,
                                  text: renderChoices(rail)))
        }
        return finish(boxes, art: art)
    }

    /// At most 8 text boxes and 12 containers in all. A lone sentence keeps one free for the
    /// location pin (the Conductor shows it only there; the attention mark only with the display off).
    private func finish(_ boxes: [FrameBox], art: [Art]) -> GlassesFrame {
        let text = Array(boxes.prefix(G2Layout.maxTextBoxes))
        let reserved = text.count == 1 ? 1 : 0
        let images = art.prefix(max(Self.maxContainers - reserved - text.count, 0)).enumerated().compactMap { index, art in
            G2ImageBox(id: Self.firstImageID + index, name: art.name, x: art.x, y: art.y, bitmap: art.bitmap)
        }
        return GlassesFrame(boxes: text, images: images)
    }

    /// The text, cut to `maxLines`, then (after a blank line, if asked) as many details as still
    /// fit. An opened item (`.original`) always keeps its first detail line, the "Mail · title"
    /// header: a long body is cut further instead.
    static func mainLines(_ kind: Screen.Kind, _ text: String, details: [String], columns: Int, maxLines: Int,
                          blankLine: Bool = true) -> [String] {
        let details = details.flatMap { wrap($0, columns: columns) }
        let spacer = blankLine ? 1 : 0
        let reserved = kind == .original && !details.isEmpty && maxLines >= 3 ? 1 + spacer : 0  // blank + header
        let textLines = maxLines - reserved
        var lines = wrap(text, columns: columns)
        if lines.count > textLines {
            lines = Array(lines.prefix(textLines))
            lines[lines.count - 1] = ellipsize(lines[lines.count - 1], columns: columns)
        }
        if !details.isEmpty, lines.count + spacer + 1 <= maxLines {
            if blankLine { lines.append("") }
            lines += details.prefix(maxLines - lines.count)
        }
        return lines
    }

    /// One choice per line, the highlighted one marked.
    func renderChoices(_ rail: Rail) -> String {
        let width = layout.fullWidthColumns - Self.highlightMarker.count
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
