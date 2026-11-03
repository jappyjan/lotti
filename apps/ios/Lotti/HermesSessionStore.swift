import Foundation
import LottiKit

/// Persists the id of the Hermes session in UserDefaults, matching the other Settings.
struct UserDefaultsHermesSessionStore: HermesSessionStore {
    static let key = "hermesSession"

    func load() throws -> String? {
        UserDefaults.standard.string(forKey: Self.key)
    }

    func save(_ id: String) throws {
        UserDefaults.standard.set(id, forKey: Self.key)
    }
}
