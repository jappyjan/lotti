import Foundation

/// One message of a chat completion.
public struct ChatMessage: Equatable, Sendable, Codable {
    public enum Role: String, Sendable, Codable { case system, user, assistant }
    public var role: Role
    public var content: String

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

/// Sends a whole conversation to Hermes and returns its reply text. `progress` gets Hermes's
/// own tool activity ("web_search") while it works.
public protocol HermesTransport: Sendable {
    func complete(_ messages: [ChatMessage], progress: @escaping @Sendable (String) -> Void) async throws -> String
}

/// Where your Hermes is: its API server (`hermes gateway` with `API_SERVER_ENABLED=true`).
public struct HermesConfig: Equatable, Sendable {
    /// e.g. `https://hermes.example.ts.net` or `http://192.168.1.20:8642`; with or without `/v1`.
    public var url: URL
    /// Hermes's `API_SERVER_KEY`.
    public var key: String

    public init(url: URL, key: String) {
        self.url = url
        self.key = key
    }

    /// Accepts what people paste: a missing scheme becomes `https://`, a trailing slash is dropped.
    public init?(address: String, key: String) {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !key.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        self.init(url: url, key: key)
    }

    /// `…/v1/<path>`, whether or not the address already ends in `/v1`.
    public func endpoint(_ path: String) -> URL {
        let base = url.path().hasSuffix("/v1") ? url : url.appending(path: "v1")
        return base.appending(path: path)
    }
}

public enum HermesError: Error, LocalizedError, Equatable {
    case notConfigured
    case http(Int, String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Hermes isn't set up."
        case .http(401, _), .http(403, _): "Hermes didn't accept the key."
        case .http(429, _): "Hermes is busy."
        case .http(let code, let message): "Hermes error \(code)" + (message.isEmpty ? "" : ": \(message)")
        case .empty: "Hermes sent an empty reply."
        }
    }
}

/// Talks to Hermes's OpenAI-compatible chat completions endpoint, streaming. Stateless: every
/// request carries the whole conversation, so the phone owns the history.
public struct HermesClient: HermesTransport {
    /// Read at every request, so settings changes apply right away. Nil when not set up.
    public var config: @Sendable () -> HermesConfig?
    public var session: URLSession

    public init(session: URLSession = HermesClient.defaultSession, config: @escaping @Sendable () -> HermesConfig?) {
        self.config = config
        self.session = session
    }

    /// Hermes sends a keepalive every 10 s while it works, so a minute of silence means it's gone.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    public func complete(_ messages: [ChatMessage], progress: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let config = config() else { throw HermesError.notConfigured }
        var request = URLRequest(url: config.endpoint("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        struct Body: Encodable {
            var model = "hermes-agent"
            var messages: [ChatMessage]
            var stream = true
        }
        request.httpBody = try JSONEncoder().encode(Body(messages: messages))

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard (200..<300).contains(status) else {
            throw HermesError.http(status, Self.errorMessage(try await Self.collect(bytes)))
        }
        // A server that ignores `stream` answers with one JSON object.
        if !type.contains("event-stream") {
            let body = try await Self.collect(bytes)
            guard let text = Self.messageContent(body), !text.isEmpty else { throw HermesError.empty }
            return text
        }
        var parser = ServerSentEvents()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch parser.feed(line) {
            case .progress(let text): progress(text)
            case .done: return try parser.finish()
            case nil: break
            }
        }
        return try parser.finish()
    }

    /// Checks address and key: lists the models (cheap, authenticated). Returns the model name.
    public func check() async throws -> String {
        guard let config = config() else { throw HermesError.notConfigured }
        var request = URLRequest(url: config.endpoint("models"))
        request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw HermesError.http(status, Self.errorMessage(String(decoding: data, as: UTF8.self)))
        }
        let json = try? JSONValue(json: String(decoding: data, as: UTF8.self))
        return json?["data"]?.array?.first?["id"]?.string ?? "Hermes"
    }

    static func collect(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return String(decoding: data, as: UTF8.self)
    }

    static func messageContent(_ body: String) -> String? {
        let json = try? JSONValue(json: body)
        return json?["choices"]?.array?.first?["message"]?["content"]?.string
    }

    static func errorMessage(_ body: String) -> String {
        let json = try? JSONValue(json: body)
        let message = json?["error"]?["message"]?.string ?? json?["error"]?.string ?? json?["detail"]?.string ?? body
        return String(message.prefix(120))
    }
}

/// Reads Hermes's stream line by line (blank lines may be skipped by the line reader, so each
/// `data:` line is handled on its own; an `event:` line names the next `data:` line).
struct ServerSentEvents {
    enum Signal: Equatable {
        case progress(String)
        case done
    }

    private(set) var text = ""
    private var event: String?

    mutating func feed(_ line: String) -> Signal? {
        if line.isEmpty { event = nil; return nil }
        if line.hasPrefix(":") { return nil }  // keepalive comment
        if line.hasPrefix("event:") {
            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return nil
        }
        guard line.hasPrefix("data:") else { return nil }
        let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        defer { event = nil }
        if data == "[DONE]" { return .done }
        guard let json = try? JSONValue(json: data) else { return nil }
        if let event, event != "message" {
            guard event.contains("progress") else { return nil }
            return Self.progressText(json).map(Signal.progress)
        }
        if let delta = json["choices"]?.array?.first?["delta"]?["content"]?.string {
            text += delta
        }
        return nil
    }

    func finish() throws -> String {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if reply.isEmpty { throw HermesError.empty }
        return reply
    }

    /// The progress event's fields aren't documented; take the first likely one.
    static func progressText(_ json: JSONValue) -> String? {
        for key in ["label", "message", "status", "tool", "name", "tool_name"] {
            if let text = json[key]?.string, !text.isEmpty { return text }
        }
        return json.string
    }
}
