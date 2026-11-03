import Foundation

/// The offline brain without a model: rules and parsers only. It handles what matters when the
/// backend can't be reached, and runs on any device, with or without Apple Intelligence:
/// - timers and navigation (most important): arguments come from the words (`OfflineIntents`),
///   the answer is a prepared action you tap;
/// - a new reminder, when the words say what and optionally when;
/// - reading the reminder list and the local calendar: the tool's own text is the answer;
/// - everything else: one short "I'm offline" sentence in the question's language.
@MainActor
public final class OfflineBrain: Brain {
    private let toolbox: Toolbox

    public init(tools: Toolbox = Toolbox()) {
        self.toolbox = tools
    }

    public func prewarm() {}
    public func endConversation() {}

    public func answer(_ message: String, context: String, status: @escaping @MainActor (String) -> Void) async throws -> Answer {
        let language = LocalPipeline.language(of: message)
        let names = Set(toolbox.specs.map(\.name))
        guard case .tools(let picked)? = LocalPipeline.offlinePlan(message, names: names) else {
            return Answer(sentence: LocalPipeline.offlineSentence(language: language))
        }

        // Actions first: a timer or a destination you can tap.
        var prepared: [ProposedAction] = []
        for name in picked where toolbox.tool(named: name)?.spec.effect == .action {
            guard let arguments = OfflineIntents.arguments(for: name, message: message) else {
                let what = name == "set_timer" ? "timer" : name == "start_navigation" ? "navigation" : "reminder"
                return Answer(sentence: LocalPipeline.missingSentence(what, language: language))
            }
            guard let proposal = toolbox.proposal(for: ToolCall(id: name, tool: name, arguments: arguments)) else {
                return Answer(sentence: LocalPipeline.offlineSentence(language: language))
            }
            prepared.append(proposal)
        }
        if !prepared.isEmpty {
            return Answer(sentence: LocalPipeline.preparedSentence(prepared, language: language), actions: prepared)
        }

        // Reads: the reminder list and the calendar, as the tools word them.
        let reads = picked.map { ToolCall(id: $0, tool: $0, arguments: [:]) }
        status(toolbox.progress(for: reads))
        let results = await toolbox.run(reads, allowed: Set(picked))
        let lines = results.map { $0.ok ? $0.content : (language == "German" ? "Nicht verfügbar." : "Not available.") }
        return Answer(sentence: String(lines.joined(separator: "\n").prefix(220)))
    }
}
