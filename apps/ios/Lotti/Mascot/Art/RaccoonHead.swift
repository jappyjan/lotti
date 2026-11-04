import SwiftUI

private func rp(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// Layer 3: chin shadow on the chest, ears, face, mask, eyes, nose, mouth (no glasses), on the
/// shared 400-unit canvas. Pitch/yaw are faked (features shift by depth, ears the other way,
/// forehead/chin compress, the chin shadow changes); roll rotates about `RaccoonAnchors.headPivot`.
struct RaccoonHead: View {
    var pose: RaccoonHeadPose = .neutral
    var compact: Bool? = nil
    /// Soft shadow the head casts on the chest (clipped to the body). Off for head-only framings.
    var chinShadow: Bool = true
    var viewport: CGRect = RaccoonAnchors.canvasRect

    var body: some View {
        let pose = self.pose, chinShadow = self.chinShadow
        RaccoonCanvas(compact: compact, viewport: viewport) { ctx, env in
            RaccoonHeadArt.draw(in: &ctx, pose: pose, chinShadow: chinShadow, env: env)
        }
    }
}

enum RaccoonHeadArt {
    // Feature depths for the fake 3D (1 = eyes). Ears sit behind the face, so they move the other way.
    static let earDepth: CGFloat = -0.5
    static let skullDepth: CGFloat = 0.15
    static let browDepth: CGFloat = 0.85
    static let maskDepth: CGFloat = 0.95
    static let eyeDepth: CGFloat = 1
    static let cheekDepth: CGFloat = 0.7
    static let muzzleDepth: CGFloat = 1.2
    /// Kept close to the glasses' depth so the nose never slides under the rims when pitching.
    static let noseDepth: CGFloat = 1.15

    static func draw(in context: inout GraphicsContext, pose: RaccoonHeadPose, chinShadow: Bool, env: RaccoonDrawEnv) {
        let pal = env.palette

        // Chin shadow on the chest: rolls with the head, deepens looking down, thins looking up.
        if chinShadow {
            var shadow = context
            shadow.clip(to: RaccoonBodyArt.bodyShape())
            shadow.raccoonRotate(degrees: pose.roll, around: RaccoonAnchors.headPivot)
            let a = pose.pitchAmount
            let ry = 24 * (1 - 0.42 * a)
            let cy = 254 - 2 * a
            shadow.raccoonFill(Path.raccoonEllipse(rp(200 + pose.yawAmount * 6, cy), 108, ry), pal.furDark.opacity(0.5))
        }

        var ctx = context
        ctx.raccoonRotate(degrees: pose.roll, around: RaccoonAnchors.headPivot)
        ctx.raccoonScale(x: pose.squash, around: RaccoonAnchors.headCenter)

        // Ears (behind the head): parallax plus the crown dropping as the forehead compresses.
        var ears = ctx
        let earOff = pose.featureOffset(depth: earDepth)
        ears.translateBy(x: earOff.dx, y: earOff.dy + (RaccoonAnchors.eyeLeft.y - 90) * pose.foreheadCompression)
        ears.raccoonFillOutlined(earOuter().raccoonWithMirror(), pal.furDark, pal.outline, env.outline)
        ears.raccoonFill(earRim().raccoonWithMirror(), pal.cream)
        ears.raccoonFill(earInner().raccoonWithMirror(), pal.innerEar)

        // Skull.
        var skull = ctx
        skull.raccoonTranslate(pose.featureOffset(depth: skullDepth))
        let head = headShape(pose: pose)
        skull.raccoonFill(head, pal.fur)

        // Markings, clipped to the head so parallax never spills over the outline.
        var face = skull
        face.clip(to: head)
        layer(face, pose, depth: 0.5) { $0.raccoonFill(foreheadStripe(), pal.furDark) }
        layer(face, pose, depth: cheekDepth - skullDepth) { $0.raccoonFill(lowerFace(), pal.cream) }
        layer(face, pose, depth: browDepth - skullDepth) { $0.raccoonFill(brows(), pal.cream) }
        layer(face, pose, depth: maskDepth - skullDepth) { $0.raccoonFill(mask(), pal.mask) }
        layer(face, pose, depth: cheekDepth - skullDepth) {
            $0.raccoonFill(Path.raccoonEllipse(rp(136, 226), 16, 9).raccoonWithMirror(), pal.blush)
        }
        skull.raccoonStroke(head, pal.outline, env.outline)

        // Eyes.
        let yaw = pose.yawAmount
        let look = CGVector(dx: yaw * 3.5, dy: -pose.pitchAmount * 3)
        var eyes = ctx
        eyes.raccoonTranslate(pose.featureOffset(depth: eyeDepth))
        drawEye(eyes, at: RaccoonAnchors.eyeLeft, squash: 1 - 0.12 * max(-yaw, 0), look: look, env: env)
        drawEye(eyes, at: RaccoonAnchors.eyeRight, squash: 1 - 0.12 * max(yaw, 0), look: look, env: env)

        // Muzzle: whiskers, snaggle tooth, mouth.
        var muzzle = ctx
        muzzle.raccoonTranslate(pose.featureOffset(depth: muzzleDepth))
        if !env.compact {
            muzzle.raccoonStroke(whiskers(), pal.line.opacity(0.35), 2.2)
        }
        muzzle.raccoonFillOutlined(tooth(compact: env.compact), pal.eyeWhite, pal.line, env.compact ? 4 : 2.5)
        muzzle.raccoonStroke(mouth(compact: env.compact), pal.line, env.detail)

        // Nose.
        var nose = ctx
        nose.raccoonTranslate(pose.featureOffset(depth: noseDepth))
        nose.raccoonFill(noseShape(compact: env.compact), pal.nose)
        nose.raccoonFill(Path.raccoonEllipse(rp(194, 197), env.compact ? 5 : 5.5, env.compact ? 3 : 2.8), pal.shine.opacity(0.55))
    }

    /// Runs `body` on a copy of `ctx` shifted by an additional parallax depth.
    private static func layer(_ ctx: GraphicsContext, _ pose: RaccoonHeadPose, depth: CGFloat, _ body: (GraphicsContext) -> Void) {
        var c = ctx
        c.raccoonTranslate(pose.featureOffset(depth: depth))
        body(c)
    }

    // MARK: Eyes

    static func drawEye(_ ctx: GraphicsContext, at c: CGPoint, squash: CGFloat, look: CGVector, env: RaccoonDrawEnv) {
        let pal = env.palette
        var e = ctx
        e.raccoonScale(x: squash, around: c)
        let r: CGFloat = env.compact ? 25 : 23
        e.raccoonFill(Path.raccoonEllipse(c, r * 0.97, r * 1.03), pal.eyeWhite)
        let pupilR: CGFloat = env.compact ? 19 : 17
        let pc = rp(c.x + look.dx, c.y + 1.5 + look.dy)
        e.raccoonFill(Path.raccoonCircle(pc, pupilR), pal.pupil)
        e.raccoonFill(Path.raccoonCircle(rp(pc.x - 6, pc.y - 7), env.compact ? 7.5 : 6.5), pal.shine)
        if !env.compact {
            e.raccoonFill(Path.raccoonCircle(rp(pc.x + 6.5, pc.y + 6), 2.8), pal.shine.opacity(0.9))
        }
    }

    // MARK: Head silhouette

    static let headStart = rp(200, 58)
    /// Right half of the head outline, top centre → chin, as cubic segments.
    static let headSegments: [RaccoonSegment] = [
        (rp(246, 58), rp(296, 74), rp(312, 118)),
        (rp(320, 140), rp(324, 164), rp(342, 190)),   // cheek tuft 1
        (rp(332, 195), rp(324, 197), rp(316, 199)),
        (rp(324, 209), rp(330, 219), rp(334, 230)),   // cheek tuft 2
        (rp(320, 234), rp(308, 234), rp(298, 236)),
        (rp(278, 256), rp(240, 264), rp(200, 264)),   // chin
    ]

    static func headShape(pose: RaccoonHeadPose = .neutral) -> Path {
        let w = pose.warpSilhouette
        return Path.raccoonSymmetric(start: w(headStart), headSegments.map { (w($0.c1), w($0.c2), w($0.to)) })
    }

    /// x of the head outline on one side (`side` −1 left, 1 right) at height `y`, in head space
    /// (before squash and roll), for the upper half of the head (crown to first cheek tuft).
    static func silhouetteEdgeX(side: CGFloat, y: CGFloat, pose: RaccoonHeadPose) -> CGFloat {
        let skull = pose.featureOffset(depth: skullDepth)
        let target = y - skull.dy
        var previous = pose.warpSilhouette(headStart)
        var start = headStart
        for segment in headSegments.prefix(2) {
            for i in 1...24 {
                let t = CGFloat(i) / 24
                let p = pose.warpSilhouette(RaccoonGeometry.cubic(start, segment.c1, segment.c2, segment.to, t))
                if p.y >= target && previous.y < target {
                    let k = (target - previous.y) / max(p.y - previous.y, 0.001)
                    let x = previous.x + (p.x - previous.x) * k
                    return 200 + side * (x - 200) + skull.dx
                }
                previous = p
            }
            start = segment.to
        }
        return 200 + side * (previous.x - 200) + skull.dx
    }

    // MARK: Shapes (right half / right side, mirrored where symmetric)

    static func earOuter() -> Path {
        Path.raccoonCurves(start: rp(232, 96), [
            (rp(228, 54), rp(262, 24), rp(298, 25)),
            (rp(334, 26), rp(352, 62), rp(334, 128)),
            (rp(302, 114), rp(266, 102), rp(232, 96)),
        ])
    }

    /// Cream rim inside the ear.
    static func earRim() -> Path {
        Path.raccoonCurves(start: rp(246, 96), [
            (rp(244, 62), rp(268, 40), rp(297, 40)),
            (rp(324, 41), rp(338, 68), rp(326, 118)),
            (rp(300, 108), rp(270, 100), rp(246, 96)),
        ])
    }

    /// Pink inner ear.
    static func earInner() -> Path {
        Path.raccoonCurves(start: rp(258, 98), [
            (rp(258, 72), rp(276, 55), rp(297, 55)),
            (rp(315, 56), rp(324, 78), rp(316, 110)),
            (rp(298, 104), rp(276, 100), rp(258, 98)),
        ])
    }

    static func foreheadStripe() -> Path {
        Path.raccoonSymmetric(start: rp(200, 60), [
            (rp(207, 86), rp(213, 116), rp(212, 152)),
            (rp(210, 154), rp(205, 155), rp(200, 155)),
        ])
    }

    static func brows() -> Path {
        // Left brow arched high, right brow slanting down towards the nose: a raised eyebrow
        // and a scheming one — the mischievous half of Lotti.
        let right = Path.raccoonCurves(start: rp(214, 134), [
            (rp(230, 110), rp(276, 98), rp(306, 114)),
            (rp(280, 110), rp(240, 118), rp(214, 134)),
        ])
        let left = Path.raccoonCurves(start: rp(188, 122), [
            (rp(178, 86), rp(126, 76), rp(94, 104)),
            (rp(126, 94), rp(164, 100), rp(188, 122)),
        ])
        var p = right
        p.addPath(left)
        return p
    }

    static func lowerFace() -> Path {
        Path.raccoonSymmetric(start: rp(200, 168), [
            (rp(232, 168), rp(270, 178), rp(304, 194)),
            (rp(318, 206), rp(310, 228), rp(292, 236)),
            (rp(270, 254), rp(236, 262), rp(200, 262)),
        ])
    }

    /// The bandit mask: a ring around each lens, drooping below the rims towards the cheeks.
    static func mask() -> Path {
        Path.raccoonSymmetric(start: rp(200, 146), [
            (rp(214, 131), rp(234, 122), rp(256, 122)),
            (rp(285, 122), rp(309, 139), rp(321, 162)),
            (rp(329, 179), rp(331, 199), rp(325, 218)),   // mask tail
            (rp(311, 212), rp(297, 207), rp(281, 207)),
            (rp(263, 207), rp(251, 211), rp(236, 209)),
            (rp(221, 206), rp(211, 188), rp(200, 186)),
        ])
    }

    static func noseShape(compact: Bool) -> Path {
        let w: CGFloat = compact ? 17 : 14
        return Path.raccoonSymmetric(start: rp(200, 192), [
            (rp(200 + w * 0.7, 192), rp(200 + w, 194), rp(200 + w, 200)),
            (rp(200 + w, 207), rp(207, 214), rp(200, 214)),
        ])
    }

    static func mouth(compact: Bool) -> Path {
        var p = Path()
        p.move(to: rp(200, 212))
        p.addLine(to: rp(200, 219))
        // Left: a soft curl.
        p.move(to: rp(200, 219))
        p.addCurve(to: rp(178, 221), control1: rp(196, 227), control2: rp(185, 229))
        // Right: hitched up higher — the smirk.
        p.move(to: rp(200, 219))
        p.addCurve(to: rp(228, 211), control1: rp(206, 229), control2: rp(222, 227))
        if !compact {
            p.addCurve(to: rp(230, 205), control1: rp(230, 209), control2: rp(231, 207))
        }
        return p
    }

    /// A little snaggle tooth under the smirk.
    static func tooth(compact: Bool) -> Path {
        let w: CGFloat = compact ? 10 : 8, h: CGFloat = compact ? 10 : 9
        let x: CGFloat = 211, y: CGFloat = 225
        var p = Path()
        p.move(to: rp(x - w / 2, y + 0.5))
        p.addLine(to: rp(x + w / 2, y - 0.5))
        p.addQuadCurve(to: rp(x + 0.5, y + h), control: rp(x + w / 2, y + h))
        p.addQuadCurve(to: rp(x - w / 2, y + 0.5), control: rp(x - w / 2 + 0.5, y + h * 0.6))
        p.closeSubpath()
        return p
    }

    static func whiskers() -> Path {
        var p = Path()
        p.move(to: rp(236, 210)); p.addQuadCurve(to: rp(292, 204), control: rp(264, 204))
        p.move(to: rp(236, 217)); p.addQuadCurve(to: rp(290, 221), control: rp(264, 216))
        return p.raccoonWithMirror()
    }
}
