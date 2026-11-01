import CLC3
import Foundation
import Testing
@testable import LottiKit

struct MicrophoneTests {
    @Test func audioControlPayload() {
        // {1: 15, 2: 120, 18: {1: 1}} and {1: 15, 2: 121, 18: {1: 0}}
        #expect(hex(G2Payload.audioControl(magic: 120, enabled: true)) == "080f10789201020801")
        #expect(hex(G2Payload.audioControl(magic: 121, enabled: false)) == "080f10799201020800")
    }

    @Test func fullPacketHoldsFiveFramesAndDropsMetadata() {
        let packet = (0..<205).map { UInt8($0 & 0xFF) }
        let frames = G2Microphone.frames(in: packet)
        #expect(frames.count == 5)
        #expect(frames.allSatisfy { $0.count == 40 })
        #expect(frames[0].first == 0)
        #expect(frames[4].last == 199)
    }

    @Test func shortPacketYieldsWholeFramesOnly() {
        #expect(G2Microphone.frames(in: [UInt8](repeating: 0, count: 95)).count == 2)
        #expect(G2Microphone.frames(in: [UInt8](repeating: 0, count: 39)).isEmpty)
        // Never more than five frames, even if a packet is longer than expected.
        #expect(G2Microphone.frames(in: [UInt8](repeating: 0, count: 400)).count == 5)
    }

    @Test func decodesWhatLC3EncodedFromA1kHzTone() throws {
        let rate = G2Microphone.sampleRate
        let frameSamples = G2Microphone.samplesPerFrame
        let frameCount = 50  // 0.5 s
        let tone = (0..<(frameSamples * frameCount)).map {
            Int16(8000 * sin(2 * Double.pi * 1000 * Double($0) / Double(rate)))
        }

        // Encode with liblc3 at the glasses' settings: 10 ms frames, 40 bytes each.
        let encoderSize = Int(lc3_encoder_size(G2Microphone.frameDurationMicroseconds, Int32(rate)))
        let memory = UnsafeMutableRawPointer.allocate(byteCount: encoderSize, alignment: 16)
        defer { memory.deallocate() }
        let encoder = try #require(lc3_setup_encoder(G2Microphone.frameDurationMicroseconds, Int32(rate), 0, memory))
        var packets: [[UInt8]] = []
        var packet: [UInt8] = []
        for i in 0..<frameCount {
            var frame = [UInt8](repeating: 0, count: G2Microphone.frameBytes)
            let pcm = Array(tone[(i * frameSamples)..<((i + 1) * frameSamples)])
            let result = pcm.withUnsafeBufferPointer { input in
                frame.withUnsafeMutableBytes { out in
                    lc3_encode(encoder, LC3_PCM_FORMAT_S16, input.baseAddress, 1, Int32(out.count), out.baseAddress)
                }
            }
            #expect(result == 0)
            packet += frame
            if packet.count == 200 {
                packets.append(packet + [0, 0, 0, 0, UInt8(packets.count)])  // + metadata, like the glasses
                packet = []
            }
        }
        #expect(packets.count == 10)

        let decoder = try #require(LC3Decoder())
        let decoded = packets.flatMap { decoder.decode(packet: $0) }
        #expect(decoded.count == tone.count)

        // LC3 has a few ms of delay; compare energy and the best correlation over small lags,
        // skipping the first frames while the decoder settles.
        let skip = frameSamples * 5
        let original = tone[skip...].map(Double.init)
        func energy(_ x: [Double]) -> Double { x.reduce(0) { $0 + $1 * $1 } / Double(x.count) }
        let decodedTail = decoded[skip...].map(Double.init)
        let ratio = energy(decodedTail) / energy(original)
        #expect(ratio > 0.7 && ratio < 1.3, "energy ratio \(ratio)")

        let n = original.count - 200
        let best = (0..<200).map { lag -> Double in
            var dot = 0.0, a = 0.0, b = 0.0
            for i in 0..<n {
                let x = original[original.startIndex + i]
                let y = decodedTail[decodedTail.startIndex + i + lag]
                dot += x * y
                a += x * x
                b += y * y
            }
            return dot / (a * b).squareRoot()
        }.max() ?? 0
        #expect(best > 0.9, "best correlation \(best)")
    }

    @Test func lostFrameIsConcealedNotDropped() throws {
        let decoder = try #require(LC3Decoder())
        #expect(decoder.decode(nil).count == G2Microphone.samplesPerFrame)
    }
}
