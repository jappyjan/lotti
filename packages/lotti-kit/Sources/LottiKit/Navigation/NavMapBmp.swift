import Compression
import Foundation

/// The lens' navigation map format, reconstructed from the Even app's `encodeRoadNetworkBmp4`
/// (see ~/lotti-recon/map-image-push.md): an RGBA drawing is reduced to a 3-entry palette
/// (0 = off, 1 = green road, 2 = red route), packed 4 bpp into a full BMP file — rows bottom-up,
/// 16-entry palette, pixel data offset 0x76 — and then LZ4-compressed when that shrinks it,
/// else sent raw. `compressMode` in the map message reflects the winner (1 = LZ4, 2 = raw;
/// the app's custom RLE, 0, is not implemented here).
public enum NavMapBmp {
    public enum Compression: UInt64, Sendable {
        /// The app's custom run-length encoding. Format unknown; not implemented.
        case rle = 0
        case lz4 = 1
        /// Uncompressed BMP. The app sends raw whenever compression doesn't shrink the data;
        /// the "none" mode value is a guess (0 and 1 are taken).
        case raw = 2
    }

    /// Bitmap dimensions the renderer draws at. The firmware scales whatever the BMP header
    /// says; these match the app's map sizes closely enough (best-guess values).
    public enum Size {
        public static let mini = (width: 144, height: 144)
        public static let full = (width: 576, height: 288)
    }

    /// Palettes the drawing contracts to, exactly what the app's classifier reads:
    /// green roads, red route, anything else off.
    public static let off = (r: UInt8(0), g: UInt8(0), b: UInt8(0))
    public static let road = (r: UInt8(0), g: UInt8(255), b: UInt8(0))
    public static let route = (r: UInt8(255), g: UInt8(0), b: UInt8(0))

    public static func rowBytes(forWidth width: Int) -> Int { ((width + 1) >> 1 + 3) & ~3 }

    /// RGBA (`width * height * 4`, top row first) → (BMP bytes, compress mode). Nil on bad input.
    public static func encode(rgba: [UInt8], width: Int, height: Int) -> (data: [UInt8], mode: Compression)? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        var indices = [UInt8](repeating: 0, count: width * height)
        for pixel in 0..<(width * height) {
            let r = rgba[pixel * 4], g = rgba[pixel * 4 + 1], b = rgba[pixel * 4 + 2]
            let a = rgba[pixel * 4 + 3]
            indices[pixel] = classify(r: r, g: g, b: b, a: a)
        }
        let bmp = Self.file(pixels: indices, width: width, height: height)
        return Self.compressed(bmp)
    }

    /// The app's `_classifyPaletteIndex`: alpha or brightness too low → off; saturated green
    /// (hue 70–170°) → road; saturated red (hue < 25° or ≥ 335°) → route; anything else off.
    static func classify(r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> UInt8 {
        guard a >= 16, max(r, g, b) >= 16 else { return 0 }
        let (h, s, v) = hsv(r: r, g: g, b: b)
        guard s >= 0.25, v >= 0.07 else { return 0 }
        if h >= 70, h <= 170, g >= r, g >= b { return 1 }
        if (h < 25 || h >= 335), r >= g, r >= b { return 2 }
        return 0
    }

    /// RGB → HSV, hue in degrees [0, 360).
    static func hsv(r: UInt8, g: UInt8, b: UInt8) -> (h: Double, s: Double, v: Double) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let maxc = max(rf, gf, bf), minc = min(rf, gf, bf)
        let delta = maxc - minc
        var h = 0.0
        if delta > 0 {
            if maxc == rf { h = 60 * ((gf - bf) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxc == gf { h = 60 * ((bf - rf) / delta + 2) }
            else { h = 60 * ((rf - gf) / delta + 4) }
            if h < 0 { h += 360 }
        }
        let s = maxc > 0 ? delta / maxc : 0
        return (h, s, maxc)
    }

    /// Assemblies the BMP file: `BM` header, BITMAPINFOHEADER (bpp 4, 2835 ppm, 16 palette
    /// entries), the palette (0 black, 1 green, 2 red), then 4-bpp pixels bottom-up with each
    /// row padded to 4 bytes. Two pixels per byte, high nibble first.
    static func file(pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        let rowStride = rowBytes(forWidth: width)
        let pixelBytes = rowStride * height
        let fileSize = 118 + pixelBytes
        var bmp = [UInt8](repeating: 0, count: fileSize)

        // 14-byte file header.
        bmp[0] = 0x42  // B
        bmp[1] = 0x4D  // M
        putLE32(&bmp, 2, UInt32(fileSize))
        putLE32(&bmp, 10, 0x76)  // pixel data offset: 14 + 40 + 16*4

        // 40-byte BITMAPINFOHEADER.
        putLE32(&bmp, 14, 40)
        putLE32(&bmp, 18, UInt32(width))
        putLE32(&bmp, 22, UInt32(height))
        putLE16(&bmp, 26, 1)  // planes
        putLE16(&bmp, 28, 4)  // bpp
        putLE32(&bmp, 30, 0)  // compression: BI_RGB
        putLE32(&bmp, 34, UInt32(pixelBytes))
        putLE32(&bmp, 38, 2835)  // 72 dpi in pixels per metre
        putLE32(&bmp, 42, 2835)
        putLE32(&bmp, 46, 16)  // palette entries used
        putLE32(&bmp, 50, 0)   // important colors

        // 16-entry palette (BGRA): 0 = black, 1 = green (roads), 2 = red (route), 3–15 = black.
        putLE32(&bmp, 54 + 1 * 4, 0x0000FF00)
        putLE32(&bmp, 54 + 2 * 4, 0x00FF0000)

        // Pixels, bottom row first, high nibble first.
        var cursor = 118
        for row in stride(from: height - 1, through: 0, by: -1) {
            var out = cursor
            var column = 0
            while column < width {
                let high = pixels[row * width + column]
                let low = column + 1 < width ? pixels[row * width + column + 1] : 0
                bmp[out] = (high << 4) | low
                out += 1
                column += 2
            }
            cursor += rowStride
        }
        return bmp
    }

    /// LZ4 block-compresses the BMP; raw wins when LZ4 doesn't shrink it (the app's rule).
    static func compressed(_ bmp: [UInt8]) -> (data: [UInt8], mode: Compression) {
        let bound = bmp.count + bmp.count / 255 + 16
        var scratch = [UInt8](repeating: 0, count: bound)
        let compressed = scratch.withUnsafeMutableBytes { raw -> Int in
            bmp.withUnsafeBytes { source -> Int in
                guard let src = source.baseAddress, let dst = raw.baseAddress else { return 0 }
                return compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self, capacity: bound), bound,
                    src.assumingMemoryBound(to: UInt8.self), bmp.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        if compressed > 0, compressed < bmp.count {
            return (Array(scratch[0..<compressed]), .lz4)
        }
        return (bmp, .raw)
    }

    private static func putLE16(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt16) {
        buffer[offset] = UInt8(truncatingIfNeeded: value)
        buffer[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func putLE32(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt32) {
        buffer[offset] = UInt8(truncatingIfNeeded: value)
        buffer[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        buffer[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        buffer[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
