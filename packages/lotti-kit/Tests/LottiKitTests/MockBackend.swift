import Foundation
@testable import LottiKit

/// An in-process Lotti Brain for tests: a `BackendTransport` whose "server" answers the protocol in
/// docs/protocol.md from a script.
///
/// By default it welcomes every `hello`, answers every `ask` with "OK" and every `perform` / `undo`
/// with `performed ok`. Tests push their own server messages with `send(_:)`, read what the app sent
/// with `received`, and break the connection with `drop()`.
final class MockBackend: BackendTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _connections: [MockConnection] = []
    private var _received: [JSONValue] = []
    private var _connectCount = 0
    private var _refusals = 0
    /// Called for each frame the app sends; returns the server frames to send back.
    var script: @Sendable (JSONValue) -> [String] = { MockBackend.defaultReply($0) }

    /// Every frame the app sent, decoded, oldest first (across all connections).
    var received: [JSONValue] { lock.withLock { _received } }
    var connectCount: Int { lock.withLock { _connectCount } }
    var headers: [String] { lock.withLock { _headers } }
    private var _headers: [String] = []

    func received(type: String) -> [JSONValue] { received.filter { $0["type"]?.string == type } }

    /// The next `count` connection attempts fail.
    func refuse(_ count: Int) { lock.withLock { _refusals = count } }

    func connect(to url: URL, token: String) async throws -> any BackendConnection {
        try lock.withLock {
            _connectCount += 1
            _headers.append("\(url.absoluteString) Bearer \(token)")
            if _refusals > 0 {
                _refusals -= 1
                throw BackendError.unreachable
            }
        }
        let connection = MockConnection(owner: self)
        lock.withLock { _connections.append(connection) }
        return connection
    }

    /// Server → app: one JSON frame to the newest open connection.
    func send(_ frame: String) {
        let connection = lock.withLock { _connections.last }
        connection?.deliver(frame)
    }

    /// The server goes away: the app's `receive()` throws.
    func drop() {
        let connection = lock.withLock { _connections.last }
        connection?.fail()
    }

    fileprivate func receive(_ text: String) {
        guard let frame = try? JSONValue(json: text) else { return }
        lock.withLock { _received.append(frame) }
        for reply in script(frame) { send(reply) }
    }

    static func defaultReply(_ frame: JSONValue) -> [String] {
        switch frame["type"]?.string {
        case "hello":
            return [#"{"type":"welcome","serverVersion":"0.1.0","conversationId":"c1","settings":{"catchup":true,"activeProvider":"test"}}"#]
        case "ask":
            let id = frame["id"]?.string ?? ""
            return [#"{"type":"answer","id":"\#(id)","conversationId":"c1","text":"OK","followUps":[],"actions":[]}"#]
        case "perform", "undo":
            let id = frame["id"]?.string ?? ""
            return [#"{"type":"performed","id":"\#(id)","ok":true,"text":"Done."}"#]
        default:
            return []
        }
    }
}

final class MockConnection: BackendConnection, @unchecked Sendable {
    struct Closed: Error {}

    private weak var owner: MockBackend?
    private let lock = NSLock()
    private var queue: [String] = []
    private var waiting: CheckedContinuation<String, Error>?
    private var failed = false
    var pings = 0
    var pingFails = false

    init(owner: MockBackend) { self.owner = owner }

    func send(_ text: String) async throws {
        if lock.withLock({ failed }) { throw Closed() }
        owner?.receive(text)
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !queue.isEmpty {
                let next = queue.removeFirst()
                lock.unlock()
                continuation.resume(returning: next)
            } else if failed {
                lock.unlock()
                continuation.resume(throwing: Closed())
            } else {
                waiting = continuation
                lock.unlock()
            }
        }
    }

    func ping() async throws {
        pings += 1
        if pingFails { throw Closed() }
    }

    func close() { fail() }

    func deliver(_ frame: String) {
        lock.lock()
        if let waiting {
            self.waiting = nil
            lock.unlock()
            waiting.resume(returning: frame)
        } else {
            queue.append(frame)
            lock.unlock()
        }
    }

    func fail() {
        lock.lock()
        failed = true
        let waiting = self.waiting
        self.waiting = nil
        lock.unlock()
        waiting?.resume(throwing: Closed())
    }
}

enum Fixtures {
    static let config = BackendConfiguration(baseURL: URL(string: "https://brain.test")!, token: "tok",
                                             deviceName: "Jan's iPhone", appVersion: "1.0")

    @MainActor
    static func client(_ backend: MockBackend, tools: [any PhoneTool] = [], toolTimeout: Duration = .seconds(10),
                       policy: ReconnectPolicy = ReconnectPolicy(initial: .milliseconds(20), maximum: .milliseconds(80)),
                       start: Bool = true) -> BackendClient {
        let client = BackendClient(transport: backend, toolbox: Toolbox(tools), configuration: config, policy: policy,
                                   toolTimeout: toolTimeout, requestTimeout: .seconds(2))
        if start { client.start() }
        return client
    }
}
