import Foundation

/// What Hermes said back, in Lotti's reply format.
public enum HermesReply: Equatable, Sendable {
    /// Hermes wants facts from the phone. All calls run at the same time.
    case calls([ToolCall], status: String?)
    /// Hermes is done.
    case answer(sentence: String, followUps: [String], actions: [ToolCall])
}

/// Lotti's protocol on top of Hermes's chat API. Hermes runs its own tools on its server and
/// can't take client tools, so phone tools travel inside the conversation as JSON:
///
/// Hermes → phone, needs facts (several calls at once):
/// `{"type":"call","status":"Checking your calendar","calls":[{"id":"c1","tool":"calendar","args":{…}}, …]}`
///
/// Phone → Hermes, the results:
/// `{"type":"results","results":[{"id":"c1","ok":true,"content":"…"}, …]}`
///
/// Hermes → phone, done:
/// `{"type":"answer","sentence":"…","followUps":["…"],"actions":[{"tool":"set_timer","args":{…}}]}`
///
/// Actions are never run by Hermes: they show up as choices on the glasses and run when you tap.
public enum HermesFormat {
    /// The system message for a Hermes conversation. Hermes layers it on top of its own prompt.
    /// `reads` are the read tools Hermes may call, `actions` the ones it may suggest.
    public static func instructions(reads: [PhoneToolSpec], actions: [PhoneToolSpec]) -> String {
        var lines = [
            "You are answering as Lotti, the assistant on Jan's smart glasses. Jan lives in Berlin.",
            "Brief, warm, a bit curious. Jan speaks to you; his words come from speech-to-text, so guess what he meant.",
            "Use your own tools (web, research, memory, …) as usual. Jan's phone also has tools, listed below.",
            "",
            "Reply with exactly one JSON object and nothing else, no markdown fences. Two kinds:",
            "",
            "1. You need facts from Jan's phone:",
            #"{"type":"call","status":"Checking your calendar","calls":[{"id":"c1","tool":"calendar","args":{"from":"2026-11-02"}},{"id":"c2","tool":"weather","args":{}}]}"#,
            "Put every phone call you need into one reply: they run at the same time. \"status\" is a few words shown while they run.",
            #"The phone replies with {"type":"results","results":[{"id":"c1","ok":true,"content":"…"}]}. Then call again or answer."#,
            "",
            "2. Your answer:",
            #"{"type":"answer","sentence":"…","followUps":["…"],"actions":[{"tool":"set_timer","args":{"minutes":10,"label":"Pasta"}}]}"#,
            "- sentence: what Lotti says, one or two short sentences, at most 30 words. The display is tiny. Plain text: no lists, no markdown, no emoji, no links.",
            "- Use the language of Jan's message, even if your facts are in another language.",
            "- followUps: up to 3 things Jan might ask next, each 1 to 3 words, in his language.",
            "- actions: up to 2 phone actions Jan can confirm with one tap. Never say they are done; say what you prepared.",
        ]
        lines.append("")
        if reads.isEmpty {
            lines.append("Phone tools you may call: none.")
        } else {
            lines.append("Phone tools you may call (in \"calls\"):")
            lines += reads.map(describe)
        }
        if !actions.isEmpty {
            lines.append("Phone actions you may suggest (only in \"actions\", Jan confirms them):")
            lines += actions.map(describe)
        }
        return lines.joined(separator: "\n")
    }

    /// `- calendar(from: string, days?: integer): Jan's calendar events. from: first day, YYYY-MM-DD; …`
    static func describe(_ spec: PhoneToolSpec) -> String {
        let signature = spec.parameters.map { "\($0.name)\($0.isOptional ? "?" : ""): \($0.typeName)" }.joined(separator: ", ")
        var line = "- \(spec.name)(\(signature)): \(spec.description)"
        let notes = spec.parameters.filter { !$0.description.isEmpty }.map { "\($0.name): \($0.description)" }
        if !notes.isEmpty { line += " " + notes.joined(separator: "; ") + "." }
        return line
    }

    /// The first user message of a conversation, or a follow-up.
    public static func question(_ text: String, context: String?) -> String {
        guard let context, !context.isEmpty else { return "Jan: \(text)" }
        return "\(context)\n\nJan: \(text)"
    }

    /// The phone's reply to a `call`. `final` tells Hermes to stop calling and answer.
    public static func results(_ results: [ToolResult], final: Bool = false) -> String {
        var object: [String: JSONValue] = [
            "type": "results",
            "results": .array(results.map { ["id": .string($0.id), "ok": .bool($0.ok), "content": .string($0.content)] }),
        ]
        if final { object["note"] = "No more phone calls. Answer now with what you have." }
        return JSONValue.object(object).json
    }

    /// The phone's reply when Hermes didn't use the format.
    public static let formatReminder = #"Lotti couldn't read that. Reply with one JSON object only: {"type":"answer",…} or {"type":"call",…}."#

    /// Reads Hermes's reply. Forgiving: finds the JSON object inside fences or prose, accepts
    /// `args` or `arguments`, numbers missing call ids. Returns nil if there is no usable JSON,
    /// so the caller can show the text as it is.
    public static func parse(_ text: String) -> HermesReply? {
        guard let object = jsonObject(in: text) else { return nil }
        let type = object["type"]?.string?.lowercased()
        if type == "call" || type == "calls" || (type == nil && object["calls"] != nil) {
            let calls = (object["calls"]?.array ?? []).enumerated().compactMap { index, value -> ToolCall? in
                guard let tool = (value["tool"] ?? value["name"])?.string else { return nil }
                let arguments = (value["args"] ?? value["arguments"])?.object ?? [:]
                return ToolCall(id: value["id"]?.string ?? "c\(index + 1)", tool: tool, arguments: arguments)
            }
            guard !calls.isEmpty else { return nil }
            let status = object["status"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return .calls(calls, status: status)
        }
        guard let sentence = (object["sentence"] ?? object["text"])?.string, !sentence.isEmpty else { return nil }
        let followUps = (object["followUps"] ?? object["follow_ups"])?.array?.compactMap(\.string) ?? []
        let actions = (object["actions"]?.array ?? []).enumerated().compactMap { index, value -> ToolCall? in
            guard let tool = (value["tool"] ?? value["name"])?.string else { return nil }
            return ToolCall(id: "a\(index + 1)", tool: tool, arguments: (value["args"] ?? value["arguments"])?.object ?? [:])
        }
        return .answer(sentence: sentence, followUps: followUps, actions: actions)
    }

    /// The outermost `{…}` in `text` that parses as a JSON object.
    static func jsonObject(in text: String) -> JSONValue? {
        if let value = try? JSONValue(json: text), value.object != nil { return value }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        guard let value = try? JSONValue(json: String(text[start...end])), value.object != nil else { return nil }
        return value
    }

    /// Plain text from a reply that wasn't JSON: no fences, no markdown emphasis, first ~40 words.
    public static func plainSentence(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = cleaned.split(separator: " ", omittingEmptySubsequences: true)
        return words.count <= 40 ? words.joined(separator: " ") : words.prefix(40).joined(separator: " ") + " …"
    }
}

extension ToolParameter {
    var typeName: String {
        switch kind {
        case .string: "string"
        case .integer: "integer"
        case .number: "number"
        case .boolean: "boolean"
        case .oneOf(let choices): choices.map { "\"\($0)\"" }.joined(separator: "|")
        }
    }
}
