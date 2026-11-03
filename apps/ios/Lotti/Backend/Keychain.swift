import Foundation
import Security

/// Holds secrets in memory instead of the Keychain. Unit tests use it: the unsigned test host that
/// runs on CI has no Keychain entitlement, so `SecItem*` fails there.
final class MemorySecrets: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func get(_ key: String) -> String? { lock.withLock { values[key] } }
    func set(_ value: String?, for key: String) { lock.withLock { values[key] = value } }
}

/// A tiny Keychain wrapper for the device token (generic password items, this device only).
struct Keychain: Sendable {
    var service = "de.janjaap.lotti"
    /// Set in tests only.
    var memory: MemorySecrets?

    func string(_ account: String) -> String? {
        if let memory { return memory.get(account) }
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func set(_ value: String, for account: String) -> Bool {
        if let memory {
            memory.set(value, for: account)
            return true
        }
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(base(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func remove(_ account: String) {
        if let memory {
            memory.set(nil, for: account)
            return
        }
        SecItemDelete(base(account) as CFDictionary)
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
