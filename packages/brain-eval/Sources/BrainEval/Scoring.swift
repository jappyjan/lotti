import Foundation
import NaturalLanguage

/// What a model produced for one case, flattened so it can be scored and logged as JSON.
public struct CaseOutput: Codable, Sendable, Equatable {
    public var priority: Priority?
    public var reason: String?
    public var text: String?
    public var choices: [String]?
    public var template: Template?
    public var toolCalls: [ToolCall]?

    public struct ToolCall: Codable, Sendable, Equatable {
        public var name: String
        /// The arguments as the model produced them (JSON).
        public var arguments: String
        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    public init(
        priority: Priority? = nil, reason: String? = nil, text: String? = nil, choices: [String]? = nil,
        template: Template? = nil, toolCalls: [ToolCall]? = nil
    ) {
        self.priority = priority
        self.reason = reason
        self.text = text
        self.choices = choices
        self.template = template
        self.toolCalls = toolCalls
    }
}

/// One named check and whether it passed.
public struct Check: Codable, Sendable, Equatable {
    public var name: String
    public var passed: Bool
    public var detail: String?
}

public enum Scoring {
    public static func checks(for evalCase: EvalCase, output: CaseOutput) -> [Check] {
        let expect = evalCase.expect
        var checks: [Check] = []
        let allText = ([output.text] + (output.choices ?? []).map(Optional.some)).compactMap { $0 }.joined(separator: " ")

        if let priority = expect.priority {
            let allowed = [priority] + (expect.alsoOK ?? [])
            checks.append(Check(
                name: "priority", passed: output.priority.map(allowed.contains) ?? false,
                detail: output.priority == priority ? nil : "expected \(priority.rawValue)"))
        }
        if let language = evalCase.language, evalCase.task != .tool {
            let detected = detectLanguage(allText)
            checks.append(Check(name: "language", passed: detected == language, detail: detected))
        }
        if let mentions = expect.mentions {
            let missing = mentions.filter { !contains(allText, $0) }
            checks.append(Check(name: "mentions", passed: missing.isEmpty, detail: missing.isEmpty ? nil : "missing \(missing)"))
        }
        if let groups = expect.mentionsAny {
            let choices = output.choices ?? []
            let missing = groups.filter { group in !choices.contains { contains($0, group) } }
            checks.append(Check(name: "mentionsAny", passed: missing.isEmpty, detail: missing.isEmpty ? nil : "missing \(missing)"))
        }
        if let avoid = expect.avoid {
            let found = avoid.filter { allText.localizedCaseInsensitiveContains($0) }
            checks.append(Check(name: "avoid", passed: found.isEmpty, detail: found.isEmpty ? nil : "found \(found)"))
        }
        if let maxWords = expect.maxWords {
            let words = wordCount(output.text ?? "")
            checks.append(Check(name: "maxWords", passed: words > 0 && words <= maxWords, detail: "\(words)"))
        }
        if evalCase.task == .rail {
            let choices = output.choices ?? []
            let tooLong = choices.filter { wordCount($0) > 4 }
            checks.append(Check(
                name: "railShape", passed: (1...3).contains(choices.count) && tooLong.isEmpty,
                detail: "\(choices.count) choices" + (tooLong.isEmpty ? "" : ", too long: \(tooLong)")))
        }
        if let templates = expect.templates {
            checks.append(Check(
                name: "template", passed: output.template.map(templates.contains) ?? false,
                detail: output.template?.rawValue))
        }
        if let tool = expect.tool {
            checks.append(toolCheck(tool, calls: output.toolCalls ?? []))
        }
        if expect.noTool == true {
            let calls = output.toolCalls ?? []
            checks.append(Check(name: "noTool", passed: calls.isEmpty, detail: calls.map(\.name).joined(separator: ",")))
        }
        return checks
    }

    static func toolCheck(_ expected: CaseExpectation.ToolExpectation, calls: [CaseOutput.ToolCall]) -> Check {
        guard let call = calls.first(where: { $0.name == expected.name }) else {
            return Check(name: "tool", passed: false, detail: "called \(calls.map(\.name))")
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        let wrong = expected.args.filter { name, pattern in
            guard let value = args[name] else { return true }
            return !contains("\(value)", pattern)
        }
        return Check(name: "tool", passed: wrong.isEmpty, detail: wrong.isEmpty ? nil : "args \(call.arguments)")
    }

    /// Case-insensitive substring match; `a|b` matches either.
    static func contains(_ text: String, _ pattern: String) -> Bool {
        pattern.split(separator: "|").contains { text.localizedCaseInsensitiveContains($0) }
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// "de", "en", … or "?" if unsure.
    static func detectLanguage(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.german, .english]
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "?"
    }
}
