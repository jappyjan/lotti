import SwiftUI

private func rp(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// Layer 1: chubby sitting body, cream tummy, feet and the ringed tail. Static.
struct RaccoonBody: View {
    var compact: Bool? = nil
    var viewport: CGRect = RaccoonAnchors.canvasRect

    var body: some View {
        RaccoonCanvas(compact: compact, viewport: viewport) { ctx, env in
            RaccoonBodyArt.draw(in: &ctx, env: env)
        }
    }
}

/// Layers 2 and 4: both arms, from the shoulders to the given paw positions (unit space).
/// Each arm is an upper arm (shoulder → elbow, meant to sit under the head) and a tapered
/// forearm (elbow → paw, meant to sit in front of chest and chin); `part` picks which to draw.
/// The elbow is derived from shoulder and paw (`RaccoonBodyArt.elbow`).
struct RaccoonArms: View {
    enum Part: Sendable { case upper, fore, whole }

    var left: CGPoint = RaccoonAnchors.pawRestLeft
    var right: CGPoint = RaccoonAnchors.pawRestRight
    var part: Part = .whole
    var compact: Bool? = nil
    var viewport: CGRect = RaccoonAnchors.canvasRect

    var body: some View {
        let left = self.left, right = self.right, part = self.part
        RaccoonCanvas(compact: compact, viewport: viewport) { ctx, env in
            RaccoonBodyArt.drawArm(in: ctx, shoulder: RaccoonAnchors.shoulderLeft, paw: left, side: -1, part: part, env: env)
            RaccoonBodyArt.drawArm(in: ctx, shoulder: RaccoonAnchors.shoulderRight, paw: right, side: 1, part: part, env: env)
        }
    }
}

/// Layer 6: the two front paws at the given positions (unit space). Fingers point along
/// `leftAngle` / `rightAngle` (degrees, 0 = +x, clockwise); nil = along the forearm.
struct RaccoonPaws: View {
    var left: CGPoint = RaccoonAnchors.pawRestLeft
    var right: CGPoint = RaccoonAnchors.pawRestRight
    var leftAngle: Double? = nil
    var rightAngle: Double? = nil
    var compact: Bool? = nil
    var viewport: CGRect = RaccoonAnchors.canvasRect

    var body: some View {
        let left = self.left, right = self.right
        let leftAngle = self.leftAngle ?? RaccoonPosing.angle(
            from: RaccoonBodyArt.elbow(shoulder: RaccoonAnchors.shoulderLeft, paw: left, side: -1), to: left)
        let rightAngle = self.rightAngle ?? RaccoonPosing.angle(
            from: RaccoonBodyArt.elbow(shoulder: RaccoonAnchors.shoulderRight, paw: right, side: 1), to: right)
        RaccoonCanvas(compact: compact, viewport: viewport) { ctx, env in
            RaccoonBodyArt.drawPaw(in: ctx, at: left, angle: leftAngle, env: env)
            RaccoonBodyArt.drawPaw(in: ctx, at: right, angle: rightAngle, env: env)
        }
    }
}

enum RaccoonBodyArt {
    static func draw(in context: inout GraphicsContext, env: RaccoonDrawEnv) {
        let pal = env.palette
        let ctx = context

        drawTail(ctx, env: env)

        let body = bodyShape()
        ctx.raccoonFill(body, pal.fur)
        var tummy = ctx
        tummy.clip(to: body)
        tummy.raccoonFill(Path.raccoonEllipse(rp(200, 316), 64, 54), pal.cream)
        ctx.raccoonStroke(body, pal.outline, env.outline)

        // Feet.
        let feet = Path.raccoonEllipse(rp(153, 364), 31, 15).raccoonWithMirror()
        ctx.raccoonFillOutlined(feet, pal.paw, pal.outline, env.outline)
        if !env.compact {
            var toes = Path()
            for x: CGFloat in [144, 162] {
                toes.move(to: rp(x, 353)); toes.addLine(to: rp(x, 360))
            }
            ctx.raccoonStroke(toes.raccoonWithMirror(), pal.fur.opacity(0.55), 3)
        }
    }

    static func bodyShape() -> Path {
        Path.raccoonSymmetric(start: rp(200, 208), [
            (rp(262, 208), rp(304, 250), rp(306, 302)),
            (rp(308, 348), rp(274, 372), rp(200, 372)),
        ])
    }

    // MARK: Tail

    /// Centre line of the tail: from behind the body, sweeping right and curling up.
    static let tailCurve = (rp(232, 348), rp(318, 382), rp(368, 316), rp(338, 232))

    static func tailHalfWidth(_ s: CGFloat) -> CGFloat {
        let grow = 14 + 18 * CGFloat(RaccoonPosing.smoothstep(0, 0.5, Double(s)))
        let tipStart: CGFloat = 0.78
        guard s > tipStart else { return grow }
        let k = (s - tipStart) / (1 - tipStart)
        return grow * sqrt(max(0, 1 - k * k))
    }

    static func tailPoint(_ s: CGFloat) -> (center: CGPoint, normal: CGVector) {
        let (p0, p1, p2, p3) = tailCurve
        let c = RaccoonGeometry.cubic(p0, p1, p2, p3, s)
        let t = RaccoonGeometry.cubicTangent(p0, p1, p2, p3, s)
        return (c, CGVector(dx: -t.dy, dy: t.dx))
    }

    static func tailPath() -> Path {
        let n = 72
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for i in 0...n {
            // Denser sampling near the rounded tip.
            let u = CGFloat(i) / CGFloat(n)
            let s = 1 - pow(1 - u, 1.4)
            let (c, nrm) = tailPoint(s)
            let h = tailHalfWidth(s)
            left.append(rp(c.x + nrm.dx * h, c.y + nrm.dy * h))
            right.append(rp(c.x - nrm.dx * h, c.y - nrm.dy * h))
        }
        var path = Path()
        path.addLines(left)
        for p in right.reversed() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    /// A ring band between s0 and s1 whose edges bow towards the tip (wrapping round the tail).
    static func ringBand(_ s0: CGFloat, _ s1: CGFloat) -> Path {
        func edge(_ s: CGFloat) -> (CGPoint, CGPoint, CGPoint) {
            let (c, nrm) = tailPoint(s)
            let tangent = CGVector(dx: nrm.dy, dy: -nrm.dx)
            let h = tailHalfWidth(s) * 1.6
            let a = rp(c.x + nrm.dx * h, c.y + nrm.dy * h)
            let b = rp(c.x - nrm.dx * h, c.y - nrm.dy * h)
            let bow = rp(c.x + tangent.dx * 9, c.y + tangent.dy * 9)
            return (a, bow, b)
        }
        let (a0, m0, b0) = edge(s0)
        let (a1, m1, b1) = edge(s1)
        var p = Path()
        p.move(to: a0)
        p.addQuadCurve(to: b0, control: m0)
        p.addLine(to: b1)
        p.addQuadCurve(to: a1, control: m1)
        p.closeSubpath()
        return p
    }

    static func drawTail(_ context: GraphicsContext, env: RaccoonDrawEnv) {
        let pal = env.palette
        let tail = tailPath()
        context.raccoonFill(tail, pal.fur)
        var rings = context
        rings.clip(to: tail)
        let bands: [(CGFloat, CGFloat)] = [(0.30, 0.39), (0.49, 0.58), (0.67, 0.76), (0.86, 1.2)]
        for (a, b) in bands {
            rings.raccoonFill(ringBand(a, b), pal.ring)
        }
        context.raccoonStroke(tail, pal.outline, env.outline)
    }

    // MARK: Arms and paws

    /// Elbow for a shoulder and paw (`side` −1 = left, 1 = right). Resting: halfway along the
    /// arm, bowed outwards. With the paw raised towards the face the elbow tucks out and down at
    /// the side of the body, so the forearm rises in front of the chest and cheek.
    static func elbow(shoulder s: CGPoint, paw p: CGPoint, side: CGFloat) -> CGPoint {
        let raise = CGFloat(RaccoonPosing.smoothstep(Double(s.y + 30), Double(s.y - 50), Double(p.y)))
        let dx = p.x - s.x, dy = p.y - s.y
        let len = max(sqrt(dx * dx + dy * dy), 1)
        var nx = -dy / len, ny = dx / len
        if nx * side < 0 { nx = -nx; ny = -ny }
        let bow = min(10, len * 0.15)
        let mid = RaccoonGeometry.lerp(s, p, 0.45)
        let rest = rp(mid.x + nx * bow, mid.y + ny * bow)
        let raised = rp(s.x + side * 22, s.y + 26)
        return RaccoonGeometry.lerp(rest, raised, raise)
    }

    static func drawArm(in ctx: GraphicsContext, shoulder s: CGPoint, paw p: CGPoint, side: CGFloat,
                        part: RaccoonArms.Part, env: RaccoonDrawEnv) {
        let e = elbow(shoulder: s, paw: p, side: side)
        if part != .fore {
            drawLimb(ctx, from: s, to: e, startWidth: 38, endWidth: 34, env: env)
        }
        if part != .upper {
            drawLimb(ctx, from: e, to: p, startWidth: 34, endWidth: 26, env: env)
        }
    }

    /// A tapered tube with round ends, outlined as one shape.
    static func drawLimb(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint, startWidth w0: CGFloat, endWidth w1: CGFloat, env: RaccoonDrawEnv) {
        let pal = env.palette
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(sqrt(dx * dx + dy * dy), 0.001)
        let nx = -dy / len, ny = dx / len
        var tube = Path()
        tube.move(to: rp(a.x + nx * w0 / 2, a.y + ny * w0 / 2))
        tube.addLine(to: rp(b.x + nx * w1 / 2, b.y + ny * w1 / 2))
        tube.addLine(to: rp(b.x - nx * w1 / 2, b.y - ny * w1 / 2))
        tube.addLine(to: rp(a.x - nx * w0 / 2, a.y - ny * w0 / 2))
        tube.closeSubpath()
        let parts = [tube, Path.raccoonCircle(a, w0 / 2), Path.raccoonCircle(b, w1 / 2)]
        // Outlines behind the fills give one clean silhouette for the union (filled one by one,
        // so opposite windings can't punch holes).
        for part in parts { ctx.raccoonStroke(part, pal.outline, env.outline * 2) }
        for part in parts { ctx.raccoonFill(part, pal.fur) }
    }

    static func drawPaw(in ctx: GraphicsContext, at p: CGPoint, angle: Double, env: RaccoonDrawEnv) {
        let pal = env.palette
        var c = ctx
        c.translateBy(x: p.x, y: p.y)
        c.rotate(by: .degrees(angle))
        // In paw space +x points towards the fingers.
        var paw = Path.raccoonEllipse(rp(0, 0), 19, 20)
        for y: CGFloat in [-11, 0, 11] {
            paw.addPath(Path.raccoonCircle(rp(15, y), 8))
        }
        c.raccoonStroke(paw, pal.outline, env.outline * 2)
        c.raccoonFill(paw, pal.paw)
        if !env.compact {
            var knuckles = Path()
            for y: CGFloat in [-5.5, 5.5] {
                knuckles.move(to: rp(11, y)); knuckles.addLine(to: rp(18, y))
            }
            c.raccoonStroke(knuckles, pal.fur.opacity(0.5), 2.2)
        }
    }
}
