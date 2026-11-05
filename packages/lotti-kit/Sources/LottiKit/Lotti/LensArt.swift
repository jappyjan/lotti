import Foundation

/// The pictures Lotti draws on the lens: weather, timer, calendar, bell, check. One colour (lit or
/// off), drawn from circles and lines at their final size rather than scaled-up pixel art, so the
/// curves stay smooth on the lens.
public enum LensIcon: Equatable, Hashable, Sendable {
    case sun, partlyCloudy, cloud, fog, drizzle, rain, heavyRain, snow, storm
    case calendar, bell, check
    /// A stopwatch whose dial is filled for the share of time still left (0...1).
    case timer(left: Double)

    /// The picture for one of `OpenMeteo.condition`'s words.
    public init(condition: String) {
        switch condition {
        case "clear": self = .sun
        case "mostly clear", "partly cloudy": self = .partlyCloudy
        case "foggy": self = .fog
        case "drizzly": self = .drizzle
        case "light rain", "rainy", "freezing rain": self = .rain
        case "heavy rain": self = .heavyRain
        case "light snow", "snowy": self = .snow
        case "stormy": self = .storm
        default: self = .cloud
        }
    }
}

public enum LensArt {
    /// Icons are this many pixels square (the bell a little bigger).
    public static let iconSize = 32
    public static let bellSize = 44

    public static func bitmap(_ icon: LensIcon) -> MonoBitmap {
        switch icon {
        case .sun: return sun(center: (16, 16), radius: 6, rays: (9, 14))
        case .partlyCloudy:
            var art = sun(center: (10, 10), radius: 4, rays: (7, 9))
            let cloud = cloudShape(dx: 4, dy: 6)
            art.punch(cloud.grown(by: 2))  // a dark gap between sun and cloud
            art.draw(outline(cloud), x: 0, y: 0)
            return art
        case .cloud: return outline(cloudShape(dx: 0, dy: 3))
        case .fog:
            var art = outline(cloudShape(dx: 0, dy: -3))
            for y in [23, 27] { art.fill(x: 4, y: y, width: 24, height: 2) }
            art.fill(x: 8, y: 31, width: 16, height: 1)
            return art
        case .drizzle:
            var art = outline(cloudShape(dx: 0, dy: -4))
            for (x, y) in [(10, 25), (16, 28), (22, 25), (13, 30), (19, 31)] { art.fill(x: x, y: y, width: 2, height: 2) }
            return art
        case .rain: return rain(drops: [10, 16, 22], length: 6)
        case .heavyRain: return rain(drops: [8, 13, 18, 23], length: 9)
        case .snow:
            var art = outline(cloudShape(dx: 0, dy: -4))
            for (x, y) in [(10, 25), (22, 25), (16, 29)] { art.flake(x: x, y: y) }
            return art
        case .storm:
            var art = outline(cloudShape(dx: 0, dy: -4))
            art.punch(bolt(widened: true))
            art.draw(bolt(widened: false), x: 0, y: 0)
            return art
        case .calendar: return calendar()
        case .bell: return bell()
        case .check:
            var art = MonoBitmap(width: iconSize, height: iconSize)
            art.line(from: (5, 17), to: (12, 24), width: 4)
            art.line(from: (12, 24), to: (27, 8), width: 4)
            return art
        case .timer(let left): return timer(left: left)
        }
    }

    // MARK: Big digits

    /// A 5 × 7 font for the clock, drawn at `scale`.
    public static func digits(_ text: String, scale: Int = 4) -> MonoBitmap {
        let glyphs = text.compactMap { font[$0] }
        let widths = glyphs.map { ($0.first?.count ?? 0) * scale }
        let gap = scale
        var art = MonoBitmap(width: widths.reduce(0, +) + gap * max(glyphs.count - 1, 0), height: 7 * scale)
        var x = 0
        for (glyph, width) in zip(glyphs, widths) {
            art.draw(MonoBitmap(rows: glyph).scaled(by: scale), x: x, y: 0)
            x += width + gap
        }
        return art
    }

