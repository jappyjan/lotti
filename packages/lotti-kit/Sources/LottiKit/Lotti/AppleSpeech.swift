#if canImport(Speech)
@preconcurrency import AVFoundation
import Foundation
import Speech

/// On-device speech-to-text with `SpeechAnalyzer` (iOS 26+). Takes 16 kHz mono PCM, the format of
/// the glasses' mic and of `PhoneMicrophone`.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
public final class AppleSpeechRecognizer: SpeechRecognizer {
    /// The language you speak to Lotti in.
    public var locale: Locale

    public init(locale: Locale) {
        self.locale = locale
    }

    /// Downloads the speech model for `locale` if it isn't installed yet.
    public func prepare() async {
        let locale = await Self.supported(locale)
        do {
            try await Self.install(for: Self.transcriber(locale))
            print("[Speech] ready for \(locale.identifier)")
        } catch {
            print("[Speech] can't prepare \(locale.identifier): \(error.localizedDescription)")
        }
    }

    public func transcribe(_ audio: AsyncStream<[Int16]>) -> AsyncThrowingStream<Transcript, Error> {
        let locale = self.locale
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await Self.run(audio, locale: locale) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated static func supported(_ locale: Locale) async -> Locale {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? Locale(identifier: "en-US")
    }

    nonisolated static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [])
    }

    nonisolated static func install(for transcriber: SpeechTranscriber) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            print("[Speech] downloading the speech model…")
            try await request.downloadAndInstall()
        }
    }

    nonisolated static func run(
        _ audio: AsyncStream<[Int16]>, locale requested: Locale, yield: @escaping @Sendable (Transcript) -> Void
    ) async throws {
        let locale = await supported(requested)
        let transcriber = transcriber(locale)
        try await install(for: transcriber)

        let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: input) ?? input
        let converter = format == input ? nil : AVAudioConverter(from: input, to: format)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)

        // Finalized text accumulates; the volatile tail is replaced by each new guess.
        let results = Task {
            var finalized = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalized += text
                    yield(Transcript(finalized))
                } else {
                    yield(Transcript(finalized + text))
                }
            }
            return finalized
        }

        var samples = 0
        for await chunk in audio {
            samples += chunk.count
            guard let buffer = pcmBuffer(chunk, format: input) else { continue }
            if let converter {
                if let converted = convert(buffer, with: converter, to: format) { feed.yield(AnalyzerInput(buffer: converted)) }
            } else {
                feed.yield(AnalyzerInput(buffer: buffer))
            }
        }
        feed.finish()
        print(String(format: "[Speech] audio ended after %.1f s", Double(samples) / 16_000))
        if samples == 0 {
            await analyzer.cancelAndFinishNow()
        } else {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        let final = try await results.value.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[Speech] heard: \(final)")
        yield(Transcript(final, isFinal: true))
    }

    nonisolated static func pcmBuffer(_ samples: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.int16ChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { print("[Speech] convert failed: \(error.localizedDescription)") }
        return output.frameLength > 0 ? output : nil
    }
}
#endif
