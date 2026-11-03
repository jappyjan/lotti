import Foundation
import Testing
@testable import LottiKit

/// Plays Hermes's HTTP side for `HermesClient`: canned responses per path, recording every request.
/// A stream marked `hang` sends its chunks and then stays open until the client goes away.
final class StubHermesProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var contentType = "text/event-stream"
        var body: String
        var hang = false
        /// Like Hermes stopping a run: first ends the open streams (a `cancelled` finish), then
        /// answers this request a little later.
        var endsOpenStreams = false
        /// Sent this long after `body`, like Hermes loading a long session before its first chunk.
        var later: (body: String, after: TimeInterval)?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var _requests: [(request: URLRequest, body: Data)] = []
    nonisolated(unsafe) private static var open: [StubHermesProtocol] = []
    /// Whether a stream was still open when each request arrived, in order.
    nonisolated(unsafe) private static var _openAtRequest: [Bool] = []

    static func reset(_ replies: [String: Reply]) {
        lock.withLock { _replies = replies; _requests = []; open = []; _openAtRequest = [] }
    }

    static var openAtRequest: [Bool] { lock.withLock { _openAtRequest } }

    static var requests: [(request: URLRequest, body: Data)] { lock.withLock { _requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let path = request.url?.path() ?? ""
        let (reply, streams) = Self.lock.withLock {
            Self._requests.append((request, body))
            Self._openAtRequest.append(!Self.open.isEmpty)
            let reply = Self._replies[path]
            var streams: [StubHermesProtocol] = []
            if reply?.endsOpenStreams == true { streams = Self.open; Self.open = [] }
            if reply?.hang == true { Self.open.append(self) }
            return (reply, streams)
        }
        let answer = reply ?? Reply(status: 404, contentType: "text/plain", body: "404: Not Found")
        for stream in streams { stream.endCancelled() }
        let respond = {
            let response = HTTPURLResponse(url: self.request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": answer.contentType])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
            if let later = answer.later {
                DispatchQueue.global().asyncAfter(deadline: .now() + later.after) {
                    guard Self.lock.withLock({ Self.open.contains { $0 === self } }) else { return }
                    self.client?.urlProtocol(self, didLoad: Data(later.body.utf8))
                }
            }
            if !answer.hang { self.client?.urlProtocolDidFinishLoading(self) }
        }
        if answer.endsOpenStreams { DispatchQueue.global().asyncAfter(deadline: .now() + 0.05, execute: respond) } else { respond() }
    }

    private func endCancelled() {
        let finish = #"data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"cancelled"}]}"# + "\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(finish.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.withLock { Self.open.removeAll { $0 === self } }
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite(.serialized)
struct HermesClientTests {
    let config = HermesConfig(url: URL(string: "https://hermes.test")!, key: "k")

    func client(stuckAfter: TimeInterval = 10) -> HermesClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHermesProtocol.self]
        let config = config
        return HermesClient(session: URLSession(configuration: configuration), stuckAfter: stuckAfter) { config }
    }

    static func chunk(_ content: String) -> String {
        #"data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"\#(content)"}}]}"# + "\n\n"
    }

    static let opening = #"data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"}}]}"# + "\n\n"

    let messages = [ChatMessage(.system, "prompt"), ChatMessage(.user, "Jan: Hi")]

    @Test func sendsTheSessionHeaderAndJustTheGivenMessages() async throws {
        StubHermesProtocol.reset(["/v1/chat/completions": .init(body: Self.opening + Self.chunk("Hello.") + "data: [DONE]\n\n")])
        let text = try await client().complete(messages, session: "lotti-abc") { _ in }
        #expect(text == "Hello.")
        let sent = try #require(StubHermesProtocol.requests.first)
        #expect(sent.request.value(forHTTPHeaderField: "X-Hermes-Session-Id") == "lotti-abc")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let body = try JSONValue(json: String(decoding: sent.body, as: UTF8.self))
        #expect(body["messages"]?.array?.count == 2)
        #expect(body["messages"]?.array?.last?["content"]?.string == "Jan: Hi")
    }

    @Test func aRetiredSessionIsSessionGone() async throws {
        StubHermesProtocol.reset(["/v1/chat/completions": .init(
            status: 409, contentType: "application/json",
            body: #"{"error":{"message":"not_found","type":"invalid_request_error","code":"not_found"}}"#)])
        await #expect(throws: HermesError.sessionGone) { try await client().complete(messages, session: "lotti-old") { _ in } }
    }

    @Test func anErrorChunkNamingTheSessionIsSessionGone() async throws {
        let failed = #"data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"error"}],"error":{"message":"unknown_execution","type":"RuntimeStoreError"}}"# + "\n\n"
        StubHermesProtocol.reset(["/v1/chat/completions": .init(body: Self.opening + failed + "data: [DONE]\n\n")])
        await #expect(throws: HermesError.sessionGone) { try await client().complete(messages, session: "lotti-old") { _ in } }
    }

    @Test func otherErrorsStayAsTheyWere() async throws {
        StubHermesProtocol.reset(["/v1/chat/completions": .init(status: 404, contentType: "text/plain", body: "404: Not Found")])
        await #expect(throws: HermesError.http(404, "404: Not Found")) { try await client().complete(messages, session: "s") { _ in } }
    }

    /// Waits until the stream's first chunk (with the run id) is in.
    func startQuestion(_ client: HermesClient) async throws -> Task<String, Error> {
        let question = Task { try await client.complete(messages, session: "lotti-abc") { _ in } }
        try await eventually { StubHermesProtocol.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        return question
    }

    @Test func aCancelledQuestionStopsItsRunWhileTheStreamIsOpen() async throws {
        StubHermesProtocol.reset([
            "/v1/chat/completions": .init(body: Self.opening + Self.chunk("Work"), hang: true),
            "/v1/runs/chatcmpl-1/stop": .init(contentType: "application/json",
                                              body: #"{"run_id":"chatcmpl-1","status":"stopping"}"#, endsOpenStreams: true),
        ])
        let question = try await startQuestion(client(stuckAfter: 0))
        question.cancel()
        let result = await question.result
        #expect(throws: CancellationError.self) { try result.get() }
        let paths = StubHermesProtocol.requests.map { $0.request.url?.path() ?? "" }
        #expect(paths == ["/v1/chat/completions", "/v1/runs/chatcmpl-1/stop"])  // it had started: no status check
        let stop = try #require(StubHermesProtocol.requests.last)
        #expect(stop.request.httpMethod == "POST")
        #expect(stop.request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(StubHermesProtocol.openAtRequest.last == true)  // Hermes still knew the run
    }

    @Test func aRunStillQueuedMeansTheSessionIsStuck() async throws {
        // Queued behind a turn that won't finish. Like Hermes: the stop ends the stream first and
        // then answers null (the run's alias is gone by then).
        StubHermesProtocol.reset([
            "/v1/chat/completions": .init(body: Self.opening, hang: true),
            "/v1/runs/chatcmpl-1": .init(contentType: "application/json", body: #"{"object":"hermes.run","status":"queued"}"#),
            "/v1/runs/chatcmpl-1/stop": .init(contentType: "application/json", body: "null", endsOpenStreams: true),
        ])
        let question = try await startQuestion(client(stuckAfter: 0))
        question.cancel()
        let result = await question.result
        #expect(throws: HermesError.sessionStuck) { try result.get() }
        #expect(StubHermesProtocol.openAtRequest == [false, true, true])
    }

    @Test func aRunThatIsRunningIsNotStuck() async throws {
        StubHermesProtocol.reset([
            "/v1/chat/completions": .init(body: Self.opening, hang: true),
            "/v1/runs/chatcmpl-1": .init(contentType: "application/json", body: #"{"object":"hermes.run","status":"running"}"#),
            "/v1/runs/chatcmpl-1/stop": .init(contentType: "application/json", body: "null", endsOpenStreams: true),
        ])
        let question = try await startQuestion(client(stuckAfter: 0))
        question.cancel()
        let result = await question.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test func aShortWaitInTheQueueIsNotStuck() async throws {
        StubHermesProtocol.reset([
            "/v1/chat/completions": .init(body: Self.opening, hang: true),
            "/v1/runs/chatcmpl-1": .init(contentType: "application/json", body: #"{"object":"hermes.run","status":"queued"}"#),
            "/v1/runs/chatcmpl-1/stop": .init(contentType: "application/json", body: "null", endsOpenStreams: true),
        ])
        let question = try await startQuestion(client(stuckAfter: 60))
        question.cancel()
        let result = await question.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!StubHermesProtocol.requests.contains { $0.request.url?.path() == "/v1/runs/chatcmpl-1" })
    }

    @Test func aQuestionCancelledBeforeItsRunIsKnownWaitsForTheId() async throws {
        StubHermesProtocol.reset([
            "/v1/chat/completions": .init(body: ": keepalive\n\n", hang: true, later: (Self.opening, 0.3)),
            "/v1/runs/chatcmpl-1/stop": .init(contentType: "application/json", body: "null", endsOpenStreams: true),
        ])
        let client = client()
        let question = Task { try await client.complete(messages, session: "lotti-abc") { _ in } }
        try await eventually { StubHermesProtocol.requests.count == 1 }
        question.cancel()  // before the first chunk (with the run id) arrives
        _ = await question.result
        #expect(StubHermesProtocol.requests.last?.request.url?.path() == "/v1/runs/chatcmpl-1/stop")
    }
}
