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

    func cancel() {
        task?.cancel()
        status = "Cancelling…"
    }

    func runEval(_ choice: EvalModelChoice, task evalTask: EvalTask? = nil) {
        start("Eval \(choice.label)") { [self] runner in
            let cases = runner.set.cases.filter { evalTask == nil || $0.task == evalTask }
            let results = await self.withModel(choice) { model in
                await runner.run(model, label: choice.label, cases: cases)
            }
            lastSummaries = TaskSummary.make(results ?? [])
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

    /// Runs a triage case every 20 s for `minutes`, logging app state, so we can see what still works
    /// with the phone locked. Asks iOS for background time when the app leaves the foreground.
    func runBackgroundProbe(_ choice: EvalModelChoice, minutes: Int = 10) {
        start("Background probe \(choice.label)") { [self] runner in
            let evalCase = runner.set.cases.first { $0.task == .triage }!
            let background = BackgroundTime()
            defer { background.end() }
            _ = await self.withModel(choice) { model in
                let started = ContinuousClock.now
                var n = 0
                while !Task.isCancelled, ContinuousClock.now - started < .seconds(minutes * 60) {
                    n += 1
                    let state = await MainActor.run { Self.appState() }
                    if state != "active" { await MainActor.run { background.begin() } }
                    let result = await runner.run(evalCase, model: model, label: choice.label)
                    let remaining = await MainActor.run { UIApplication.shared.backgroundTimeRemaining }
                    print(EvalLog.line("background", BackgroundSample(
                        model: choice.label, n: n, appState: state,
                        backgroundTimeRemaining: remaining.isFinite ? Int(remaining) : -1,
                        ok: result.error == nil, totalMs: result.totalMs, error: result.error,
                        protectedData: await MainActor.run { UIApplication.shared.isProtectedDataAvailable })))
                    try? await Task.sleep(for: .seconds(20))
                }
            }
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
            print("[Eval] loaded \(choice.label) loadMs=\(loadMs) footprintMB=\(before)->\(memoryFootprintMB()) weights=\(GemmaModels.weightsDirectory(model.configuration.name).path)")
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
