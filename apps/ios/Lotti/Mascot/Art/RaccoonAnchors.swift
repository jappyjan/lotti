import SwiftUI

// MARK: - Lotti mascot art: layer API
//
// Lotti is a curious, warm, slightly mischievous raccoon who wears (smart) glasses.
// The art is plain SwiftUI `Path` drawing (one `Canvas` per layer), no assets, no animation.
//
// DESIGN CANVAS
//   Every layer draws into the same square 400 × 400 unit space (origin top-left, y down),
//   scaled to fit the view (aspect-fit, centred). All anchors below are in that unit space;
//   convert with `RaccoonAnchors.unitPoint(_:)` for SwiftUI `anchor:` parameters.
//   Each layer takes a `viewport` (the part of the unit space it shows, default the whole
//   canvas). `RaccoonView` uses `fullBodyViewport` (nudged so the tail is balanced) and
//   `RaccoonAvatar` uses `avatarViewport`.
//
// LAYERS (back to front, as `RaccoonView` stacks them; each is a full-canvas view)
//   1. RaccoonBody                  body, belly, feet, ringed tail. Static.
//   2. RaccoonArms(part: .upper)    upper arms (shoulder → elbow), tucked under the head.
//   3. RaccoonHead                  chin shadow on the chest, ears, face, mask, eyes, nose,
//                                   mouth. No glasses. Takes a `RaccoonHeadPose`: pitch/yaw are
//                                   faked inside the layer (features shift by depth, ears move
//                                   the other way, forehead/chin compress, chin shadow grows or
//                                   shrinks); roll rotates the whole head about `headPivot`.
//   4. RaccoonArms(part: .fore)     forearms (elbow → paw), in front of chest and chin, so a
//                                   raised paw is always attached to an arm.
//   5. RaccoonGlasses               frames + nearly clear lenses + temples. Takes a
//                                   `RaccoonGlassesPlacement`. Designed centred on
//                                   `glassesOnPosition`, so the identity placement = worn on a
//                                   neutral head.
//   6. RaccoonPaws                  the two front paws, above the glasses so they can grip the rims.
//
//   `RaccoonView` composes all of them as a pure function of
//   (glassesProgress, headPitch, headRoll, headYaw) and is `Animatable`, so animating those
//   parameters with `withAnimation` interpolates the whole pose frame by frame.
//   `RaccoonAvatar` is the head-only framing (head + glasses) for small avatars.
//   `RaccoonPosing` holds the pure pose math if you compose the layers yourself.
//
// INDEPENDENT TRANSFORMS
//   Head and glasses are separate views. Besides their pose parameters you may also apply your
//   own SwiftUI transforms, e.g. `.rotationEffect(.degrees(r), anchor: RaccoonAnchors.unitPoint(RaccoonAnchors.headPivot))`
//   (with the default full-canvas viewport). Offsets in unit space must be multiplied by
//   (view side / viewport width).
//
// ANGLE CONVENTIONS (degrees)
//   pitch > 0  looks up (face features move up),   pitch < 0 looks down.
//   roll  > 0  tilts the head clockwise on screen (top of head goes to the viewer's right).
//   yaw   > 0  turns toward the viewer's right (features shift right).
//   Designed for ±20° pitch, ±15° roll and ±25° yaw; values beyond are softly limited.
//
// DETAIL LEVEL
//   Every view takes `compact: Bool?` (nil = automatic from the rendered size). Compact drops
//   whiskers, toe lines, folded temples and small highlights, and thickens outlines so the art
//   reads at 28–36 pt.
//
// COLOURS
//   `RaccoonPalette.light` / `.dark`, picked from `@Environment(\.colorScheme)`.

/// Anchor points and fixed dimensions of the raccoon design canvas (400 × 400 units, y down).
enum RaccoonAnchors {
    /// Side of the square design canvas, in units.
    static let canvasSide: CGFloat = 400
    static let canvasRect = CGRect(x: 0, y: 0, width: 400, height: 400)
    /// Framing used by `RaccoonView`: shifted so head + tail sit balanced, and zoomed out 3 % so
    /// the ears keep a margin at ±15° roll.
    static let fullBodyViewport = CGRect(x: 6, y: -10, width: 412, height: 412)

    // Head

    /// Neck/chin point the head rotates about for roll (and the natural anchor for any head
    /// rotation you apply yourself).
    static let headPivot = CGPoint(x: 200, y: 252)
    /// Visual centre of the head (between the eyes, a little above).
    static let headCenter = CGPoint(x: 200, y: 160)
    /// Eye centres on a neutral head.
    static let eyeLeft = CGPoint(x: 155, y: 165)
    static let eyeRight = CGPoint(x: 245, y: 165)
    /// Bounding box of the head including ears on a neutral pose.
    static let headBounds = CGRect(x: 52, y: 22, width: 296, height: 248)
    /// Square crop used by `RaccoonAvatar` (head + glasses only). Leaves ≥ 6 % margin around
    /// ears and cheek tufts at ±15° roll and ±20° pitch.
    static let avatarViewport = CGRect(x: 30, y: -24, width: 340, height: 340)

    // Glasses

    /// Where the glasses' design centre (middle of the bridge line, at eye height) sits when
    /// worn on a neutral head. The glasses layer is drawn around this point.
    static let glassesOnPosition = CGPoint(x: 200, y: 165)
    /// Where the glasses' centre rests when taken off: held face-on in both front paws in front
    /// of the tummy ("the washer" — Procyon lotor cleaning its glasses).
    static let glassesOffPosition = CGPoint(x: 200, y: 304)
    /// Rotation hint for the taken-off glasses, in degrees (a playful tilt).
    static let glassesOffRotation: Double = -12
    /// Uniform scale of the taken-off glasses (rim weight is kept constant regardless).
    static let glassesOffScale: CGFloat = 0.82
    /// Horizontal squash of the taken-off glasses (1 = facing the viewer).
    static let glassesOffSquash: CGFloat = 1
    /// Temple hinges (outer top corner of each rim) in the glasses' design space.
    static let glassesHingeLeft = CGPoint(x: 120, y: 145)
    static let glassesHingeRight = CGPoint(x: 280, y: 145)
    /// Where the paws hold the glasses (centre of each paw, just outside the outer rims) in the
    /// glasses' design space. The fingers overlap only the outer rim.
    static let glassesGripLeft = CGPoint(x: 97, y: 168)
    static let glassesGripRight = CGPoint(x: 303, y: 168)

    // Body

    /// Shoulder points the upper arms start from (tucked under the head).
    static let shoulderLeft = CGPoint(x: 124, y: 262)
    static let shoulderRight = CGPoint(x: 276, y: 262)
    /// Paw positions when not holding anything (resting on the tummy).
    static let pawRestLeft = CGPoint(x: 162, y: 318)
    static let pawRestRight = CGPoint(x: 238, y: 318)

    /// Converts a unit-space point to a SwiftUI `UnitPoint` (for `anchor:` parameters) for a
    /// layer showing `viewport`.
    static func unitPoint(_ point: CGPoint, in viewport: CGRect = canvasRect) -> UnitPoint {
        UnitPoint(x: (point.x - viewport.minX) / viewport.width, y: (point.y - viewport.minY) / viewport.height)
    }
}
