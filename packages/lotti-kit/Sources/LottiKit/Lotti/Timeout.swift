import Foundation

/// Runs `work` and returns its result, or nil if `duration` passes first (then `work` is
/// cancelled). Main-actor only, so the work can use main-actor state such as the model session.
@MainActor
func withTimeout<T: Sendable>(_ duration: Duration, _ work: @escaping @MainActor () async -> T) async -> T? {
    let gate = Gate<T>()
    return await withCheckedContinuation { continuation in
        gate.continuation = continuation
        gate.worker = Task { @MainActor in gate.finish(await work()) }
        Task { @MainActor in
            try? await Task.sleep(for: duration)
            gate.worker?.cancel()
            gate.finish(nil)
        }
    }
}

@MainActor
private final class Gate<T: Sendable> {
    var continuation: CheckedContinuation<T?, Never>?
    var worker: Task<Void, Never>?

    func finish(_ value: T?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
