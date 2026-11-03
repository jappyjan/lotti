import Foundation

/// Decides who answers a question: the backend whenever it can be reached, the on-device offline
/// brain otherwise. The offline brain is narrow (timers, navigation, reminders, the local day;
/// everything else gets a short offline sentence), so a reachable backend always wins.
public enum Router {
    public enum Route: Equatable, Sendable {
        /// Lotti Brain answers.
        case backend
        /// The offline brain answers.
        case offline
    }

    public static func route(backendReachable: Bool) -> Route {
        backendReachable ? .backend : .offline
    }
}
