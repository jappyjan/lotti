import Foundation

/// One case run against one model.
public struct CaseResult: Codable, Sendable {
    public var model: String
    public var caseID: String
    public var task: EvalTask
    public var output: CaseOutput?
    public var error: String?
    public var checks: [Check]
    /// Time to the first streamed snapshot.
    public var ttftMs: Int?
    public var totalMs: Int
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// This app's memory footprint after the case (Apple's model runs in a system process).
    public var footprintMB: Int

    public var passed: Bool { error == nil && checks.allSatisfy(\.passed) }
}

/// Per model and task: how many cases passed every check, and typical latency.
public struct TaskSummary: Codable, Sendable {
    public var model: String
    public var task: EvalTask
    public var cases: Int
    public var passed: Int
    public var errors: Int
    public var medianTtftMs: Int?
    public var medianTotalMs: Int?
    public var maxFootprintMB: Int

    public static func make(_ results: [CaseResult]) -> [TaskSummary] {
        let groups = Dictionary(grouping: results) { "\($0.model)|\($0.task.rawValue)" }
        return groups.values.compactMap { group in
            guard let first = group.first else { return nil }
            return TaskSummary(
                model: first.model, task: first.task, cases: group.count,
                passed: group.filter(\.passed).count,
                errors: group.filter { $0.error != nil }.count,
                medianTtftMs: median(group.compactMap(\.ttftMs)),
                medianTotalMs: median(group.filter { $0.error == nil }.map(\.totalMs)),
                maxFootprintMB: group.map(\.footprintMB).max() ?? 0)
        }
        .sorted { ($0.model, EvalTask.allCases.firstIndex(of: $0.task)!) < ($1.model, EvalTask.allCases.firstIndex(of: $1.task)!) }
    }

    static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }
}

/// The `[Eval] …` console lines the spike collects from the device log.
public enum EvalLog {
    public static func line(_ kind: String, _ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "[Eval] \(kind) \(json)"
    }
}

/// Resident memory as the system counts it for jetsam (phys_footprint), in MB.
public func memoryFootprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
}
