@preconcurrency import AVFoundation
import LottiKit

/// The phone's microphone, used when the glasses' mic doesn't work. Delivers 16 kHz mono PCM like
/// the glasses do.
@MainActor
final class PhoneMicrophone: Microphone {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<[Int16]>.Continuation?

    func start() async throws -> AsyncStream<[Int16]> {
        guard await AVAudioApplication.requestRecordPermission() else { throw MicrophoneError.notAllowed }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .mixWithOthers])
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else { throw MicrophoneError.format }

        let (stream, continuation) = AsyncStream<[Int16]>.makeStream()
        self.continuation = continuation
        input.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate) + 16
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: output, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard let samples = output.int16ChannelData?[0], output.frameLength > 0 else { return }
            continuation.yield(Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength))))
        }
        engine.prepare()
        try engine.start()
        print("[Mic] phone mic on (\(inputFormat.sampleRate) Hz)")
        return stream
    }

    func stop() async {
        guard continuation != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        print("[Mic] phone mic off")
    }
}

enum MicrophoneError: Error, LocalizedError {
    case notAllowed, format

    var errorDescription: String? {
        switch self {
        case .notAllowed: "Microphone access is off for Lotti (Settings → Lotti)."
        case .format: "The phone's microphone format isn't supported."
        }
    }
}
