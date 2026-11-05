import CreateML
import Foundation

/// A clip and where it came from.
struct Clip {
    var url: URL
    var label: String
    /// "pos", "near", "bg", "noise" for synthetic clips; "user" for ones recorded in the app.
    var group: String

    /// Clips made from one recording (`<id>~<variant>.wav`) stay together, so a held-out clip
    /// never has a near copy in the training set.
    var isHeldOut: Bool {
        let base = url.deletingPathExtension().lastPathComponent.split(separator: "~").first.map(String.init) ?? ""
        var rng = Random(seed: "split-" + base)
        return rng.next() % 100 < 15
    }

    static func all() -> [Clip] {
        var clips: [Clip] = []
        for label in Paths.classes {
            for url in Paths.wavs(Paths.synthetic.appending(path: label)) {
                let name = url.lastPathComponent
                let group = name.hasPrefix("pos-") ? "pos" : name.hasPrefix("near-") ? "near" : name.hasPrefix("noise-") ? "noise" : "bg"
                clips.append(Clip(url: url, label: label, group: group))
            }
            for url in Paths.wavs(Paths.userPrepared.appending(path: label)) { clips.append(Clip(url: url, label: label, group: "user")) }
        }
        return clips
    }
}

/// `wake-word train`: Create ML sound classifier on everything except the held-out 15%.
enum Train {
    static func run() throws {
        let started = Date()
        try Generate.prepareUserClips()
        let clips = Clip.all()
        guard clips.contains(where: { $0.label == "hey_lotti" }) else {
            throw ToolError("no training clips in data/: run `wake-word generate` first")
        }
        // Create ML crashes (stack overflow while freeing its feature chain) with much more than
        // ~7000 clips, so each class keeps at most `perClass`: your own clips first, then a fixed
        // random pick of the synthetic ones.
        let perClass = 3300
        var training: [Clip] = []
        for label in Paths.classes {
            let own = clips.filter { !$0.isHeldOut && $0.label == label }
            let ranked = own.sorted { lhs, rhs in
                if (lhs.group == "user") != (rhs.group == "user") { return lhs.group == "user" }
                var a = Random(seed: lhs.url.lastPathComponent), b = Random(seed: rhs.url.lastPathComponent)
                return a.next() < b.next()
            }
            training += ranked.prefix(perClass)
        }
        var data: [String: [URL]] = [:]
        for clip in training { data[clip.label, default: []].append(clip.url) }
        print("training on \(training.count) clips (\(data.map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", "))); "
              + "\(clips.count - training.count) held out; user clips: \(clips.filter { $0.group == "user" }.count)")

        let parameters = MLSoundClassifier.ModelParameters(
            validation: .split(strategy: .automatic), maxIterations: 100, overlapFactor: 0.75,
            algorithm: .transferLearning(featureExtractor: .vggish(), classifier: .multilayerPerceptron(layerSizes: [512, 128])))
        let classifier = try MLSoundClassifier(trainingData: data, parameters: parameters)
        print(String(format: "Create ML: training accuracy %.1f%%, validation accuracy %.1f%%",
                     100 * (1 - classifier.trainingMetrics.classificationError),
                     100 * (1 - classifier.validationMetrics.classificationError)))
        let metadata = MLModelMetadata(author: "Lotti", shortDescription: "Hey Lotti wake word: hey_lotti or background",
                                       version: "1")
        try classifier.write(to: Paths.model, metadata: metadata)
        try? FileManager.default.removeItem(at: Paths.appModel)
        try FileManager.default.copyItem(at: Paths.model, to: Paths.appModel)
        print("wrote \(Paths.model.path) and copied it to \(Paths.appModel.path) in \(Int(Date().timeIntervalSince(started))) s")
    }
}
