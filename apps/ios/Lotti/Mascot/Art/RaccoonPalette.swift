import SwiftUI

/// Colours of the raccoon. Two hand-tuned sets: `light` reads on white, `dark` on near-black.
/// Views pick one from `@Environment(\.colorScheme)`; no asset catalog needed.
struct RaccoonPalette: Sendable {
    /// Silhouette outline. In dark mode a mid tone, so it reads as a soft rim against black
    /// and as an outline against the fur.
    var outline: Color
    /// Inner detail lines (mouth, toes, whiskers).
    var line: Color
    var fur: Color
    var furDark: Color
    var cream: Color
    var mask: Color
    var ring: Color
    var paw: Color
    var innerEar: Color
    var blush: Color
    var eyeWhite: Color
    var pupil: Color
    var nose: Color
    var shine: Color
    var frame: Color
    var frameEdge: Color
    var frameHighlight: Color
    /// Lens tint: ≤ 10 %, so eyes and mask show through.
    var lens: Color
    var glint: Color

    static let light = RaccoonPalette(
        outline: Color(raccoonHex: 0x3A3444),
        line: Color(raccoonHex: 0x3A3444),
        fur: Color(raccoonHex: 0xA9ACBC),
        furDark: Color(raccoonHex: 0x81849A),
        cream: Color(raccoonHex: 0xFCF7EF),
        mask: Color(raccoonHex: 0x3F3A4B),
        ring: Color(raccoonHex: 0x4A4559),
        paw: Color(raccoonHex: 0x4A4559),
        innerEar: Color(raccoonHex: 0xF4C7C3),
        blush: Color(raccoonHex: 0xFF8F9A, opacity: 0.5),
        eyeWhite: .white,
        pupil: Color(raccoonHex: 0x221B2A),
        nose: Color(raccoonHex: 0x2C2634),
        shine: .white,
        frame: Color(raccoonHex: 0x23A45A),
        frameEdge: Color(raccoonHex: 0x14653A),
        frameHighlight: Color(raccoonHex: 0x8BE3A9),
        lens: Color(raccoonHex: 0x8FE3B4, opacity: 0.09),
        glint: Color(raccoonHex: 0xFFFFFF, opacity: 0.85)
    )

    static let dark = RaccoonPalette(
        outline: Color(raccoonHex: 0x6A6580),
        line: Color(raccoonHex: 0x2E2938),
        fur: Color(raccoonHex: 0x9EA2B4),
        furDark: Color(raccoonHex: 0x777A90),
        cream: Color(raccoonHex: 0xEFE9DF),
        mask: Color(raccoonHex: 0x363142),
        ring: Color(raccoonHex: 0x423D52),
        paw: Color(raccoonHex: 0x423D52),
        innerEar: Color(raccoonHex: 0xE7B5B2),
        blush: Color(raccoonHex: 0xFF8F9A, opacity: 0.45),
        eyeWhite: Color(raccoonHex: 0xFBFAF7),
        pupil: Color(raccoonHex: 0x1D1724),
        nose: Color(raccoonHex: 0x2A2432),
        shine: .white,
        frame: Color(raccoonHex: 0x30C766),
        frameEdge: Color(raccoonHex: 0x14653A),
        frameHighlight: Color(raccoonHex: 0xA2F0BD),
        lens: Color(raccoonHex: 0x8FE3B4, opacity: 0.08),
        glint: Color(raccoonHex: 0xFFFFFF, opacity: 0.8)
    )

    static func resolve(_ scheme: ColorScheme) -> RaccoonPalette {
        scheme == .dark ? .dark : .light
    }
}

extension Color {
    /// sRGB colour from a 0xRRGGBB literal (raccoon palette only).
    init(raccoonHex hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
