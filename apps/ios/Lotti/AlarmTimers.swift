import AlarmKit
import Foundation
import LottiKit

/// Lotti's AlarmKit timers as the glasses see them: which ones run and ring, and stopping one
/// (which stops it on the phone and the lock screen too).
@MainActor
final class AlarmTimers: Timers {
    func updates() -> AsyncStream<[PhoneTimer]> {
        AsyncStream { continuation in
            let task = Task {
                var ringingSince: [UUID: Date] = [:]
                var last: [PhoneTimer]?
                for await alarms in AlarmManager.shared.alarmUpdates {
                    let entries = Self.load()
                    var running: [PhoneTimer] = []
                    var ringing: [UUID] = []
                    for alarm in alarms {
                        switch alarm.state {
                        case .alerting:
                            ringing.append(alarm.id)
                        case .countdown:
                            // AlarmKit doesn't say when a timer ends; Lotti noted it when setting it.
                            guard let entry = entries[alarm.id.uuidString] else { continue }
                            running.append(PhoneTimer(id: alarm.id, label: entry.label, state: .running(ends: entry.ends),
                                                      duration: entry.duration))
                        default:
                            continue
                        }
                    }
                    ringingSince = ringing.reduce(into: [:]) { result, id in result[id] = ringingSince[id] ?? Date() }
                    let now = running.sorted { $0.ends < $1.ends }
                        + ringing.sorted { ringingSince[$0]! < ringingSince[$1]! }
                        .map { PhoneTimer(id: $0, label: entries[$0.uuidString]?.label, state: .ringing) }
                    if now != last {
                        print("[Timers] \(now.map { "\($0.label ?? "timer") \($0.state)" })")
                        continuation.yield(now)
                        last = now
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop(_ id: UUID) async throws {
        try AlarmManager.shared.stop(id: id)
    }

    // MARK: - What AlarmKit doesn't hand back

    /// `SetTimerTool` notes each timer's name and end here: AlarmKit gives neither back.
    private nonisolated static let entriesKey = "timerEntries"

    private struct Entry: Codable {
        var label: String?
        var ends: Date
        var duration: TimeInterval?
    }

    nonisolated static func remember(_ id: UUID, label: String?, duration: TimeInterval) {
        // Timers last at most 12 hours; older entries belong to timers long gone.
        var entries = load().filter { $0.value.ends > Date().addingTimeInterval(-12 * 3600) }
        entries[id.uuidString] = Entry(label: label, ends: Date().addingTimeInterval(duration), duration: duration)
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: entriesKey)
    }

    private nonisolated static func load() -> [String: Entry] {
        UserDefaults.standard.data(forKey: entriesKey).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }
}

private extension PhoneTimer {
    var ends: Date {
        if case .running(let ends) = state { return ends }
        return .distantFuture
    }
}
