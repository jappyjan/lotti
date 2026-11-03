import SwiftUI

/// Head orientation in degrees. See `RaccoonAnchors` for the sign conventions.
///
/// Pitch and yaw are faked in 2D: each face feature is shifted by `featureOffset(depth:)`
/// (eyes depth 1, nose 1.15, ears negative = they move the other way), the head is squashed a
/// little horizontally for yaw, and the forehead (looking up) or chin (looking down) of the
/// silhouette is compressed. Roll is a real rotation about `RaccoonAnchors.headPivot`.
struct RaccoonHeadPose: Equatable, Sendable {
    var pitch: Double = 0
    var roll: Double = 0
    var yaw: Double = 0

    static let neutral = RaccoonHeadPose()

    /// Units a depth-1 feature moves per normalised unit of yaw / pitch.
    static let yawShift: CGFloat = 14
    static let pitchShift: CGFloat = 10

    /// Yaw normalised so ±20° ≈ ±1, with a soft limit.
    var yawAmount: CGFloat { Self.soften(yaw / 20) }
    /// Pitch normalised so ±15° ≈ ±1 (positive = looking up), with a soft limit.
    var pitchAmount: CGFloat { Self.soften(pitch / 15) }

    /// Horizontal squash of the whole head for yaw (1 = none).
    var squash: CGFloat { 1 - 0.035 * abs(yawAmount) }

    /// Fraction the forehead (looking up) or chin (looking down) of the silhouette compresses
    /// towards eye height.
    var foreheadCompression: CGFloat { 0.05 * max(pitchAmount, 0) }
    var chinCompression: CGFloat { 0.05 * max(-pitchAmount, 0) }

    /// Applies the forehead/chin compression to a point of the head silhouette.
    func warpSilhouette(_ p: CGPoint) -> CGPoint {
        let c = RaccoonAnchors.eyeLeft.y
        let k = p.y < c ? foreheadCompression : chinCompression
        return CGPoint(x: p.x, y: c + (p.y - c) * (1 - k))
    }

    /// Parallax offset of a face feature at the given depth (1 = eyes).
    func featureOffset(depth: CGFloat) -> CGVector {
        CGVector(dx: yawAmount * Self.yawShift * depth, dy: -pitchAmount * Self.pitchShift * depth)
    }

    /// Maps a point drawn on a neutral head (at the given feature depth) to where it ends up
    /// with this pose, including squash and roll.
    func project(_ point: CGPoint, depth: CGFloat) -> CGPoint {
        let off = featureOffset(depth: depth)
        let shifted = CGPoint(x: point.x + off.dx, y: point.y + off.dy)
        let c = RaccoonAnchors.headCenter
        let squashed = CGPoint(x: c.x + (shifted.x - c.x) * squash, y: shifted.y)
        return RaccoonGeometry.rotate(squashed, degrees: roll, around: RaccoonAnchors.headPivot)
    }

    private static func soften(_ value: Double) -> CGFloat {
        // Linear up to ±1, then eases towards ±1.5.
        let v = CGFloat(value)
        guard abs(v) > 1 else { return v }
        let excess = abs(v) - 1
        return (1 + 0.5 * (1 - exp(-2 * excess))) * (v < 0 ? -1 : 1)
    }
}

/// Where and how the glasses layer is drawn. The glasses are designed centred on
/// `RaccoonAnchors.glassesOnPosition`; the placement maps that design onto the canvas:
/// translate to `center`, rotate by `rotation`, scale by (`scale` × `squash`, `scale`).
/// Rim and temple weights stay constant whatever the scale.
struct RaccoonGlassesPlacement: Equatable, Sendable {
    var center: CGPoint = RaccoonAnchors.glassesOnPosition
    /// Degrees, clockwise.
    var rotation: Double = 0
    var scale: CGFloat = 1
    /// Extra horizontal scale (yaw on the face).
    var squash: CGFloat = 1
    /// 0 = temples open (worn), 1 = folded behind the lenses (taken off). In between they
    /// swing round the hinge (foreshortened to nothing at 0.5).
    var templeFold: CGFloat = 0
    /// Head turn while worn, −1…1 (normalised yaw): narrows the far lens.
    var turn: CGFloat = 0
    /// Length of each open temple from its hinge to where it tucks under the head outline,
    /// in design units. 0 hides it (the far temple when the head is turned).
    var templeReachLeft: CGFloat = RaccoonPosing.neutralTempleReach.left
    var templeReachRight: CGFloat = RaccoonPosing.neutralTempleReach.right

    static let worn = RaccoonGlassesPlacement()

    /// Maps a point in the glasses' design space to the canvas.
    func apply(_ point: CGPoint) -> CGPoint {
        let o = RaccoonAnchors.glassesOnPosition
        let local = CGPoint(x: (point.x - o.x) * scale * squash, y: (point.y - o.y) * scale)
        let r = RaccoonGeometry.rotate(local, degrees: rotation, around: .zero)
        return CGPoint(x: center.x + r.x, y: center.y + r.y)
    }
}

/// Paw positions (unit space) and finger directions (degrees, 0 = +x, clockwise).
struct RaccoonPawPose: Equatable, Sendable {
    var left: CGPoint = RaccoonAnchors.pawRestLeft
    var right: CGPoint = RaccoonAnchors.pawRestRight
    var leftAngle: Double = 0
    var rightAngle: Double = 0
}

/// Pure pose math shared by `RaccoonView` and anyone composing the layers by hand.
/// Everything is a function of (glassesProgress, head pose); no state, no animation.
enum RaccoonPosing {
    /// Portion of `glassesProgress` spent moving the glasses; the rest is the paws letting go.
    static let glassesTravelEnd: Double = 0.8
    /// Feature depth the worn glasses follow (just in front of the eyes).
    static let glassesDepth: CGFloat = 1.05

