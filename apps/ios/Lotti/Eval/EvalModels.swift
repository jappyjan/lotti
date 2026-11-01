import BrainEval
import Foundation
import FoundationModels
import HuggingFace
import MLXFoundationModels
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Spike S3: the models under test, all behind FoundationModels' `LanguageModel`.
@available(iOS 27.0, *)
enum EvalModelChoice: String, CaseIterable, Identifiable, Sendable {
    case apple = "Apple on-device"
    case pcc = "Apple PCC"
    case gemmaE2B = "Gemma 4 E2B"
    case gemmaE4B = "Gemma 4 E4B"

    var id: String { rawValue }

    var isGemma: Bool { self == .gemmaE2B || self == .gemmaE4B }

    /// Short label for `[Eval]` lines.
    var label: String {
        switch self {
        case .apple: "apple"
        case .pcc: "pcc"
        case .gemmaE2B: "gemma4-e2b"
        case .gemmaE4B: "gemma4-e4b"
        }
    }
}

/// Gemma weights are downloaded on the phone from Hugging Face into the app's caches
/// (not the app bundle, not git). They survive app updates; deleting the app removes them.
@available(iOS 27.0, *)
enum GemmaModels {
    static func make(_ choice: EvalModelChoice) -> MLXLanguageModel {
        let configuration = choice == .gemmaE4B ? LLMRegistry.gemma4_e4b_it_4bit : LLMRegistry.gemma4_e2b_it_4bit
        return MLXLanguageModel(
            configuration: configuration,
            capabilities: [.guidedGeneration, .toolCalling],
            weightsLocation: { id in weightsDirectory(id) },
            load: { configuration, progress in
                let label = choice.label
                return try await loadModelContainer(
                    from: HubDownloader(),
                    using: TransformersTokenizerLoader(),
                    configuration: configuration,
                    progressHandler: { p in
                        progress(p)
                        let percent = Int(p.fractionCompleted * 100)
                        if percent % 10 == 0 { print("[Eval] download \(label) \(percent)%") }
                    })
            })
    }

    static func weightsDirectory(_ id: String) -> URL {
        let cache = HubCache.default
        guard let repo = Repo.ID(rawValue: id) else { return cache.cacheDirectory }
        if let commit = cache.resolveRevision(repo: repo, kind: .model, ref: "main"),
            let snapshot = try? cache.snapshotPath(repo: repo, kind: .model, commitHash: commit)
        {
            return snapshot
        }
        return cache.repoDirectory(repo: repo, kind: .model)
    }
}
