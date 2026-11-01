import Foundation

/// The eval set: real-looking notifications and requests plus loose expectations.
/// Stored as JSON (`Fixtures/s3-eval.json`) so other tools (the web simulator, Hermes) can reuse it.
public struct EvalSet: Codable, Sendable {
    public var version: Int
    public var about: String?
    public var user: User
    public var cases: [EvalCase]

    public struct User: Codable, Sendable {
        public var name: String
        public var city: String
        /// Messages the user wrote to each person, for "replies in my own style".
        public var style: [String: [String]]
    }

    /// The set that ships with this package.
    public static func bundled() throws -> EvalSet {
        guard let url = Bundle.module.url(forResource: "s3-eval", withExtension: "json", subdirectory: "Fixtures")
        else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode(EvalSet.self, from: Data(contentsOf: url))
    }
}

public enum EvalTask: String, Codable, Sendable, CaseIterable {
    case triage, summary, rail, reply, screen, tool
}

public struct EvalCase: Codable, Sendable, Identifiable {
    public var id: String
    public var task: EvalTask
    /// Wall-clock context, e.g. "Fri 19:40".
    public var now: String
    /// The language Lotti should answer in (summary, rail, reply).
    public var language: String?
    public var event: Event?
    public var utterance: String?
    /// What the user wants to say (reply task).
    public var intent: String?
    /// Memories relevant to this event.
    public var memory: [String]?
    /// Extra facts the screen task may use (calendar, weather, what's on screen).
    public var context: [String]?
    public var expect: CaseExpectation

    public struct Event: Codable, Sendable {
        public var app: String
        public var from: String
        public var text: String
    }
}

/// Loose, machine-checkable expectations. Text matches are case-insensitive substrings;
/// `a|b` means either.
public struct CaseExpectation: Codable, Sendable {
    public var priority: Priority?
    public var alsoOK: [Priority]?
    /// Every entry must appear in the output.
    public var mentions: [String]?
    /// Every entry must appear in at least one choice (rail).
    public var mentionsAny: [String]?
    /// None of these may appear.
    public var avoid: [String]?
    public var maxWords: Int?
    public var templates: [Template]?
    public var tool: ToolExpectation?
    public var noTool: Bool?

    public struct ToolExpectation: Codable, Sendable {
        public var name: String
        /// Argument name → expected substring (`a|b` alternatives).
        public var args: [String: String]
    }
}

public enum Priority: String, Codable, Sendable, CaseIterable {
    case quiet, normal, urgent
}

/// The building blocks from docs/design.md.
public enum Template: String, Codable, Sendable, CaseIterable {
    case lottiSays, proposal, original, list, reading, working, card, done
}
