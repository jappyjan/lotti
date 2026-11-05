import AuthenticationServices
import LottiKit
import SwiftUI

/// What a browser login hands back: `lotti://oauth?code=…&state=…` or, for a Google iOS client,
/// `com.googleusercontent.apps.<id>:/oauth2redirect?code=…&state=…` (or `error=…`).
struct OAuthCallback: Equatable {
    var code: String?
    var state: String?
    var error: String?

    init?(_ url: URL) {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        code = value("code")
        state = value("state")
        // The description when there is one, else the bare code ("access_denied" reads as "access denied").
        error = value("error_description") ?? value("error")?.replacingOccurrences(of: "_", with: " ")
        if code == nil && error == nil { return nil }
    }
}

enum OAuthFlow {
    /// The scheme the backend wants us to wait for (`callbackScheme` of the start answer; `lotti` by default).
    static func callbackScheme(_ start: JSONValue) -> String { start.text("callbackScheme") ?? "lotti" }

    /// The `code` and `state` to hand back to the backend, from the URL the browser returned.
    static func result(_ callback: URL, start: JSONValue) throws -> (code: String, state: String) {
        guard let result = OAuthCallback(callback) else { throw BackendError.badResponse }
        if let problem = result.error { throw BackendError.server(problem) }
        guard let code = result.code, let state = result.state ?? start.text("state") else { throw BackendError.badResponse }
        return (code, state)
    }

    /// Opens the login page the backend built and waits for the redirect. Nil: you closed the sheet.
    @MainActor static func authorize(start: JSONValue, using session: WebAuthenticationSession) async throws -> (code: String, state: String)? {
        guard let text = start.text("url"), let url = URL(string: text) else { throw BackendError.badResponse }
        do {
            let callback = try await session.authenticate(using: url, callbackURLScheme: callbackScheme(start))
            return try result(callback, start: start)
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            return nil  // nothing went wrong
        }
    }
}
