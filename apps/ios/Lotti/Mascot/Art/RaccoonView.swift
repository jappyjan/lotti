import SwiftUI

/// Lotti, full body: the layers composed as a pure function of the parameters.
///
/// - glassesProgress: 0 = glasses off, held face-on in both paws in front of the tummy;
///   1 = worn (paws back on the tummy). In between, the paws lift the glasses along an arc to
///   the face, the temples swing open (0…0.8), then the paws let go (0.8…1).
/// - headPitch / headRoll / headYaw: degrees, see `RaccoonAnchors` for conventions.
/// - compact: nil = automatic (simplified below ~140 pt).
///
/// The view has no animation of its own. It is `Animatable`, so changing the parameters inside
/// `withAnimation` interpolates them and redraws every frame.
struct RaccoonView: View, Animatable {
    var glassesProgress: Double
    var headPitch: Double
    var headRoll: Double
    var headYaw: Double
    var compact: Bool?

    init(glassesProgress: Double = 1, headPitch: Double = 0, headRoll: Double = 0, headYaw: Double = 0, compact: Bool? = nil) {
        self.glassesProgress = glassesProgress
        self.headPitch = headPitch
        self.headRoll = headRoll
        self.headYaw = headYaw
        self.compact = compact
    }

    nonisolated var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(glassesProgress, headPitch), AnimatablePair(headRoll, headYaw)) }
        set {
            glassesProgress = newValue.first.first
            headPitch = newValue.first.second
            headRoll = newValue.second.first
            headYaw = newValue.second.second
        }
    }

    var body: some View {
        let pose = RaccoonHeadPose(pitch: headPitch, roll: headRoll, yaw: headYaw)
        let placement = RaccoonPosing.glasses(progress: glassesProgress, head: pose)
        let paws = RaccoonPosing.pawPose(progress: glassesProgress, head: pose)
        let viewport = RaccoonAnchors.fullBodyViewport
        ZStack {
            RaccoonBody(compact: compact, viewport: viewport)
            RaccoonArms(left: paws.left, right: paws.right, part: .upper, compact: compact, viewport: viewport)
            RaccoonHead(pose: pose, compact: compact, viewport: viewport)
            RaccoonArms(left: paws.left, right: paws.right, part: .fore, compact: compact, viewport: viewport)
            RaccoonGlasses(placement: placement, compact: compact, viewport: viewport)
            RaccoonPaws(left: paws.left, right: paws.right, leftAngle: paws.leftAngle, rightAngle: paws.rightAngle,
                        compact: compact, viewport: viewport)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Lotti the raccoon")
    }
}

/// Lotti, head only (head + glasses), framed for avatars such as a 28–36 pt chat header.
/// Same parameters as `RaccoonView`. The paws are out of frame here, so the glasses stay at eye
/// level, settling from slightly larger while fading in (`RaccoonPosing.avatarGlasses`); at 0
/// they are hidden. Roll rotates about the avatar centre so the head stays in frame.
struct RaccoonAvatar: View, Animatable {
    var glassesProgress: Double
    var headPitch: Double
    var headRoll: Double
    var headYaw: Double
    var compact: Bool?

    /// Below this rendered side (points) the avatar switches to compact detail.
    static let compactThreshold: CGFloat = 80

    init(glassesProgress: Double = 1, headPitch: Double = 0, headRoll: Double = 0, headYaw: Double = 0, compact: Bool? = nil) {
        self.glassesProgress = glassesProgress
        self.headPitch = headPitch
        self.headRoll = headRoll
        self.headYaw = headYaw
        self.compact = compact
    }

    nonisolated var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(glassesProgress, headPitch), AnimatablePair(headRoll, headYaw)) }
        set {
            glassesProgress = newValue.first.first
            headPitch = newValue.first.second
            headRoll = newValue.second.first
            headYaw = newValue.second.second
        }
    }

    var body: some View {
        // Roll is applied to the framed result so the head pivots about the avatar centre.
        let pose = RaccoonHeadPose(pitch: headPitch, roll: 0, yaw: headYaw)
        let placement = RaccoonPosing.avatarGlasses(progress: glassesProgress, head: pose)
        let glassesOpacity = RaccoonPosing.avatarGlassesOpacity(progress: glassesProgress)
        let viewport = RaccoonAnchors.avatarViewport
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let isCompact = compact ?? (side < Self.compactThreshold)
            ZStack {
                RaccoonHead(pose: pose, compact: isCompact, chinShadow: false, viewport: viewport)
                RaccoonGlasses(placement: placement, compact: isCompact, viewport: viewport)
                    .opacity(glassesOpacity)
            }
            .rotationEffect(.degrees(headRoll))
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .accessibilityElement()
        .accessibilityLabel("Lotti the raccoon")
    }
}
