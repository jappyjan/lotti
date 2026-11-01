#if canImport(FoundationModels)
import FoundationModels

// Guided-generation types per task. Field order matters: models generate top to bottom.

@available(iOS 27.0, macOS 27.0, *)
@Generable enum PriorityChoice: String {
    case quiet, normal, urgent
}

@available(iOS 27.0, macOS 27.0, *)
@Generable struct TriageOutput {
    @Guide(description: "A few words on why")
    var reason: String
    var priority: PriorityChoice
}

@available(iOS 27.0, macOS 27.0, *)
@Generable struct SummaryOutput {
    @Guide(description: "One sentence, at most 20 words")
    var sentence: String
}

@available(iOS 27.0, macOS 27.0, *)
@Generable struct RailOutput {
    @Guide(description: "1 to 3 choices, each 1 to 3 words, best guess first", .maximumCount(3))
    var choices: [String]
}

@available(iOS 27.0, macOS 27.0, *)
@Generable struct ReplyOutput {
    @Guide(description: "The message exactly as Jan would send it")
    var message: String
}

@available(iOS 27.0, macOS 27.0, *)
@Generable enum TemplateChoice: String {
    case lottiSays, proposal, original, list, card, done
}

@available(iOS 27.0, macOS 27.0, *)
@Generable struct ScreenOutput {
    var template: TemplateChoice
    var priority: PriorityChoice
    @Guide(description: "Lotti's sentence; for proposal and original the exact message text")
    var text: String
    @Guide(description: "List items or card facts, one line each; empty for other templates", .maximumCount(6))
    var lines: [String]
    @Guide(description: "Choices in the rail, each 1 to 3 words", .maximumCount(4))
    var choices: [String]
}

@available(iOS 27.0, macOS 27.0, *)
extension TriageOutput {
    var output: CaseOutput { CaseOutput(priority: Priority(rawValue: priority.rawValue), reason: reason) }
}

@available(iOS 27.0, macOS 27.0, *)
extension ScreenOutput {
    var output: CaseOutput {
        let body = ([text] + lines).joined(separator: "\n")
        return CaseOutput(
            priority: Priority(rawValue: priority.rawValue), text: body, choices: choices,
            template: Template(rawValue: template.rawValue))
    }
}
#endif
