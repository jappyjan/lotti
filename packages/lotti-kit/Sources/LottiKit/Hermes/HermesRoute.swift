import Foundation

/// The rules tier of the router: questions that go to Hermes without asking the on-device brain.
public enum HermesRoute {
    /// Openers that mean "this is for Hermes". Matched at the start, case-insensitively.
    static let openers = [
        "ask hermes", "hey hermes", "hermes", "frag hermes", "frage hermes", "frag mal hermes",
    ]
    /// Openers that mean "research this", sent to Hermes as they are.
    static let research = ["dig into", "look into", "research", "recherchiere", "find heraus", "finde heraus"]

    /// Phrases that mean "forget this conversation and start fresh". Matched whole and
    /// case-insensitively, so "reset my timer" still reaches Hermes.
    static let resets = germanResets + ["new chat", "new conversation", "start over", "reset"]

    /// The German reset phrases, so the confirmation matches what you said.
    static let germanResets = ["neues gespräch", "neuer chat", "neue unterhaltung", "neu anfangen"]

    /// The question to send to Hermes if `text` asks for Hermes explicitly, else nil.
    /// "Hermes, what's new in Swift 7?" → "what's new in Swift 7?"; "Dig into X" → "Dig into X".
    public static func explicitQuestion(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for opener in research where lower.hasPrefix(opener + " ") {
            return trimmed
        }
        for opener in openers.sorted(by: { $0.count > $1.count }) where lower.hasPrefix(opener) {
            let rest = trimmed.dropFirst(opener.count)
            // "Hermesbrief" is not "Hermes, …".
            guard rest.isEmpty || rest.first!.isWhitespace || rest.first!.isPunctuation else { continue }
            let question = String(rest.drop { $0.isWhitespace || $0.isPunctuation })
            return question.isEmpty ? nil : question
        }
        return nil
    }

    /// True when `text` is a reset phrase ("Neues Gespräch" / "new chat"), matched whole and
    /// case-insensitively, ignoring leading/trailing whitespace and punctuation.
    public static func resetRequest(_ text: String) -> Bool {
        resetPhrase(text) != nil
    }

    /// The short confirmation line for a reset phrase, in the phrase's language.
    public static func resetConfirmation(_ text: String) -> String {
        germanResets.contains(resetPhrase(text) ?? "") ? "Neues Gespräch." : "New conversation."
    }

    private static func resetPhrase(_ text: String) -> String? {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return resets.contains(normalized) ? normalized : nil
    }
}
