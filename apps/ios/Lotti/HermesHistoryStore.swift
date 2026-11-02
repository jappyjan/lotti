import Foundation
import LottiKit

/// Persists the Hermes conversation in UserDefaults as one JSON blob under a single key. The
/// protocol (`HermesHistoryStore`) keeps it swappable; UserDefaults is used so there is no file
/// lifecycle to manage, matching the other Settings.
struct UserDefaultsHermesHistoryStore: HermesHistoryStore {
    static let key = "hermesConversation"

    func load() throws -> PersistedHermesSession? {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return nil }
        return try JSONDecoder().decode(PersistedHermesSession.self, from: data)
    }

    func save(_ session: PersistedHermesSession) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(session), forKey: Self.key)
    }
}
