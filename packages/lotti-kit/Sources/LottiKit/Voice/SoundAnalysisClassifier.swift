#if canImport(SoundAnalysis)
@preconcurrency import AVFoundation
import CoreML
import Foundation
@preconcurrency import SoundAnalysis

/// Runs a Create ML sound classifier (`HeyLotti.mlmodel`, trained by `packages/wake-word`) with
/// SoundAnalysis. The model has two classes, `hey_lotti` and `background`.
public final class SoundAnalysisClassifier: SoundClassifier, @unchecked Sendable {
    public static let label = "hey_lotti"

    private let model: MLModel
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public init(model: MLModel) {
        self.model = model
    }

    /// Loads a compiled model (`.mlmodelc`) from `url`.
    public convenience init(contentsOf url: URL) throws {
        self.init(model: try MLModel(contentsOf: url))
    }

    public func score(_ window: [Int16]) async -> Double {
        guard !window.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(window.count)),
              let channel = buffer.floatChannelData?[0],
              let request = try? SNClassifySoundRequest(mlModel: model) else { return 0 }
        for (index, sample) in window.enumerated() { channel[index] = Float(sample) / 32768 }
        buffer.frameLength = AVAudioFrameCount(window.count)

        // One window in, one verdict out: the analyzer is cheap, the model is shared.
        let collector = Collector()
        let analyzer = SNAudioStreamAnalyzer(format: format)
        do {
            try analyzer.add(request, withObserver: collector)
            analyzer.analyze(buffer, atAudioFramePosition: 0)
            analyzer.completeAnalysis()
        } catch {
            return 0
        }
        return collector.best
    }

    private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0

        var best: Double { lock.withLock { value } }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult,
                  let hit = result.classification(forIdentifier: SoundAnalysisClassifier.label) else { return }
            lock.withLock { value = max(value, hit.confidence) }
        }
    }
}
#endif
