import BrainEval
import Foundation
import FoundationModels
import MLXFoundationModels
import Observation
import UIKit

/// Spike S3: drives the eval runs from the eval screen. Results go to the console as `[Eval]` lines.
@available(iOS 27.0, *)
@MainActor
@Observable
final class EvalController {
    private(set) var status = "Idle"
    private(set) var isRunning = false
    private(set) var lastSummaries: [TaskSummary] = []
    private var task: Task<Void, Never>?
    private var gemma: [EvalModelChoice: MLXLanguageModel] = [:]
    private let runner: EvalRunner?

    init() {
        runner = (try? EvalSet.bundled()).map(EvalRunner.init)
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    /// Starts a run from launch arguments, so runs can be started from the Mac:
    /// `--eval apple|pcc|gemma4-e2b|gemma4-e4b [--tasks triage,tool] [--soak 30] [--background 10]`.
    func runFromLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        guard let label = value("--eval"), let choice = EvalModelChoice.allCases.first(where: { $0.label == label })
        else { return }
        if let minutes = value("--soak").flatMap(Int.init) {
            runSoak(choice, minutes: minutes)
        } else if let minutes = value("--background").flatMap(Int.init) {
            runBackgroundProbe(Self.choices(value("--probe")) ?? [choice], minutes: minutes)
        } else {
            let tasks = value("--tasks").map { Set($0.split(separator: ",").compactMap { EvalTask(rawValue: String($0)) }) }
            // `--then-background 10 --probe apple,gemma4-e2b`: run the eval, then the background probe.
            let then = value("--then-background").flatMap(Int.init).map { ($0, Self.choices(value("--probe")) ?? [choice]) }
            runEval(choice, tasks: tasks, then: then)
        }
    }

    private static func choices(_ list: String?) -> [EvalModelChoice]? {
        list.map { $0.split(separator: ",").compactMap { l in EvalModelChoice.allCases.first { $0.label == l } } }
    }

    func cancel() {
        task?.cancel()
        status = "Cancelling…"
    }

    func runEval(_ choice: EvalModelChoice, tasks: Set<EvalTask>? = nil, then background: (Int, [EvalModelChoice])? = nil) {
        start("Eval \(choice.label)") { [self] runner in
            let cases = runner.set.cases.filter { tasks?.contains($0.task) ?? true }
            let results = await self.withModel(choice) { model in
                await runner.run(model, label: choice.label, cases: cases)
            }
            lastSummaries = TaskSummary.make(results ?? [])
            if let (minutes, choices) = background {
                await self.backgroundProbe(choices, minutes: minutes, runner: runner)
            }
        }
    }

    /// 30 minutes of back-to-back cases, one `[Eval] soak` line a minute.
    func runSoak(_ choice: EvalModelChoice, minutes: Int = 30) {
        start("Soak \(choice.label) \(minutes) min") { [self] runner in
            _ = await self.withModel(choice) { model in
                await Soak(runner: runner).run(model, label: choice.label, minutes: minutes, device: { await Self.deviceStats() })
            }
        }
    }

    /// Runs a triage case on each model every 20 s for `minutes`, logging app state, so we can see
    /// what still works with the phone locked. Asks iOS for background time when the app leaves the
    /// foreground. At most one Gemma per probe.
    func runBackgroundProbe(_ choices: [EvalModelChoice], minutes: Int = 10) {
        let labels = choices.map(\.label).joined(separator: "+")
        start("Background probe \(labels)") { [self] runner in
            await self.backgroundProbe(choices, minutes: minutes, runner: runner)
        }
    }

