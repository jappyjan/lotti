import SwiftUI

private func rp(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// Layer 5: Lotti's (smart) glasses — green rims, nearly clear lenses with one highlight streak,
/// temples. Designed centred on `RaccoonAnchors.glassesOnPosition`; `placement` moves them
/// anywhere (worn, held in the paws, or in between). Rim weight is constant at any scale, and the
/// lenses are almost clear so the eyes and the black mask always show through.
struct RaccoonGlasses: View {
    var placement: RaccoonGlassesPlacement = .worn
    var compact: Bool? = nil
    var viewport: CGRect = RaccoonAnchors.canvasRect

    var body: some View {
        let placement = self.placement
        RaccoonCanvas(compact: compact, viewport: viewport) { ctx, env in
            RaccoonGlassesArt.draw(in: &ctx, placement: placement, env: env)
        }
    }
}

enum RaccoonGlassesArt {
    static let lensSize = CGSize(width: 76, height: 66)
    static let lensCorner: CGFloat = 30
    /// How much an open temple rises from hinge to tip (towards the ear base).
    static let templeRise: CGFloat = 7

    static func lensRect(_ eye: CGPoint, widthScale: CGFloat = 1) -> CGRect {
        let w = lensSize.width * widthScale
        return CGRect(x: eye.x - w / 2, y: eye.y - lensSize.height / 2, width: w, height: lensSize.height)
    }

    static func draw(in context: inout GraphicsContext, placement: RaccoonGlassesPlacement, env: RaccoonDrawEnv) {
        let pal = env.palette
        var ctx = context
        let o = RaccoonAnchors.glassesOnPosition
        ctx.translateBy(x: placement.center.x, y: placement.center.y)
        ctx.rotate(by: .degrees(placement.rotation))
        ctx.scaleBy(x: placement.scale * placement.squash, y: placement.scale)
        ctx.translateBy(x: -o.x, y: -o.y)

        // Keep line weights constant on screen whatever the scale.
        let k = 1 / max(placement.scale, 0.4)
        let rim: CGFloat = (env.compact ? 10.5 : 6.8) * k
        let edge: CGFloat = (env.compact ? 2.5 : 2) * k

        // The far lens narrows a little when the head is turned.
        let turn = placement.turn
        let leftRect = lensRect(RaccoonAnchors.eyeLeft, widthScale: 1 - 0.08 * max(-turn, 0))
        let rightRect = lensRect(RaccoonAnchors.eyeRight, widthScale: 1 - 0.08 * max(turn, 0))
        let leftLens = Path(roundedRect: leftRect, cornerRadius: lensCorner, style: .continuous)
        let rightLens = Path(roundedRect: rightRect, cornerRadius: lensCorner, style: .continuous)

        // Temples swing round their hinges: folded = lying inward behind the lens, open = reaching
        // back to the head outline. The projected length is cos(angle) × length.
        let swing = cos(CGFloat.pi * (1 - placement.templeFold))   // 1 folded … −1 open
        var temples = Path()
        for side: CGFloat in [-1, 1] {
            let rect = side < 0 ? leftRect : rightRect
            let hinge = rp(side < 0 ? rect.minX + 3 : rect.maxX - 3, rect.minY + 13)
            if swing > 0 {
                guard !env.compact else { continue }
                let len = swing * (rect.width - 18)
                temples.move(to: hinge)
                temples.addLine(to: rp(hinge.x - side * len, hinge.y + 10 * swing))
            } else {
                let reach = side < 0 ? placement.templeReachLeft : placement.templeReachRight
                let len = -swing * reach
                guard len > 0.5 else { continue }
                temples.move(to: hinge)
                temples.addQuadCurve(to: rp(hinge.x + side * len, hinge.y - templeRise * -swing),
                                     control: rp(hinge.x + side * len * 0.5, hinge.y - templeRise * 0.2))
            }
        }
        let templeWidth = rim * 0.72
        ctx.raccoonStroke(temples, pal.frameEdge, templeWidth + edge * 2)
        ctx.raccoonStroke(temples, pal.frame, templeWidth)

        // Lenses: a whisper of tint, so they read as glass without hiding what's behind.
        ctx.raccoonFill(leftLens, pal.lens)
        ctx.raccoonFill(rightLens, pal.lens)

        // One highlight streak per lens.
        var glints = Path()
        for rect in [leftRect, rightRect] {
            glints.move(to: rp(rect.minX + 14, rect.minY + 35))
            glints.addLine(to: rp(rect.minX + 31, rect.minY + 15))
        }
        ctx.raccoonStroke(glints, pal.glint, (env.compact ? 7 : 5) * k)

        // Rims and bridge: dark edge under a green rim.
        var frame = leftLens
        frame.addPath(rightLens)
        frame.move(to: rp(leftRect.maxX - 1, o.y - 10))
        frame.addQuadCurve(to: rp(rightRect.minX + 1, o.y - 10), control: rp(200, o.y - 21))
        ctx.raccoonStroke(frame, pal.frameEdge, rim + edge * 2)
        ctx.raccoonStroke(frame, pal.frame, rim)

        if !env.compact {
            // Thin highlight along the top of each rim.
            var hi = Path()
            for rect in [leftRect, rightRect] {
                hi.move(to: rp(rect.minX + 17, rect.minY + 0.5))
                hi.addQuadCurve(to: rp(rect.maxX - 17, rect.minY + 0.5), control: rp(rect.midX, rect.minY - 1))
            }
            ctx.raccoonStroke(hi, pal.frameHighlight.opacity(0.9), 2.2 * k)
        }
    }
}