    static let font: [Character: [String]] = [
        "0": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["####.", "....#", "....#", ".###.", "....#", "....#", "####."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
        ":": [".", "#", ".", ".", ".", "#", "."],
    ]

    // MARK: Forecast

    /// A day's icon over a bar from its low to its high, on the scale of the whole forecast (the
    /// dotted track), with the low under the bar's left end and the high under its right end.
    public static func day(_ icon: LensIcon, low: Int, high: Int, of range: ClosedRange<Int>, width: Int) -> MonoBitmap {
        let barTop = iconSize + 6
        let lowLabel = small("\(low)°"), highLabel = small("\(high)°")
        let labelTop = barTop + 4 + 4
        var art = MonoBitmap(width: width, height: labelTop + lowLabel.height)
        art.draw(bitmap(icon), x: (width - iconSize) / 2, y: 0)
        let inset = 6
        let track = width - 2 * inset
        for x in stride(from: inset, to: inset + track, by: 3) { art[x, barTop + 2] = true }
        let span = Double(max(range.upperBound - range.lowerBound, 1))
        let from = inset + Int(Double(low - range.lowerBound) / span * Double(track - 4))
        let to = inset + Int(Double(high - range.lowerBound) / span * Double(track - 4)) + 4
        art.fill(x: from, y: barTop, width: max(to - from, 4), height: 4)

        // Labels at the bar's ends; on a short bar they move apart around its middle.
        let gap = 6
        var lowX = from, highX = to - highLabel.width
        if lowX + lowLabel.width + gap > highX {
            let both = lowLabel.width + gap + highLabel.width
            lowX = (from + to) / 2 - both / 2
            highX = lowX + lowLabel.width + gap
        }
        let shift = min(max(0, -lowX), width) - max(0, highX + highLabel.width - width)  // keep both on the picture
        art.draw(lowLabel, x: lowX + shift, y: labelTop)
        art.draw(highLabel, x: highX + shift, y: labelTop)
        return art
    }

    /// Small numbers for labels: a 3 × 5 font (with ° and −) at 3×, about as tall as the text.
    public static func small(_ text: String, scale: Int = 3) -> MonoBitmap {
        let glyphs = text.compactMap { smallFont[$0] }
        let widths = glyphs.map { ($0.first?.count ?? 0) * scale }
        var art = MonoBitmap(width: widths.reduce(0, +) + scale * max(glyphs.count - 1, 0), height: 5 * scale)
        var x = 0
        for (glyph, width) in zip(glyphs, widths) {
            art.draw(MonoBitmap(rows: glyph).scaled(by: scale), x: x, y: 0)
            x += width + scale
        }
        return art
    }

    static let smallFont: [Character: [String]] = BuiltInIndicatorIcons.digits.merging([
        "°": ["##", "##", "..", "..", ".."],
        "-": ["...", "...", "###", "...", "..."],
    ]) { current, _ in current }

    // MARK: Shapes

    private static func sun(center: (Int, Int), radius: Int, rays: (Int, Int)) -> MonoBitmap {
        var art = MonoBitmap(width: iconSize, height: iconSize)
        art.disc(center: center, radius: Double(radius))
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4
            let from = (center.0 + Int((Double(rays.0) * cos(angle)).rounded()), center.1 + Int((Double(rays.0) * sin(angle)).rounded()))
            let to = (center.0 + Int((Double(rays.1) * cos(angle)).rounded()), center.1 + Int((Double(rays.1) * sin(angle)).rounded()))
            art.line(from: from, to: to, width: 2)
        }
        return art
    }

    /// A filled cloud: three bumps on a flat base.
    private static func cloudShape(dx: Int, dy: Int) -> MonoBitmap {
        var art = MonoBitmap(width: iconSize, height: iconSize)
        art.disc(center: (10 + dx, 18 + dy), radius: 5.5)
        art.disc(center: (17 + dx, 13 + dy), radius: 7.5)
        art.disc(center: (24 + dx, 18 + dy), radius: 5)
        art.fill(x: 10 + dx, y: 17 + dy, width: 15, height: 7)
        return art
    }

    /// The edge of a filled shape, two pixels wide.
    private static func outline(_ shape: MonoBitmap) -> MonoBitmap {
        var art = MonoBitmap(width: shape.width, height: shape.height)
        for y in 0..<shape.height {
            for x in 0..<shape.width where shape[x, y] {
                let inner = (-2...2).allSatisfy { oy in (-2...2).allSatisfy { ox in abs(ox) + abs(oy) > 2 || shape[x + ox, y + oy] } }
                if !inner { art[x, y] = true }
            }
        }
        return art
    }

    private static func rain(drops: [Int], length: Int) -> MonoBitmap {
        var art = outline(cloudShape(dx: 0, dy: -4))
        for x in drops { art.line(from: (x + 2, 23), to: (x - 1, 23 + length), width: 2) }
        return art
    }

    private static func bolt(widened: Bool) -> MonoBitmap {
        var art = MonoBitmap(width: iconSize, height: iconSize)
        let width = widened ? 6 : 2
        art.line(from: (18, 14), to: (13, 23), width: width)
        art.line(from: (13, 23), to: (19, 23), width: width)
        art.line(from: (19, 23), to: (14, 31), width: width)
        return art
    }

    private static func calendar() -> MonoBitmap {
        var art = MonoBitmap(width: iconSize, height: iconSize)
        art.frame(x: 3, y: 6, width: 26, height: 23, thickness: 2)
        art.fill(x: 3, y: 6, width: 26, height: 6)
        art.fill(x: 9, y: 2, width: 2, height: 7)
        art.fill(x: 21, y: 2, width: 2, height: 7)
        for row in 0..<3 { for column in 0..<4 { art.fill(x: 7 + column * 5, y: 15 + row * 4, width: 3, height: 2) } }
        return art
    }

