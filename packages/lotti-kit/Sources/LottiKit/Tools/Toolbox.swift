import Foundation

/// The phone tools, and the rules for running them:
/// - reads run when a brain asks, several at once, each with a time limit;
/// - actions never run on a brain's say-so: they become `ProposedAction`s for the rail and run
///   only through `perform`, after you tap.
public struct Toolbox: Sendable {
    public let tools: [any PhoneTool]
    public var callTimeout: Duration

    public init(_ tools: [any PhoneTool] = [], callTimeout: Duration = .seconds(10)) {
        self.tools = tools
        self.callTimeout = callTimeout
    }

    public var specs: [PhoneToolSpec] { tools.map(\.spec) }
    public var reads: [PhoneToolSpec] { specs.filter { $0.effect == .read } }
    public var actions: [PhoneToolSpec] { specs.filter { $0.effect == .action } }

    public func tool(named name: String) -> (any PhoneTool)? {
        tools.first { $0.spec.name == name }
    }

    /// Runs read calls at the same time and returns their results in the order of `calls`.
    /// Calls to unknown tools, actions, or reads not in `allowed` get an error result instead.
    public func run(_ calls: [ToolCall], allowed: Set<String>) async -> [ToolResult] {
        await withTaskGroup(of: (Int, ToolResult).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask { (index, await run(call, allowed: allowed)) }
            }
            var results = [ToolResult?](repeating: nil, count: calls.count)
            for await (index, result) in group { results[index] = result }
            return results.compactMap { $0 }
        }
    }

    func run(_ call: ToolCall, allowed: Set<String>) async -> ToolResult {
        guard let tool = tool(named: call.tool) else {
            return ToolResult(id: call.id, ok: false, content: "No phone tool called \(call.tool).")
        }
        guard tool.spec.effect == .read else {
            return ToolResult(id: call.id, ok: false,
                              content: "\(call.tool) changes something, so Jan has to confirm it: put it in \"actions\" of your answer.")
        }
        guard allowed.contains(call.tool) else {
            return ToolResult(id: call.id, ok: false, content: "Jan doesn't share \(call.tool) with you.")
        }
        return await execute(tool, call.arguments, id: call.id)
    }

    /// Checks a suggested action: it must be a known action tool with valid arguments.
    public func proposal(for call: ToolCall) -> ProposedAction? {
        guard let tool = tool(named: call.tool), tool.spec.effect == .action,
              let arguments = try? tool.spec.validate(call.arguments)
        else { return nil }
        return ProposedAction(tool: call.tool, arguments: arguments, title: tool.title(for: arguments))
    }

    /// Runs an action you tapped.
    public func perform(_ action: ProposedAction) async -> ToolResult {
        guard let tool = tool(named: action.tool) else {
            return ToolResult(id: action.tool, ok: false, content: "No phone tool called \(action.tool).")
        }
        return await execute(tool, action.arguments.values, id: action.tool)
    }

    private func execute(_ tool: any PhoneTool, _ arguments: [String: JSONValue], id: String) async -> ToolResult {
        let validated: ToolArguments
        do {
            validated = try tool.spec.validate(arguments)
        } catch {
            return ToolResult(id: id, ok: false, content: error.localizedDescription)
        }
        let timeout = callTimeout
        return await withTaskGroup(of: ToolResult?.self) { group in
            group.addTask {
                do {
                    return ToolResult(id: id, ok: true, content: try await tool.run(validated))
                } catch {
                    return ToolResult(id: id, ok: false, content: error.localizedDescription)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return Task.isCancelled ? nil : ToolResult(id: id, ok: false, content: "\(tool.spec.name) took too long.")
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? ToolResult(id: id, ok: false, content: "\(tool.spec.name) was cancelled.")
        }
    }

    /// One line for the glasses while `calls` run: the tool's own line for one call, a general
    /// one for several.
    public func progress(for calls: [ToolCall]) -> String {
        let lines = Set(calls.compactMap { tool(named: $0.tool)?.spec.progress })
        return lines.count == 1 ? lines.first! : "Checking your phone…"
    }
}
