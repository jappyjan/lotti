@preconcurrency import CoreML
import Foundation
@preconcurrency import SoundAnalysis

/// `wake-word test`: runs the trained model on the held-out clips the way the app does
/// (SoundAnalysis, `hey_lotti` confidence against the app's threshold) and reports per group.
enum Evaluate {
    static let threshold = 0.8

    static func run() throws {
        guard FileManager.default.fileExists(atPath: Paths.model.path) else {
            throw ToolError("no \(Paths.model.path): run `wake-word train` first")
        }
        try Generate.prepareUserClips()
        let compiled = try MLModel.compileModel(at: Paths.model)
        let model = try MLModel(contentsOf: compiled)
        let held = Clip.all().filter(\.isHeldOut)

        var table: [String: (hits: Int, total: Int)] = [:]
        var misses: [String] = []
        var scores: [(label: String, score: Double)] = []
        for clip in held {
            let score = try best(clip.url, model: model)
            scores.append((clip.label, score))
            let fired = score >= threshold
            if fired != (clip.label == "hey_lotti") { misses.append(String(format: "%.2f %@", score, clip.url.lastPathComponent)) }
            let key = "\(clip.label)/\(clip.group)"
            table[key, default: (0, 0)].total += 1
            if fired { table[key, default: (0, 0)].hits += 1 }
        }

        var lines = ["Held-out clips: \(held.count), threshold \(threshold)", ""]
        func rate(_ keys: [String], rejected: Bool) -> (Double, Int) {
            let total = keys.reduce(0) { $0 + (table[$1]?.total ?? 0) }
            let hits = keys.reduce(0) { $0 + (table[$1]?.hits ?? 0) }
            return (total == 0 ? .nan : Double(rejected ? total - hits : hits) / Double(total), total)
        }
        for key in table.keys.sorted() {
            let entry = table[key]!
            let positive = key.hasPrefix("hey_lotti")
            let value = positive ? Double(entry.hits) : Double(entry.total - entry.hits)
            lines.append(String(format: "%-24@ %@ %5.1f%% (%d of %d)", key as NSString, positive ? "fires   " : "rejected", 100 * value / Double(entry.total),
                                Int(value), entry.total))
        }
        let recall = rate(table.keys.filter { $0.hasPrefix("hey_lotti/") && !$0.hasSuffix("/user") }, rejected: false)
        let near = rate(["background/near"], rejected: true)
        let background = rate(table.keys.filter { $0.hasPrefix("background/") && $0 != "background/near" }, rejected: true)
        lines += ["",
                  String(format: "recall, synthetic hey_lotti: %.1f%% of %d (target 95%%)", 100 * recall.0, recall.1),
                  String(format: "rejection, near misses: %.1f%% of %d (target 98%%)", 100 * near.0, near.1),
                  String(format: "rejection, other background: %.1f%% of %d (target 98%%)", 100 * background.0, background.1)]
        lines += ["", "Wrong at the threshold:"] + misses.prefix(40)
        lines.append("")
        for t in [0.5, 0.7, 0.8, 0.9, 0.95] {
            let pos = scores.filter { $0.label == "hey_lotti" }, neg = scores.filter { $0.label == "background" }
            lines.append(String(format: "threshold %.2f: recall %.1f%%, rejection %.1f%%", t,
                                100 * Double(pos.filter { $0.score >= t }.count) / Double(max(pos.count, 1)),
                                100 * Double(neg.filter { $0.score < t }.count) / Double(max(neg.count, 1))))
        }
        print(lines.joined(separator: "\n"))
        try? lines.joined(separator: "\n").write(to: Paths.data.appending(path: "results.txt"), atomically: true, encoding: .utf8)
    }

    /// The highest `hey_lotti` confidence over the clip's windows.
    static func best(_ url: URL, model: MLModel) throws -> Double {
        let analyzer = try SNAudioFileAnalyzer(url: url)
        let request = try SNClassifySoundRequest(mlModel: model)
        let observer = Observer()
        try analyzer.add(request, withObserver: observer)
        analyzer.analyze()
        return observer.best
    }

    final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        var best = 0.0
        func request(_ request: SNRequest, didProduce result: SNResult) {
            if let result = result as? SNClassificationResult, let hit = result.classification(forIdentifier: "hey_lotti") {
                best = max(best, hit.confidence)
            }
        }
    }
}
