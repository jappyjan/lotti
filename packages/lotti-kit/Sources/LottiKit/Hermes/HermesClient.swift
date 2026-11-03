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

/// Sends the newest message to Hermes and returns its reply text. `session` is sent as
/// `X-Hermes-Session-Id`: Hermes keeps the history. `progress` gets Hermes's own tool activity
/// ("web_search") while it works.
public protocol HermesTransport: Sendable {
    func complete(_ messages: [ChatMessage], session: String, progress: @escaping @Sendable (String) -> Void) async throws -> String
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
    /// Hermes no longer has the session (deleted in its dashboard) or can't continue it.
    case sessionGone
    /// The question waited in the session's queue and never started: an earlier turn is stuck
    /// (say, Hermes restarted mid-question and paused the session).
    case sessionStuck

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Hermes isn't set up."
        case .http(401, _), .http(403, _): "Hermes didn't accept the key."
        case .http(429, _): "Hermes is busy."
        case .http(let code, let message): "Hermes error \(code)" + (message.isEmpty ? "" : ": \(message)")
        case .empty: "Hermes sent an empty reply."
        case .sessionGone: "Hermes lost our conversation."
        case .sessionStuck: "Hermes's conversation got stuck."
        }
    }
}

/// Talks to Hermes's OpenAI-compatible chat completions endpoint, streaming. With the
/// `X-Hermes-Session-Id` header Hermes loads the session's history itself and treats only the last
/// message of the body as new, so a request is the system prompt plus the newest message. A Hermes
/// without that header support (no `session_continuity_header` in `/v1/capabilities`) answers
/// without memory of earlier questions, and phone-tool rounds lose their question.
public struct HermesClient: HermesTransport {
    /// Read at every request, so settings changes apply right away. Nil when not set up.
    public var config: @Sendable () -> HermesConfig?
    public var session: URLSession
    /// A cancelled question that waited this long without starting was stuck behind another turn.
    public var stuckAfter: TimeInterval

    public init(session: URLSession = HermesClient.defaultSession, stuckAfter: TimeInterval = 10,
                config: @escaping @Sendable () -> HermesConfig?) {
        self.config = config
        self.session = session
        self.stuckAfter = stuckAfter
    }

    /// Hermes sends a keepalive every 10 s while it works, so a minute of silence means it's gone.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    public func complete(_ messages: [ChatMessage], session id: String, progress: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let config = config() else { throw HermesError.notConfigured }
        var request = URLRequest(url: config.endpoint("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(id, forHTTPHeaderField: "X-Hermes-Session-Id")
        struct Body: Encodable {
            var model = "hermes-agent"
            var messages: [ChatMessage]
            var stream = true
        }
        request.httpBody = try JSONEncoder().encode(Body(messages: messages))

        // Hermes keeps a turn running after its client goes away, and the session's next question
        // would queue behind it. So the stream runs in its own task, and a cancelled question first
        // asks Hermes to stop its run (the completion id is the run id while the stream is open),
        // then closes the stream.
        let run = Run()
        let stream = Task { try await read(request, run: run, progress: progress) }
        return try await withTaskCancellationHandler {
            do {
                return try await stream.value
            } catch {
                if run.stuck { throw HermesError.sessionStuck }
                throw error
            }
        } onCancel: {
            Task {
                await stop(run, config: config)
                stream.cancel()
            }
        }
    }

    private func read(_ request: URLRequest, run: Run, progress: @escaping @Sendable (String) -> Void) async throws -> String {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard (200..<300).contains(status) else {
            let body = try await Self.collect(bytes)
            if Self.sessionGoneReasons.contains(Self.errorCode(body) ?? "") { throw HermesError.sessionGone }
            throw HermesError.http(status, Self.errorMessage(body))
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
            let signal = parser.feed(line)
            run.update(id: parser.completionID, started: !parser.text.isEmpty)
            switch signal {
            case .progress(let text): progress(text)
            case .done: return try parser.finish()
            case nil: break
            }
        }
        return try parser.finish()
    }

    /// Best effort, bounded: a question cancelled before its run is known just closes the stream.
    /// A run Hermes hadn't started after `stuckAfter` means the session is stuck.
    private func stop(_ run: Run, config: HermesConfig) async {
        guard let id = run.id else { return }
        var request = URLRequest(url: config.endpoint("runs/\(id)/stop"), timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await session.data(for: request) else { return }
        let json = try? JSONValue(json: String(decoding: data, as: UTF8.self))
        // "stopping" is a run that was executing; a queued one is cancelled outright.
        if let status = json?["status"]?.string, status != "stopping", !run.startedAnswering,
           Date().timeIntervalSince(run.opened) >= stuckAfter {
            run.markStuck()
        }
    }

    /// What Hermes says when the session id can't be continued: deleted (retired) or unresumable.
    static let sessionGoneReasons: Set<String> = ["not_found", "unknown_execution"]

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

    static func errorCode(_ body: String) -> String? {
        let json = try? JSONValue(json: body)
        return json?["error"]?["code"]?.string ?? json?["error"]?["message"]?.string
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
    /// The `chatcmpl-…` id of the stream, which is also its run id at Hermes.
    private(set) var completionID: String?
    private var error: String?
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
        if completionID == nil { completionID = json["id"]?.string }
        let choice = json["choices"]?.array?.first
        if let delta = choice?["delta"]?["content"]?.string {
            text += delta
        }
        if choice?["finish_reason"]?.string == "error" { error = json["error"]?["message"]?.string ?? "" }
        return nil
    }

    func finish() throws -> String {
        if let error, HermesClient.sessionGoneReasons.contains(error) { throw HermesError.sessionGone }
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

/// What a cancelled question needs to know about its stream: Hermes's run id and whether the answer
/// had begun. Written by the stream, read when the question is cancelled.
private final class Run: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: String?
    private var _startedAnswering = false
    private var _stuck = false
    let opened = Date()

    var id: String? { lock.withLock { _id } }
    var startedAnswering: Bool { lock.withLock { _startedAnswering } }
    var stuck: Bool { lock.withLock { _stuck } }

    func update(id: String?, started: Bool) {
        lock.withLock {
            if _id == nil { _id = id }
            if started { _startedAnswering = true }
        }
    }

    func markStuck() { lock.withLock { _stuck = true } }
}
