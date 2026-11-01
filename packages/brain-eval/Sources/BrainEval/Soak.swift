#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Sustained use: loops over the eval set for `minutes` and prints one `[Eval] soak` line a minute
/// with throughput, latency, memory, thermal state and whatever `device` adds (battery).
@available(iOS 27.0, macOS 27.0, *)
public struct Soak: Sendable {
    public struct Sample: Codable, Sendable {
        public var model: String
        public var minute: Int
        public var casesThisMinute: Int
        public var errorsThisMinute: Int
        public var medianTotalMs: Int?
        public var outputTokensPerSecond: Double?
        public var footprintMB: Int
        public var thermal: String
        public var device: [String: String]
    }

    public let runner: EvalRunner

    public init(runner: EvalRunner) {
        self.runner = runner
    }

    public func run(
        _ model: some LanguageModel, label: String, minutes: Int,
        device: @Sendable () async -> [String: String],
        log: @Sendable (String) -> Void = { print($0) }
    ) async {
        let start = ContinuousClock.now
        var minute = 0
        var index = 0
        var window: [CaseResult] = []
        var windowStart = start
        log(EvalLog.line("soak", sample(label, 0, [], .zero, await device())))
        while !Task.isCancelled, ContinuousClock.now - start < .seconds(minutes * 60) {
            let evalCase = runner.set.cases[index % runner.set.cases.count]
            index += 1
            window.append(await runner.run(evalCase, model: model, label: label))
            if ContinuousClock.now - windowStart >= .seconds(60) {
                minute += 1
                log(EvalLog.line("soak", sample(label, minute, window, ContinuousClock.now - windowStart, await device())))
                window = []
                windowStart = .now
            }
        }
    }

    private func sample(_ label: String, _ minute: Int, _ window: [CaseResult], _ elapsed: Duration, _ device: [String: String]) -> Sample {
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let tokens = window.compactMap(\.outputTokens).reduce(0, +)
        return Sample(
            model: label, minute: minute, casesThisMinute: window.count,
            errorsThisMinute: window.filter { $0.error != nil }.count,
            medianTotalMs: TaskSummary.median(window.map(\.totalMs)),
            outputTokensPerSecond: seconds > 0 ? (Double(tokens) / seconds * 10).rounded() / 10 : nil,
            footprintMB: memoryFootprintMB(), thermal: Self.thermal, device: device)
    }

    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
#endif
