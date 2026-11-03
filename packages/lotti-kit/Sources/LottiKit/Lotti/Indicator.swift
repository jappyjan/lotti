import Foundation

/// A 1-bit picture: lit pixels are drawn (green on the lens), the rest is black, which is
/// invisible. Row-major, top row first.
public struct MonoBitmap: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [Bool]

    public init(width: Int, height: Int, pixels: [Bool]? = nil) {
        self.width = width
        self.height = height
        self.pixels = pixels ?? [Bool](repeating: false, count: width * height)
    }

    /// From picture rows: `#` is lit, anything else off. Rows may differ in length.
    public init(rows: [String]) {
        let width = rows.map(\.count).max() ?? 0
        self.init(width: width, height: rows.count)
        for (y, row) in rows.enumerated() {
            for (x, character) in row.enumerated() where character == "#" { pixels[y * width + x] = true }
        }
    }

    public subscript(x: Int, y: Int) -> Bool {
        get { x >= 0 && y >= 0 && x < width && y < height && pixels[y * width + x] }
        set { if x >= 0, y >= 0, x < width, y < height { pixels[y * width + x] = newValue } }
    }

    public var litCount: Int { pixels.filter { $0 }.count }

    /// Every pixel becomes a `factor × factor` block.
    public func scaled(by factor: Int) -> MonoBitmap {
        guard factor > 1 else { return self }
        var result = MonoBitmap(width: width * factor, height: height * factor)
        for y in 0..<result.height { for x in 0..<result.width { result[x, y] = self[x / factor, y / factor] } }
        return result
    }

    /// Copies the lit pixels of `other` onto this bitmap at (x, y).
    public mutating func draw(_ other: MonoBitmap, x: Int, y: Int) {
        for oy in 0..<other.height { for ox in 0..<other.width where other[ox, oy] { self[x + ox, y + oy] = true } }
    }

    /// RGBA for `NavMapBmp.encode`: lit pixels saturated green (its "road" colour), the rest transparent.
    public func rgba() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for index in pixels.indices where pixels[index] {
            out[index * 4 + 1] = 255
            out[index * 4 + 3] = 255
        }
        return out
    }

    /// The picture as text, for tests and logs.
    public var picture: String {
        (0..<height).map { y in String((0..<width).map { x in self[x, y] ? "#" : "." }) }.joined(separator: "\n")
    }
}

/// The small pictures the glasses' indicators are made of.
public enum IndicatorIcon: Hashable, Sendable {
    case mail, calendar, job, reminder, info, location

    public init(_ kind: InboxKind) {
        switch kind {
        case .mail: self = .mail
        case .calendar: self = .calendar
        case .job: self = .job
        case .reminder: self = .reminder
        case .info: self = .info
        }
    }
}

/// Where the indicator pictures come from. The app can implement this with CoreGraphics
/// (SF Symbols, a proper font) and return nil for what it doesn't draw; `BuiltInIndicatorIcons`
/// fills in, so tests and the default work without UIKit.
///
/// Icons should be about 24 × 24 px and counts about 15 px tall: the display is 576 × 288 and an
/// image container is at least 20 × 20 px.
public protocol IndicatorIconProvider: Sendable {
    func icon(_ icon: IndicatorIcon) -> MonoBitmap?
    /// The number next to an icon (1...99).
    func count(_ number: Int) -> MonoBitmap?
}

extension IndicatorIconProvider {
    public func icon(_ icon: IndicatorIcon) -> MonoBitmap? { nil }
    public func count(_ number: Int) -> MonoBitmap? { nil }
}

/// Hand-drawn 12 × 12 icons (drawn at 2×, so 24 × 24) and a 3 × 5 digit font (drawn at 3×).
public struct BuiltInIndicatorIcons: IndicatorIconProvider {
    public static let iconScale = 2
    public static let digitScale = 3

    public init() {}

    public func icon(_ icon: IndicatorIcon) -> MonoBitmap? {
        MonoBitmap(rows: Self.pictures[icon]!).scaled(by: Self.iconScale)
    }

    /// Digits side by side, 3 px apart (at digit scale 3 px = 1 font pixel).
    public func count(_ number: Int) -> MonoBitmap? {
        let digits = String(min(max(number, 0), 99)).compactMap { Self.digits[$0] }
        let glyphWidth = 3 * Self.digitScale
        let gap = Self.digitScale
        var bitmap = MonoBitmap(width: digits.count * glyphWidth + max(digits.count - 1, 0) * gap, height: 5 * Self.digitScale)
        for (index, glyph) in digits.enumerated() {
            bitmap.draw(MonoBitmap(rows: glyph).scaled(by: Self.digitScale), x: index * (glyphWidth + gap), y: 0)
        }
        return bitmap
    }

