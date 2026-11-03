import Foundation

/// Sends HTTP requests. `URLSession` does it in the app; tests answer from memory.
public protocol BackendHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTP: BackendHTTP {
    public var session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendError.badResponse }
        return (data, http)
    }
}

/// One operation of the management API (`GET /api/v1/ops`).
public struct BackendOp: Equatable, Sendable {
    public enum Risk: String, Sendable {
        /// Runs without asking.
        case free
        /// The agent proposes it and you tap; from the app it runs directly.
        case tap
        /// Credentials and the like: only on this HTTP API, never in the agent or MCP.
        case appOnly = "app_only"
    }

    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var risk: Risk
    public var group: String
}

/// The management API (docs/protocol.md "Management API"): one operations layer behind
/// `/api/v1/ops`, which the app's screens (status, providers, accounts, jobs, memory, skills,
/// privacy log, settings, inbox …) call over HTTP. The same operations are the agent's admin tools.
///
/// It is generic on purpose: `call(_:_:)` takes and returns `JSONValue`, and `listOps()` says
/// what exists, so a screen can be built from the op list. The typed wrappers below cover what
/// the app needs often; check names against `listOps()` (the backend's README is the authority).
public struct BackendManagementClient: Sendable {
    public var baseURL: URL
    /// The device token; nil before pairing.
    public var token: String?
    public var http: any BackendHTTP

    public init(baseURL: URL, token: String? = nil, http: any BackendHTTP = URLSessionHTTP()) {
        self.baseURL = baseURL
        self.token = token
        self.http = http
    }

    public init(configuration: BackendConfiguration, http: any BackendHTTP = URLSessionHTTP()) {
        self.init(baseURL: configuration.baseURL, token: configuration.token, http: http)
    }

    // MARK: Pairing and health

    /// `GET /health` (no auth).
    public func health() async -> Bool {
        guard let (data, response) = try? await send("GET", "health", auth: false), response.statusCode == 200 else { return false }
        return (try? JSONValue(json: String(decoding: data, as: UTF8.self)))?["ok"] == .bool(true)
    }

    /// `POST /api/v1/pair`: trades the single-use code printed at the backend's first start for
    /// this phone's device token. Keep the token in the Keychain.
    public func pair(code: String, deviceName: String) async throws -> String {
        let body: JSONValue = ["code": .string(code.trimmingCharacters(in: .whitespacesAndNewlines)), "deviceName": .string(deviceName)]
        let (data, response) = try await send("POST", "api/v1/pair", body: body, auth: false)
        let json = try decode(data, response)
        guard let token = json["token"]?.string else { throw BackendError.badResponse }
        return token
    }

    // MARK: Operations

    /// `GET /api/v1/ops`.
    public func listOps() async throws -> [BackendOp] {
        let (data, response) = try await send("GET", "api/v1/ops")
        let json = try decode(data, response)
        let list = json.array ?? json["ops"]?.array ?? json["result"]?.array ?? []
        return list.compactMap { op in
            guard let name = op["name"]?.string else { return nil }
            return BackendOp(name: name, description: op["description"]?.string ?? "", inputSchema: op["inputSchema"] ?? .null,
                             risk: op["risk"]?.string.flatMap(BackendOp.Risk.init(rawValue:)) ?? .tap, group: op["group"]?.string ?? "")
        }
    }

    /// `POST /api/v1/ops/<name>` with `input`: returns `result`, or throws `.server(error)`.
    public func call(_ op: String, _ input: JSONValue = [:]) async throws -> JSONValue {
        let (data, response) = try await send("POST", "api/v1/ops/\(op)", body: input)
        let json = try decode(data, response)
        guard json["ok"] == .bool(true) else { throw BackendError.server(json["error"]?.string ?? "The operation failed.") }
        return json["result"] ?? .null
    }

    // MARK: Typed wrappers
    //
    // Names and inputs match apps/brain/src/ops (check `listOps()` for the full list). Where the
    // app uses each:
    // - `status()` → status screen (connection, providers, versions, the "Lotti Brain" row)
    // - `inboxList()` / `dismissInboxItem(_:)` → the phone's inbox list, kept in step with the glasses
    // - `settings()` / `setting(_:)` / `setSetting(_:_:)` → settings screen (catch-up, active provider, …)
    // - `locationLog()` → "where did Lotti read my location" (privacy) screen
    // - `conversations()` → chat history
    // - `pushStatus()` → whether pushes can wake the app (APNs configured, this device's token known).
    //   The APNs token itself rides in the socket's `hello`; there is no op for it.
    // Everything else (providers, accounts, Bring!, MCP, jobs, memory, skills, scripts, dreaming,
    // admin token) goes through `call(_:_:)` with the op's schema from `listOps()`.

    public func status() async throws -> JSONValue { try await call(BackendOps.status) }

    /// Open items (pending and seen) by default.
    public func inboxList(status: String = "open", limit: Int = 50) async throws -> [InboxItem] {
        let result = try await call(BackendOps.inboxList, ["status": .string(status), "limit": .number(Double(limit))])
        return (result.array ?? result["items"]?.array ?? []).compactMap(BackendActions.decodeItem)
    }

    public func dismissInboxItem(_ id: String) async throws { _ = try await call(BackendOps.inboxDismiss, ["id": .string(id)]) }

    /// Every setting with its value, default and description.
    public func settings() async throws -> JSONValue { try await call(BackendOps.settingsList) }
    public func setting(_ key: String) async throws -> JSONValue { try await call(BackendOps.settingsGet, ["key": .string(key)]) }
    /// Changes a non-safety setting. Safety settings need `settings.set_safety` through `call`.
    public func setSetting(_ key: String, _ value: JSONValue) async throws {
        _ = try await call(BackendOps.settingsSet, ["key": .string(key), "value": value])
    }

    public func locationLog(limit: Int = 50) async throws -> JSONValue {
        try await call(BackendOps.privacyLocationLog, ["limit": .number(Double(limit))])
    }

    public func conversations(limit: Int = 20) async throws -> JSONValue {
        try await call(BackendOps.conversationsList, ["limit": .number(Double(limit))])
    }

    public func pushStatus() async throws -> JSONValue { try await call(BackendOps.pushStatus) }

    // MARK: HTTP

    private func send(_ method: String, _ path: String, body: JSONValue? = nil, auth: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        if auth {
            guard let token else { throw BackendError.notConfigured }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.json.utf8)
        }
        return try await http.send(request)
    }

    private func decode(_ data: Data, _ response: HTTPURLResponse) throws -> JSONValue {
        let json = try? JSONValue(json: String(decoding: data, as: UTF8.self))
        guard (200..<300).contains(response.statusCode) else {
            throw BackendError.http(response.statusCode, json?["error"]?.string ?? json?["message"]?.string ?? "")
        }
        guard let json else { throw BackendError.badResponse }
        return json
    }
}

/// Operation names the typed wrappers call (apps/brain/src/ops).
public enum BackendOps {
    public static let status = "status.get"
    public static let inboxList = "inbox.list"
    public static let inboxDismiss = "inbox.dismiss"
    public static let settingsList = "settings.list"
    public static let settingsGet = "settings.get"
    public static let settingsSet = "settings.set"
    public static let privacyLocationLog = "privacy.location_log"
    public static let conversationsList = "conversations.list"
    public static let pushStatus = "push.status"
}
