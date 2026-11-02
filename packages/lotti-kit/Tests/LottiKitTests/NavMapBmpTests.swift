import Compression
import Foundation
import Testing
@testable import LottiKit

struct NavMapBmpTests {
    /// RGBA for one pixel.
    static func pixel(_ rgb: (r: UInt8, g: UInt8, b: UInt8), alpha: UInt8 = 255) -> [UInt8] {
        [rgb.r, rgb.g, rgb.b, alpha]
    }

    @Test func paletteClassificationMatchesTheApp() {
        // Roads green, route red, everything else off.
        #expect(NavMapBmp.classify(r: 0, g: 255, b: 0, a: 255) == 1)
        #expect(NavMapBmp.classify(r: 255, g: 0, b: 0, a: 255) == 2)
        #expect(NavMapBmp.classify(r: 0, g: 0, b: 0, a: 255) == 0)      // black: too dark
        #expect(NavMapBmp.classify(r: 128, g: 128, b: 128, a: 255) == 0)  // gray: not saturated
        #expect(NavMapBmp.classify(r: 0, g: 255, b: 0, a: 0) == 0)        // transparent
        #expect(NavMapBmp.classify(r: 255, g: 255, b: 255, a: 255) == 0)  // white: no hue
        #expect(NavMapBmp.classify(r: 0, g: 0, b: 255, a: 255) == 0)      // blue: wrong hue
    }

    @Test func encodesAValid4bppBmp() {
        // 2×1: one green pixel (index 1), one red (index 2).
        let rgba = Self.pixel(NavMapBmp.road) + Self.pixel(NavMapBmp.route)
        let frame = NavMapBmp.encode(rgba: rgba, width: 2, height: 1)
        #expect(frame != nil)
        let bmp = try! #require(frame).data

        #expect(bmp[0] == 0x42 && bmp[1] == 0x4D)  // "BM"
        #expect(readLE32(bmp, 2) == UInt32(bmp.count))
        #expect(readLE32(bmp, 10) == 0x76)  // data offset: 14 + 40 + 64
        #expect(readLE32(bmp, 18) == 2)  // width
        #expect(readLE32(bmp, 22) == 1)  // height
        #expect(readLE16(bmp, 28) == 4)  // bpp
        #expect(readLE32(bmp, 38) == 2835)  // 72 dpi
        #expect(readLE32(bmp, 46) == 3)  // biClrUsed: black, green, red
        #expect(readLE32(bmp, 50) == 3)  // biClrImportant

        // Palette: 0 black, 1 green, 2 red.
        #expect(readLE32(bmp, 54) == 0x00000000)
        #expect(readLE32(bmp, 58) == 0x0000FF00)
        #expect(readLE32(bmp, 62) == 0x00FF0000)

        // Pixels: high nibble first — green | red.
        #expect(bmp[118] == 0x12)
    }

    @Test func rowsAreBottomUp() {
        // 2×2: top row green+green, bottom row red+red.
        let top = Self.pixel(NavMapBmp.road) + Self.pixel(NavMapBmp.road)
        let bottom = Self.pixel(NavMapBmp.route) + Self.pixel(NavMapBmp.route)
        let frame = NavMapBmp.encode(rgba: top + bottom, width: 2, height: 2)
        let bmp = try! #require(frame).data
        // First pixel row in the file is the bottom (red) row.
        #expect(bmp[118] == 0x22)
        #expect(bmp[118 + NavMapBmp.rowBytes(forWidth: 2)] == 0x11)
    }

    @Test func rowPaddingReachesFourBytes() {
        // The app's real map widths.
        #expect(NavMapBmp.rowBytes(forWidth: 576) == 288)  // max map
        #expect(NavMapBmp.rowBytes(forWidth: 170) == 88)   // mini map: (85 + 3) & ~3
        #expect(NavMapBmp.rowBytes(forWidth: 143) == 72)   // odd: 72 → aligned
        #expect(NavMapBmp.rowBytes(forWidth: 2) == 4)      // 1 byte of pixels padded to 4
        #expect(NavMapBmp.rowBytes(forWidth: 6) == 4)      // 3 bytes padded to 4
    }

    @Test func realMapSizesMatchTheApp() {
        // BMP file totals: 54262 (576×188) and 15078 (170×170), per the app's encoder.
        let max = NavMapBmp.file(
            pixels: [UInt8](repeating: 0, count: 576 * 188), width: 576, height: 188)
        #expect(max.count == 54262)
        let mini = NavMapBmp.file(
            pixels: [UInt8](repeating: 0, count: 170 * 170), width: 170, height: 170)
        #expect(mini.count == 15078)
        // The fragment budgets apply to the compressed payload: raw sizes don't decide.
        #expect(max.count > 4096)  // the max map always fragments (4096)
    }

    @Test func lz4RoundTrips() {
        // A mostly-empty map compresses well; the payload must decompress back to the BMP.
        let (width, height) = NavMapBmp.Size.mini
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) where pixel % 7 == 0 {
            rgba[pixel * 4 + 1] = 255  // green speckle
        }
        let frame = try! #require(NavMapBmp.encode(rgba: rgba, width: width, height: height))
        #expect(frame.mode == .lz4)
        #expect(frame.mode.rawValue == 4)
        let bmpSize = 118 + NavMapBmp.rowBytes(forWidth: width) * height
        var out = [UInt8](repeating: 0, count: bmpSize + 64)
        let outCount = out.count
        let written = out.withUnsafeMutableBytes { dst -> Int in
            frame.data.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, outCount,
                    src.bindMemory(to: UInt8.self).baseAddress!, frame.data.count, nil,
                    COMPRESSION_LZ4_RAW)
            }
        }
        // The LZ4 block decompresses back to the whole BMP file.
        #expect(written == bmpSize)
        #expect(out[0] == 0x42 && out[1] == 0x4D)
    }

    @Test func incompressibleDataFallsBackToRaw() {
        // Truly high-entropy input: LZ4 can't shrink it, so the raw BMP wins (the app's rule).
        var noise = [UInt8](repeating: 0, count: 5000)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for index in noise.indices {
            seed = seed &* 6364136223846793005 &+ 1
            noise[index] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        let frame = NavMapBmp.compressed(noise)
        #expect(frame.mode == .raw)
        #expect(frame.mode.rawValue == 0)
        #expect(frame.data == noise)
    }

    @Test func rejectsMismatchedInput() {
        #expect(NavMapBmp.encode(rgba: [0, 0, 0, 255], width: 2, height: 2) == nil)
        #expect(NavMapBmp.encode(rgba: [], width: 0, height: 0) == nil)
    }

    private func readLE16(_ buffer: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(buffer[offset]) | UInt16(buffer[offset + 1]) << 8
    }

    private func readLE32(_ buffer: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(buffer[offset]) | UInt32(buffer[offset + 1]) << 8
            | UInt32(buffer[offset + 2]) << 16 | UInt32(buffer[offset + 3]) << 24
    }
}