    static let pictures: [IndicatorIcon: [String]] = [
        .mail: [
            "............",
            "############",
            "##........##",
            "###......###",
            "#.##....##.#",
            "#..##..##..#",
            "#...####...#",
            "#....##....#",
            "#..........#",
            "#..........#",
            "############",
            "............",
        ],
        .calendar: [
            "..#......#..",
            "..#......#..",
            "############",
            "#..........#",
            "############",
            "#.#.#.#.#..#",
            "#..........#",
            "#.#.#.#.#..#",
            "#..........#",
            "#.#.#.#.#..#",
            "#..........#",
            "############",
        ],
        .job: [
            "....####....",
            "....#..#....",
            "############",
            "#..........#",
            "#..........#",
            "############",
            "#....##....#",
            "#....##....#",
            "#..........#",
            "#..........#",
            "#..........#",
            "############",
        ],
        .reminder: [
            ".....##.....",
            "....####....",
            "...#....#...",
            "...#....#...",
            "..#......#..",
            "..#......#..",
            ".#........#.",
            ".#........#.",
            "############",
            "............",
            ".....##.....",
            "............",
        ],
        .info: [
            "....####....",
            "..##....##..",
            ".#...##...#.",
            ".#........#.",
            "#....##....#",
            "#....##....#",
            "#....##....#",
            "#....##....#",
            ".#...##...#.",
            ".#...##...#.",
            "..##....##..",
            "....####....",
        ],
        .location: [
            "....####....",
            "...######...",
            "..##....##..",
            "..#..##..#..",
            "..#..##..#..",
            "..##....##..",
            "...##..##...",
            "....####....",
            ".....##.....",
            ".....##.....",
            "......#.....",
            "............",
        ],
    ]

    static let digits: [Character: [String]] = [
        "0": ["###", "#.#", "#.#", "#.#", "###"],
        "1": [".#.", "##.", ".#.", ".#.", "###"],
        "2": ["###", "..#", "###", "#..", "###"],
        "3": ["###", "..#", "###", "..#", "###"],
        "4": ["#.#", "#.#", "###", "..#", "..#"],
        "5": ["###", "#..", "###", "..#", "###"],
        "6": ["###", "#..", "###", "#.#", "###"],
        "7": ["###", "..#", "..#", "..#", "..#"],
        "8": ["###", "#.#", "###", "#.#", "###"],
        "9": ["###", "#.#", "###", "..#", "###"],
    ]
}

/// How many items of one kind wait.
public struct IndicatorCount: Equatable, Sendable {
    public var kind: InboxKind
    public var count: Int

    public init(kind: InboxKind, count: Int) {
        self.kind = kind
        self.count = count
    }
}

/// What the glasses' indicators show.
public struct IndicatorState: Equatable, Sendable {
    /// Pending inbox items per kind. Empty: no attention indicator.
    public var attention: [IndicatorCount]
    /// A location read runs, or ended a moment ago.
    public var locationActive: Bool

    public init(attention: [IndicatorCount] = [], locationActive: Bool = false) {
        self.attention = attention
        self.locationActive = locationActive
    }

    public var isEmpty: Bool { attention.isEmpty && !locationActive }
}

/// Turns an `IndicatorState` into the image containers the glasses draw.
///
/// Placement keeps clear of Lotti's sentence and the choices:
/// - **Attention** (kind icons with counts) sits in the top-right corner and only while the
///   display is off (`showAttention`): it is a "something is waiting" mark, never a screen, and
///   never over text.
/// - **Location** (the pin) sits in the bottom-right corner and only when the frame has no
///   choices (`showLocation`): with choices the bottom right belongs to them.
public struct IndicatorRenderer: Sendable {
    public var icons: any IndicatorIconProvider
    /// Gap to the display's edge.
    public var margin = 4
    /// At most this many kinds fit next to each other.
    public static let maxKinds = 4

    public init(icons: any IndicatorIconProvider = BuiltInIndicatorIcons()) {
        self.icons = icons
    }

    func icon(_ icon: IndicatorIcon) -> MonoBitmap {
        self.icons.icon(icon) ?? BuiltInIndicatorIcons().icon(icon)!
    }

    func count(_ number: Int) -> MonoBitmap {
        icons.count(number) ?? BuiltInIndicatorIcons().count(number)!
    }

    /// The attention strip: for each kind present, its icon and the count, left to right.
    public func attentionBitmap(_ counts: [IndicatorCount]) -> MonoBitmap? {
        let shown = Array(counts.filter { $0.count > 0 }.prefix(Self.maxKinds))
        guard !shown.isEmpty else { return nil }
        let parts = shown.map { (icon(IndicatorIcon($0.kind)), count($0.count)) }
        let iconGap = 4, groupGap = 10
        let height = parts.map { max($0.0.height, $0.1.height) }.max() ?? 0
        let width = parts.map { $0.0.width + iconGap + $0.1.width }.reduce(0, +) + groupGap * (parts.count - 1)
        var bitmap = MonoBitmap(width: width, height: height)
        var x = 0
        for (picture, number) in parts {
            bitmap.draw(picture, x: x, y: (height - picture.height) / 2)
            x += picture.width + iconGap
            bitmap.draw(number, x: x, y: (height - number.height) / 2)
            x += number.width + groupGap
        }
        return bitmap
    }

    public func images(for state: IndicatorState, showAttention: Bool, showLocation: Bool) -> [G2ImageBox] {
        var images: [G2ImageBox] = []
        if showAttention, let bitmap = attentionBitmap(state.attention),
           let box = G2ImageBox(id: G2ImageBox.attentionID, name: "attention", x: G2Layout.width - bitmap.width - margin,
                                y: margin, bitmap: bitmap) {
            images.append(box)
        }
        if showLocation, state.locationActive {
            let bitmap = icon(.location)
            if let box = G2ImageBox(id: G2ImageBox.locationID, name: "location", x: G2Layout.width - bitmap.width - margin,
                                    y: G2Layout.height - bitmap.height - margin, bitmap: bitmap) {
                images.append(box)
            }
        }
        return images
    }
}
