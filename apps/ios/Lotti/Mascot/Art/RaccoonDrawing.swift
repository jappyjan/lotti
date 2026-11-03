import SwiftUI

/// What a layer needs while drawing: colours and detail level (internal).
struct RaccoonDrawEnv {
    let palette: RaccoonPalette
    let compact: Bool

    /// Silhouette outline width in units.
    var outline: CGFloat { compact ? 11 : 5.5 }
    /// Inner detail line width in units (mouth, toes).
    var detail: CGFloat { compact ? 9 : 4.5 }
}

/// Hosts one layer: a `Canvas` that maps the 400 × 400 unit space (or `viewport` of it) onto
/// the view, aspect-fit and centred.
struct RaccoonCanvas: View {
    var compact: Bool?
    var viewport: CGRect = RaccoonAnchors.canvasRect
    var draw: (inout GraphicsContext, RaccoonDrawEnv) -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// Below this rendered side (points) of the full canvas, layers switch to compact detail.
    static let compactThreshold: CGFloat = 140

    var body: some View {
        let palette = RaccoonPalette.resolve(colorScheme)
        Canvas { ctx, size in
            let side = min(size.width, size.height)
            guard side > 0 else { return }
            let scale = side / viewport.width
            let isCompact = compact ?? (side * RaccoonAnchors.canvasSide / viewport.width < Self.compactThreshold)
            ctx.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -viewport.minX, y: -viewport.minY)
            draw(&ctx, RaccoonDrawEnv(palette: palette, compact: isCompact))
        }
    }
}

// MARK: - Geometry helpers

enum RaccoonGeometry {
    static func rotate(_ p: CGPoint, degrees: Double, around c: CGPoint) -> CGPoint {
        guard degrees != 0 else { return p }
        let a = CGFloat(degrees) * .pi / 180
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * cos(a) - dy * sin(a), y: c.y + dx * sin(a) + dy * cos(a))
    }

    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    static func quadBezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
            y: u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y
        )
    }

    static func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    static func cubicTangent(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGVector {
        let u = 1 - t
        let a = 3 * u * u, b = 6 * u * t, c = 3 * t * t
        let dx = a * (p1.x - p0.x) + b * (p2.x - p1.x) + c * (p3.x - p2.x)
        let dy = a * (p1.y - p0.y) + b * (p2.y - p1.y) + c * (p3.y - p2.y)
        let len = max(sqrt(dx * dx + dy * dy), 0.0001)
        return CGVector(dx: dx / len, dy: dy / len)
    }

    /// Mirror about the vertical centre line (x = 200).
    static func mirror(_ p: CGPoint) -> CGPoint { CGPoint(x: 400 - p.x, y: p.y) }

    static let mirrorTransform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 400, ty: 0)
}

/// One cubic segment: control 1, control 2, end point.
typealias RaccoonSegment = (c1: CGPoint, c2: CGPoint, to: CGPoint)

extension Path {
    /// A closed shape symmetric about x = 200, from its right half: `start` and the last
    /// segment's end must lie on x = 200 (top and bottom of the shape).
    static func raccoonSymmetric(start: CGPoint, _ segments: [RaccoonSegment]) -> Path {
        var path = Path()
        path.move(to: start)
        for s in segments { path.addCurve(to: s.to, control1: s.c1, control2: s.c2) }
        for i in stride(from: segments.count - 1, through: 0, by: -1) {
            let s = segments[i]
            let end = i == 0 ? start : segments[i - 1].to
            path.addCurve(to: RaccoonGeometry.mirror(end),
                          control1: RaccoonGeometry.mirror(s.c2),
                          control2: RaccoonGeometry.mirror(s.c1))
        }
        path.closeSubpath()
        return path
    }

    /// An open or closed run of cubic segments.
    static func raccoonCurves(start: CGPoint, _ segments: [RaccoonSegment], closed: Bool = true) -> Path {
        var path = Path()
        path.move(to: start)
        for s in segments { path.addCurve(to: s.to, control1: s.c1, control2: s.c2) }
        if closed { path.closeSubpath() }
        return path
    }

    static func raccoonEllipse(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2))
    }

    static func raccoonCircle(_ c: CGPoint, _ r: CGFloat) -> Path { raccoonEllipse(c, r, r) }

    /// This path plus its mirror image about x = 200.
    func raccoonWithMirror() -> Path {
        var p = self
        p.addPath(self.applying(RaccoonGeometry.mirrorTransform))
        return p
    }
}

extension GraphicsContext {
    func raccoonFill(_ path: Path, _ color: Color) {
        fill(path, with: .color(color))
    }

    func raccoonStroke(_ path: Path, _ color: Color, _ width: CGFloat) {
        stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    /// Fill, then a centred outline on top.
    func raccoonFillOutlined(_ path: Path, _ fill: Color, _ outline: Color, _ width: CGFloat) {
        raccoonFill(path, fill)
        raccoonStroke(path, outline, width)
    }

    mutating func raccoonRotate(degrees: Double, around c: CGPoint) {
        guard degrees != 0 else { return }
        translateBy(x: c.x, y: c.y)
        rotate(by: .degrees(degrees))
        translateBy(x: -c.x, y: -c.y)
    }

    mutating func raccoonScale(x sx: CGFloat, y sy: CGFloat = 1, around c: CGPoint) {
        guard sx != 1 || sy != 1 else { return }
        translateBy(x: c.x, y: c.y)
        scaleBy(x: sx, y: sy)
        translateBy(x: -c.x, y: -c.y)
    }

    mutating func raccoonTranslate(_ v: CGVector) {
        translateBy(x: v.dx, y: v.dy)
    }
}
