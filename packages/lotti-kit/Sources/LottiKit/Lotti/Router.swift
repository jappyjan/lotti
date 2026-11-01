import Foundation

/// Decides who answers a question. Hermes by default; the phone only for simple tasks its rules
/// recognise for sure, and as the fallback when Hermes is missing, failing or too slow.
public enum Router {
    public enum Route: Equatable, Sendable {
        /// The on-device brain answers.
        case local
        /// Hermes answers `question`. `fallback`: on errors or slowness the phone answers instead.
        case hermes(String, fallback: Bool)
    }

    /// Tasks the on-device brain handles reliably (the eval in LiveModelTests): one tool, clear
    /// arguments, a short answer.
    public static let localTools: Set<String> = [
        "weather", "set_timer", "create_reminder", "reminders", "calendar", "location", "directions",
    ]

    /// Tools that only know where Jan is now: "weather in Lisbon" isn't a job for them.
    static let hereOnly: Set<String> = ["weather", "directions"]

    /// "in Lissabon", "nach Berlin", "from Paris": a preposition and a capitalised name.
    static func namesAnotherPlace(_ question: String) -> Bool {
        question.contains(try! Regex(#"\b(in|im|nach|für|for|at|bei|from|von) [A-ZÄÖÜ][\wäöüß-]+"#))
    }

    public static func route(_ question: String, hermesAvailable: Bool) -> Route {
        // You asked for Hermes: no fallback, it may take its time.
        if let explicit = HermesRoute.explicitQuestion(question) { return .hermes(explicit, fallback: false) }
        let ruled = LocalPipeline.ruleTools(question, names: localTools)
        if let ruled, !ruled.isEmpty, Set(ruled).isSubset(of: localTools),
           !(Set(ruled).isSubset(of: hereOnly) && namesAnotherPlace(question)) {
            return .local
        }
        guard hermesAvailable else { return .local }
        // Only Hermes can know these (news, prices, opening hours): the phone can't stand in.
        if ruled == ["hermes"] { return .hermes(question, fallback: false) }
        return .hermes(question, fallback: true)
    }
}