    private func backgroundProbe(_ choices: [EvalModelChoice], minutes: Int, runner: EvalRunner) async {
        let evalCase = runner.set.cases.first { $0.task == .triage }!
        var models: [(EvalModelChoice, any LanguageModel)] = []
        if choices.contains(.apple) { models.append((.apple, SystemLanguageModel.default)) }
        let loop: () async -> Void = { [self] in
            let background = BackgroundTime()
            defer { background.end() }
            status = "Background probe running. Lock the phone now."
            print("[Eval] background probe ready, lock the phone")
            let started = ContinuousClock.now
            var n = 0
            while !Task.isCancelled, ContinuousClock.now - started < .seconds(minutes * 60) {
                n += 1
                for (choice, model) in models {
                    let state = Self.appState()
                    if state != "active" { background.begin() }
                    let result = await runner.run(evalCase, model: model, label: choice.label)
                    let remaining = UIApplication.shared.backgroundTimeRemaining
                    print(EvalLog.line("background", BackgroundSample(
                        model: choice.label, n: n, appState: state,
                        backgroundTimeRemaining: remaining.isFinite ? Int(remaining) : -1,
                        ok: result.error == nil, totalMs: result.totalMs, error: result.error,
                        protectedData: UIApplication.shared.isProtectedDataAvailable)))
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
        if let gemmaChoice = choices.first(where: \.isGemma) {
            _ = await withModel(gemmaChoice) { gemmaModel in
                models.append((gemmaChoice, gemmaModel))
                await loop()
            }
        } else {
            await loop()
        }
    }

    // MARK: - Helpers

    private func start(_ name: String, _ work: @escaping @MainActor (EvalRunner) async -> Void) {
        guard !isRunning, let runner else { return }
        isRunning = true
        status = "\(name)…"
        print("[Eval] start \(name)")
        task = Task {
            await work(runner)
            print("[Eval] end \(name)")
            status = Task.isCancelled ? "Cancelled" : "Done: \(name)"
            isRunning = false
        }
    }

    /// Prepares the model (Gemma: download + load, timed), then runs `body` with it.
    private func withModel<R>(_ choice: EvalModelChoice, _ body: (any LanguageModel) async -> R) async -> R? {
        switch choice {
        case .apple:
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                print("[Eval] error apple unavailable: \(model.availability)")
                status = "Apple model unavailable: \(model.availability)"
                return nil
            }
            return await body(model)
        case .pcc:
            let model = PrivateCloudComputeLanguageModel()
            print("[Eval] pcc availability=\(model.availability)")
            return await body(model)
        case .gemmaE2B, .gemmaE4B:
            // Only one Gemma in memory at a time.
            for (other, model) in gemma where other != choice { await model.evict() }
            gemma = gemma.filter { $0.key == choice }
            let model = gemma[choice] ?? GemmaModels.make(choice)
            gemma[choice] = model
            let before = memoryFootprintMB()
            let clock = ContinuousClock.now
            do {
                status = "Loading \(choice.label)…"
                try await model.preload()
            } catch {
                print("[Eval] error \(choice.label) load: \(error)")
                status = "Load failed: \(error.localizedDescription)"
                return nil
            }
            let loadMs = EvalRunnerTime.ms(ContinuousClock.now - clock)
            print("[Eval] loaded \(choice.label) loadMs=\(loadMs) footprintMB=\(before)->\(memoryFootprintMB()) weights=\((GemmaModels.sideloaded(model.configuration.name) ?? GemmaModels.weightsDirectory(model.configuration.name)).path)")
            status = "Running \(choice.label)…"
            return await body(model)
        }
    }

    static func deviceStats() async -> [String: String] {
        await MainActor.run {
            let device = UIDevice.current
            let state: String = switch device.batteryState {
            case .charging: "charging"
            case .full: "full"
            case .unplugged: "unplugged"
            default: "unknown"
            }
            return [
                "battery": String(format: "%.2f", device.batteryLevel),
                "batteryState": state,
                "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled ? "yes" : "no",
                "appState": appState(),
            ]
        }
    }

    static func appState() -> String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}

struct BackgroundSample: Codable {
    var model: String
    var n: Int
    var appState: String
    var backgroundTimeRemaining: Int
    var ok: Bool
    var totalMs: Int
    var error: String?
    var protectedData: Bool
}

enum EvalRunnerTime {
    static func ms(_ d: Duration) -> Int {
        Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// A UIKit background-time assertion, begun once when the app leaves the foreground.
@MainActor
final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard id == .invalid else { return }
        id = UIApplication.shared.beginBackgroundTask(withName: "lotti-eval") { [weak self] in
            print("[Eval] background time expired")
            self?.end()
        }
        print("[Eval] background task begun, remaining=\(Int(UIApplication.shared.backgroundTimeRemaining))s")
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
