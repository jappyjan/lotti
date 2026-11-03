import Foundation

/// Loads and saves the id of the Hermes session Lotti continues (`X-Hermes-Session-Id`), so a
/// follow-up works a day later or after an app restart. Hermes keeps the history itself; the phone
/// only remembers the id. A nil store keeps it in memory only (tests and live tests).
public protocol HermesSessionStore: Sendable {
    func load() throws -> String?
    func save(_ id: String) throws
}