    private static func bell() -> MonoBitmap {
        let size = bellSize
        var shape = MonoBitmap(width: size, height: size)
        shape.disc(center: (22, 16), radius: 10)
        for y in 16..<34 {
            let half = 10 + (y - 16) * 7 / 18
            shape.fill(x: 22 - half, y: y, width: 2 * half + 1, height: 1)
        }
        var art = outline(shape)
        art.fill(x: 4, y: 32, width: 37, height: 3)
        art.disc(center: (22, 38), radius: 3.5)
        art.fill(x: 20, y: 3, width: 5, height: 4)
        // Two strokes either side: it rings.
        art.line(from: (3, 10), to: (6, 17), width: 2)
        art.line(from: (41, 10), to: (38, 17), width: 2)
        return art
    }

    private static func timer(left: Double) -> MonoBitmap {
        var art = MonoBitmap(width: iconSize, height: iconSize)
        let center = (16.0, 18.0)
        art.ring(center: (16, 18), radius: 12.5, thickness: 2)
        art.fill(x: 13, y: 1, width: 6, height: 2)
        art.fill(x: 15, y: 3, width: 2, height: 3)
        art.line(from: (25, 6), to: (27, 8), width: 2)
        // The time still left, as a wedge clockwise from 12 o'clock.
        let share = min(max(left, 0), 1)
        for y in 0..<iconSize {
            for x in 0..<iconSize {
                let dx = Double(x) + 0.5 - center.0, dy = Double(y) + 0.5 - center.1
                guard dx * dx + dy * dy <= 9 * 9 else { continue }
                var angle = atan2(dx, -dy)  // 0 at 12 o'clock, clockwise
                if angle < 0 { angle += 2 * .pi }
                if angle <= share * 2 * .pi { art[x, y] = true }
            }
        }
        art.disc(center: (16, 18), radius: 1.5)
        return art
    }
}

extension MonoBitmap {
    mutating func fill(x: Int, y: Int, width: Int, height: Int) {
        for py in y..<(y + max(height, 0)) { for px in x..<(x + max(width, 0)) { self[px, py] = true } }
    }

    mutating func frame(x: Int, y: Int, width: Int, height: Int, thickness: Int) {
        fill(x: x, y: y, width: width, height: thickness)
        fill(x: x, y: y + height - thickness, width: width, height: thickness)
        fill(x: x, y: y, width: thickness, height: height)
        fill(x: x + width - thickness, y: y, width: thickness, height: height)
    }

    mutating func disc(center: (Int, Int), radius: Double) {
        for py in 0..<height {
            for px in 0..<width {
                let dx = Double(px - center.0), dy = Double(py - center.1)
                if dx * dx + dy * dy <= radius * radius { self[px, py] = true }
            }
        }
    }

    mutating func ring(center: (Int, Int), radius: Double, thickness: Double) {
        for py in 0..<height {
            for px in 0..<width {
                let d = (Double(px - center.0) * Double(px - center.0) + Double(py - center.1) * Double(py - center.1)).squareRoot()
                if d <= radius, d > radius - thickness { self[px, py] = true }
            }
        }
    }

    /// A straight stroke `width` pixels thick.
    mutating func line(from a: (Int, Int), to b: (Int, Int), width: Int) {
        let steps = max(abs(b.0 - a.0), abs(b.1 - a.1), 1) * 2
        let reach = Double(width) / 2
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let x = Double(a.0) + (Double(b.0) - Double(a.0)) * t
            let y = Double(a.1) + (Double(b.1) - Double(a.1)) * t
            for py in Int((y - reach).rounded(.down))...Int((y + reach).rounded(.up)) {
                for px in Int((x - reach).rounded(.down))...Int((x + reach).rounded(.up)) {
                    let dx = Double(px) + 0.5 - x, dy = Double(py) + 0.5 - y
                    if dx * dx + dy * dy <= reach * reach { self[px, py] = true }
                }
            }
        }
    }

    /// Clears every pixel that is lit in `mask`.
    mutating func punch(_ mask: MonoBitmap) {
        for py in 0..<min(height, mask.height) { for px in 0..<min(width, mask.width) where mask[px, py] { self[px, py] = false } }
    }

    /// A small snowflake centred on (x, y).
    mutating func flake(x: Int, y: Int) {
        draw(MonoBitmap(rows: ["..#..", "#.#.#", ".###.", "#.#.#", "..#.."]), x: x - 2, y: y - 2)
    }

    /// The shape with every lit pixel spread `radius` pixels in each direction.
    func grown(by radius: Int) -> MonoBitmap {
        var result = self
        for py in 0..<height {
            for px in 0..<width where self[px, py] {
                for oy in -radius...radius { for ox in -radius...radius where ox * ox + oy * oy <= radius * radius { result[px + ox, py + oy] = true } }
            }
        }
        return result
    }
}
