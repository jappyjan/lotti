import Foundation

/// A persisted Hermes conversation: the messages so far (system prompt first, then turns) and when
/// Jan last asked. The phone owns this history; Hermes itself stays stateless, and every request
/// carries the full conversation.
public struct PersistedHermesSession: Codable, Equatable, Sendable {
    /// System prompt first, then user/assistant turns.
    public var messages: [ChatMessage]
    /// When Jan last asked. Nil when there is nothing to continue.
    public var lastAsked: Date?

    public init(messages: [ChatMessage], lastAsked: Date? = nil) {
        self.messages = messages
        self.lastAsked = lastAsked
    }
}

/// Loads and saves the persisted Hermes conversation, so a follow-up works an hour later or after
/// an app restart. A nil store keeps the conversation in memory only (tests and live tests), which
/// keeps the persistence layer injectable and swappable.
public protocol HermesHistoryStore: Sendable {
    func load() throws -> PersistedHermesSession?
    func save(_ session: PersistedHermesSession) throws
}
