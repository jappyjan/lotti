import Foundation
import LottiKit

/// `lotti://pair?url=<server>&code=<code>`: what the QR code of Lotti Brain holds.
struct PairingLink: Equatable {
    var url: URL
    var code: String

    /// Reads a scanned or pasted link. Also takes `https://host/…?code=…` style text and a bare
    /// `url` + `code` pair is built by the caller. Nil if there is no server URL and code in it.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), components.scheme?.lowercased() == "lotti",
              components.host == "pair" || components.path == "/pair" || components.path == "pair"
        else { return nil }
        let query = Dictionary(components.queryItems?.compactMap { item in item.value.map { (item.name, $0) } } ?? [],
                               uniquingKeysWith: { first, _ in first })
        guard let server = query["url"], let url = BackendStore.normalizedURL(server),
              let code = query["code"]?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty
        else { return nil }
        self.url = url
        self.code = code
    }
}

/// Where Lotti Brain is and the token this phone got from pairing. The URL lives in
/// UserDefaults, the token in the Keychain.
struct BackendStore: @unchecked Sendable {
    static let urlKey = "backendURL"
    static let apnsKey = "apnsToken"
    static let tokenAccount = "backendDeviceToken"

    var defaults = UserDefaults.standard
    var keychain = Keychain()

    var url: URL? {
        get { defaults.string(forKey: Self.urlKey).flatMap(Self.normalizedURL) }
        nonmutating set { defaults.set(newValue?.absoluteString, forKey: Self.urlKey) }
    }

    var token: String? {
        get { keychain.string(Self.tokenAccount) }
        nonmutating set {
            if let newValue { keychain.set(newValue, for: Self.tokenAccount) } else { keychain.remove(Self.tokenAccount) }
        }
    }

    var apnsToken: String? {
        get { defaults.string(forKey: Self.apnsKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.apnsKey) }
    }

    var isPaired: Bool { url != nil && token != nil }

    func configuration(deviceName: String, appVersion: String) -> BackendConfiguration? {
        guard let url, let token else { return nil }
        return BackendConfiguration(baseURL: url, token: token, deviceName: deviceName, appVersion: appVersion, apnsToken: apnsToken)
    }

    func clear() {
        url = nil
        token = nil
    }

    /// "lotti.example.com:8787" → http://…; keeps a path-less base URL.
    static func normalizedURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty, ["http", "https"].contains(url.scheme) else { return nil }
        return url
    }
}
