import Foundation

/// Decides who answers a question. Hermes first: when it's set up, every question goes to it —
/// it has the phone's tools, so the simple tasks work there too. The on-device brain answers
/// only when Hermes isn't set up, and the local brain hands back to Hermes on its own when a
/// question is beyond it.
public enum Router {
    public enum Route: Equatable, Sendable {
        /// The on-device brain answers.
        case local
        /// Hermes answers `question`.
        case hermes(String)
    }

    public static func route(_ question: String, hermesAvailable: Bool) -> Route {
        if let explicit = HermesRoute.explicitQuestion(question) { return .hermes(explicit) }
        return hermesAvailable ? .hermes(question) : .local
    }
}
