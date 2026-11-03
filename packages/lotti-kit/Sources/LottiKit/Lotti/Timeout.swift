import Foundation

/// Runs `work` and returns its result, or nil if `duration` passes first (then `work` is
/// cancelled). Cancelling the caller cancels `work` too. With `activity`, only a `duration`
/// stretch of silence times out: each new activity pushes the deadline out again, so work that
/// keeps making progress isn't cut off.
/// Main-actor only, so the work can use main-actor state such as the model session.
@MainActor
func withTimeout<T: Sendable>(
    _ duration: Duration,
    activity: (@MainActor @Sendable () -> ContinuousClock.Instant)? = nil,
    _ work: @escaping @MainActor () async -> T
) async -> T? {
    let gate = Gate<T>()
    // The work runs in its own task, so a cancelled caller (double tap, a newer question) has to
    // pass the cancellation on; the timer is left to run out, its `finish` is then a no-op.
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            gate.continuation = continuation
            gate.worker = Task { @MainActor in gate.finish(await work()) }
            Task { @MainActor in
                guard let activity else {
                    try? await Task.sleep(for: duration)
                    gate.worker?.cancel()
                    gate.finish(nil)
                    return
                }
                var deadline = ContinuousClock.now.advanced(by: duration)
                var seen = activity()
                while true {
                    let now = ContinuousClock.now
                    let latest = activity()
                    if latest > seen {
                        seen = latest
                        deadline = latest.advanced(by: duration)
                    }
                    if now >= deadline {
                        gate.worker?.cancel()
                        gate.finish(nil)
                        return
                    }
                    try? await Task.sleep(for: min(.seconds(1), deadline - now))
                }
            }
        }
    } onCancel: {
        Task { @MainActor in gate.worker?.cancel() }
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
