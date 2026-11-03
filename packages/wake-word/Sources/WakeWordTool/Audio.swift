@preconcurrency import AVFoundation
import Foundation

/// 16 kHz mono 16-bit audio, the format of the G2 microphone.
enum Audio {
    static let rate = 16_000

    static func read(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ToolError("can't read \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        if buffer.format == target, let data = buffer.int16ChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * Double(rate) / buffer.format.sampleRate) + 64) else {
            throw ToolError("can't convert \(url.lastPathComponent)")
        }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength)))
    }

    static func write(_ samples: [Int16], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        samples.withUnsafeBufferPointer { buffer.int16ChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }
}

struct ToolError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Small deterministic generator, so a rerun makes the same clips.
struct Random: RandomNumberGenerator {
    private var state: UInt64

    init(seed: String) {
        // FNV-1a over the name.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        state = hash
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

enum Paths {
    /// Everything generated lives under `data/` (gitignored).
    static let data = URL(fileURLWithPath: "data")
    static let raw = data.appending(path: "raw")
    static let synthetic = data.appending(path: "synthetic")
    /// Clips recorded with the glasses' mic in the app's Debug screen, copied here by hand.
    static let user = data.appending(path: "user")
    static let model = URL(fileURLWithPath: "HeyLotti.mlmodel")
    static let appModel = URL(fileURLWithPath: "../../apps/ios/Lotti/HeyLotti.mlmodel")
    static let classes = ["hey_lotti", "background"]

    static func wavs(_ directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
    }
}
