import CLC3
import Foundation

/// The G2 microphone stream. Protocol facts from MentraOS (`G2.swift`, mic data handling) and
/// even-g2-protocol (`transport/session.py` `enable_mic`):
/// - EvenHub Cmd 15 (audio control) to the right arm turns the mic on and off.
/// - Audio arrives as notifications on `…6402`, with no frame header or CRC. Each one is about
///   205 bytes: 5 LC3 frames of 40 bytes (10 ms each, 16 kHz mono), then a few bytes of metadata
///   (signal strength, direction, a counter) that we ignore.
public enum G2Microphone {
    public static let sampleRate = 16000
    public static let frameDurationMicroseconds: Int32 = 10000
    public static let frameBytes = 40
    /// 10 ms at 16 kHz.
    public static let samplesPerFrame = 160
    /// The LC3 part of one notification.
    public static let framesPerPacket = 5

    /// The LC3 frames in one notification. Takes up to `framesPerPacket` whole 40-byte frames and
    /// drops the trailing metadata, so short or odd-sized packets still yield what they hold.
    public static func frames(in packet: [UInt8]) -> [ArraySlice<UInt8>] {
        let count = min(packet.count / frameBytes, framesPerPacket)
        return (0..<count).map { packet[($0 * frameBytes)..<(($0 + 1) * frameBytes)] }
    }
}

/// Decodes one LC3 stream (10 ms frames, 16 kHz mono) to 16-bit PCM with Google's liblc3.
/// Not thread-safe: use one decoder per stream, from one place.
public final class LC3Decoder {
    private let memory: UnsafeMutableRawPointer
    private let decoder: lc3_decoder_t
    public let samplesPerFrame: Int

    public init?(
        frameDurationMicroseconds: Int32 = G2Microphone.frameDurationMicroseconds,
        sampleRate: Int32 = Int32(G2Microphone.sampleRate)
    ) {
        let size = Int(lc3_decoder_size(frameDurationMicroseconds, sampleRate))
        let samples = Int(lc3_frame_samples(frameDurationMicroseconds, sampleRate))
        guard size > 0, samples > 0 else { return nil }
        memory = .allocate(byteCount: size, alignment: 16)
        guard let decoder = lc3_setup_decoder(frameDurationMicroseconds, sampleRate, 0, memory) else {
            memory.deallocate()
            return nil
        }
        self.decoder = decoder
        samplesPerFrame = samples
    }

    deinit { memory.deallocate() }

    /// Decodes one frame. Pass nil for a lost frame: liblc3 then conceals the gap (PLC).
    /// Returns `samplesPerFrame` samples; silence if the frame is corrupt.
    public func decode(_ frame: ArraySlice<UInt8>?) -> [Int16] {
        var pcm = [Int16](repeating: 0, count: samplesPerFrame)
        let result: Int32 = pcm.withUnsafeMutableBufferPointer { out in
            guard let frame else {
                return lc3_decode(decoder, nil, 0, LC3_PCM_FORMAT_S16, out.baseAddress, 1)
            }
            return Array(frame).withUnsafeBytes { input in
                lc3_decode(decoder, input.baseAddress, Int32(input.count), LC3_PCM_FORMAT_S16, out.baseAddress, 1)
            }
        }
        if result < 0 { return [Int16](repeating: 0, count: samplesPerFrame) }
        return pcm
    }

    /// Decodes every LC3 frame in one mic notification (800 samples for a full packet).
    public func decode(packet: [UInt8]) -> [Int16] {
        G2Microphone.frames(in: packet).flatMap { decode($0) }
    }
}

/// Encodes 16 kHz mono PCM to LC3 (10 ms frames, 40 bytes each), the way the glasses do. Only for
/// training data: the wake word model is trained on audio that went through the same codec as the
/// G2 microphone. Not thread-safe.
public final class LC3Encoder {
    private let memory: UnsafeMutableRawPointer
    private let encoder: lc3_encoder_t
    public let samplesPerFrame: Int
    public let frameBytes: Int

    public init?(
        frameDurationMicroseconds: Int32 = G2Microphone.frameDurationMicroseconds,
        sampleRate: Int32 = Int32(G2Microphone.sampleRate), frameBytes: Int = G2Microphone.frameBytes
    ) {
        let size = Int(lc3_encoder_size(frameDurationMicroseconds, sampleRate))
        let samples = Int(lc3_frame_samples(frameDurationMicroseconds, sampleRate))
        guard size > 0, samples > 0 else { return nil }
        memory = .allocate(byteCount: size, alignment: 16)
        guard let encoder = lc3_setup_encoder(frameDurationMicroseconds, sampleRate, 0, memory) else {
            memory.deallocate()
            return nil
        }
        self.encoder = encoder
        samplesPerFrame = samples
        self.frameBytes = frameBytes
    }

    deinit { memory.deallocate() }

    /// Encodes one frame of `samplesPerFrame` samples.
    public func encode(_ frame: [Int16]) -> [UInt8]? {
        guard frame.count == samplesPerFrame else { return nil }
        var out = [UInt8](repeating: 0, count: frameBytes)
        let result = frame.withUnsafeBufferPointer { pcm in
            out.withUnsafeMutableBytes { bytes in
                lc3_encode(encoder, LC3_PCM_FORMAT_S16, pcm.baseAddress, 1, Int32(frameBytes), bytes.baseAddress)
            }
        }
        return result == 0 ? out : nil
    }

    /// Sends `samples` through encode and decode, as if they came from the glasses. A partial last
    /// frame is padded with silence; the result has the same length as the input.
    public static func roundTrip(_ samples: [Int16]) -> [Int16] {
        guard let encoder = LC3Encoder(), let decoder = LC3Decoder() else { return samples }
        var output: [Int16] = []
        output.reserveCapacity(samples.count)
        var index = 0
        while index < samples.count {
            var frame = Array(samples[index..<min(index + encoder.samplesPerFrame, samples.count)])
            frame += [Int16](repeating: 0, count: encoder.samplesPerFrame - frame.count)
            guard let bytes = encoder.encode(frame) else { return samples }
            output += decoder.decode(bytes[...])
            index += encoder.samplesPerFrame
        }
        return Array(output.prefix(samples.count))
    }
}