    /// Glasses placement for a progress (0 = held in the paws, 1 = worn) and head pose.
    /// The glasses travel along a gentle arc, tilt a little extra mid-flight, come slightly
    /// "towards the camera" (scale bump), unfold their temples near the face and follow the
    /// head once worn.
    static func glasses(progress: Double, head: RaccoonHeadPose) -> RaccoonGlassesPlacement {
        let g = CGFloat(smoothstep(0, glassesTravelEnd, clamp01(progress)))
        let on = head.project(RaccoonAnchors.glassesOnPosition, depth: glassesDepth)
        let off = RaccoonAnchors.glassesOffPosition
        let control = CGPoint(x: (on.x + off.x) / 2 + 46, y: (on.y + off.y) / 2 + 6)
        let bump = sin(.pi * g)
        let reach = templeReach(head: head)
        return RaccoonGlassesPlacement(
            center: RaccoonGeometry.quadBezier(off, control, on, g),
            rotation: lerp(RaccoonAnchors.glassesOffRotation, head.roll, Double(g)) + 14 * Double(bump),
            scale: lerp(RaccoonAnchors.glassesOffScale, 1, g) + 0.06 * bump,
            squash: lerp(RaccoonAnchors.glassesOffSquash, head.squash, g),
            templeFold: 1 - CGFloat(smoothstep(0.5, 0.95, Double(g))),
            turn: head.yawAmount * g,
            templeReachLeft: reach.left,
            templeReachRight: reach.right
        )
    }

    /// Glasses placement for the head-only avatar, where the paws are out of frame: the glasses
    /// stay at eye level and settle from slightly larger (1.15) to 1. Pair with
    /// `avatarGlassesOpacity`, so no in-between frame covers the mouth.
    static func avatarGlasses(progress: Double, head: RaccoonHeadPose) -> RaccoonGlassesPlacement {
        let g = CGFloat(smoothstep(0, 1, clamp01(progress)))
        var placement = glasses(progress: 1, head: head)
        placement.scale = lerp(1.15, 1, g)
        return placement
    }

    /// Opacity of the glasses in the head-only avatar (they fade in as they settle).
    static func avatarGlassesOpacity(progress: Double) -> Double {
        smoothstep(0, 0.7, clamp01(progress))
    }

    /// Paws: gripping the glasses' outer rims while they travel, then letting go and dropping
    /// back to the tummy over the last part of the progress.
    static func pawPose(progress: Double, head: RaccoonHeadPose) -> RaccoonPawPose {
        let t = clamp01(progress)
        let placement = glasses(progress: t, head: head)
        let holdLeft = placement.apply(RaccoonAnchors.glassesGripLeft)
        let holdRight = placement.apply(RaccoonAnchors.glassesGripRight)
        let release = CGFloat(smoothstep(glassesTravelEnd - 0.02, 1, t))
        let left = RaccoonGeometry.lerp(holdLeft, RaccoonAnchors.pawRestLeft, release)
        let right = RaccoonGeometry.lerp(holdRight, RaccoonAnchors.pawRestRight, release)

        // Fingers point at the glasses while holding, along the forearm at rest.
        let gripLeft = angle(from: holdLeft, to: placement.center)
        let gripRight = angle(from: holdRight, to: placement.center)
        let restLeft = angle(from: RaccoonBodyArt.elbow(shoulder: RaccoonAnchors.shoulderLeft, paw: left, side: -1), to: left)
        let restRight = angle(from: RaccoonBodyArt.elbow(shoulder: RaccoonAnchors.shoulderRight, paw: right, side: 1), to: right)
        return RaccoonPawPose(
            left: left,
            right: right,
            leftAngle: lerpAngle(gripLeft, restLeft, Double(release)),
            rightAngle: lerpAngle(gripRight, restRight, Double(release))
        )
    }

    /// Paw positions only (see `pawPose`).
    static func paws(progress: Double, head: RaccoonHeadPose) -> (left: CGPoint, right: CGPoint) {
        let pose = pawPose(progress: progress, head: head)
        return (pose.left, pose.right)
    }

    /// Open temple lengths for a head pose: from each hinge to just inside the head outline,
    /// rising a little towards the ear base. The far temple shrinks away as the head turns.
    static func templeReach(head: RaccoonHeadPose) -> (left: CGFloat, right: CGFloat) {
        let off = head.featureOffset(depth: glassesDepth)
        let hingeL = RaccoonAnchors.glassesHingeLeft, hingeR = RaccoonAnchors.glassesHingeRight
        let tipY = hingeR.y + off.dy - RaccoonGlassesArt.templeRise
        let inset: CGFloat = 4
        let edgeR = RaccoonHeadArt.silhouetteEdgeX(side: 1, y: tipY, pose: head) - inset
        let edgeL = RaccoonHeadArt.silhouetteEdgeX(side: -1, y: tipY, pose: head) + inset
        let right = max(0, edgeR - (hingeR.x + off.dx))
        let left = max(0, (hingeL.x + off.dx) - edgeL)
        let turn = head.yawAmount
        return (left * max(0, 1 - max(-turn, 0)), right * max(0, 1 - max(turn, 0)))
    }

    static let neutralTempleReach = templeReach(head: .neutral)

    static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// Hermite smoothstep from `a` to `b` (works for a > b too).
    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    static func angle(from a: CGPoint, to b: CGPoint) -> Double {
        Double(atan2(b.y - a.y, b.x - a.x)) * 180 / .pi
    }

    /// Interpolates angles in degrees along the shorter arc.
    static func lerpAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + remainder(b - a, 360) * t
    }
}
