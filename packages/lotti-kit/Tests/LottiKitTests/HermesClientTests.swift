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
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var _requests: [(request: URLRequest, body: Data)] = []

    static func reset(_ replies: [String: Reply]) {
        lock.withLock { _replies = replies; _requests = [] }
    }

    static var requests: [(request: URLRequest, body: Data)] { lock.withLock { _requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let path = request.url?.path() ?? ""
        let reply = Self.lock.withLock {
            Self._requests.append((request, body))
            return Self._replies[path]
        } ?? Reply(status: 404, contentType: "text/plain", body: "404: Not Found")
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": reply.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        if !reply.hang { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {}

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

    @Test func aCancelledQuestionStopsItsRunAtHermes() async throws {
        StubHermesProtocol.reset([
            "/v1/chat/completions": .init(body: Self.opening + Self.chunk("Work"), hang: true),
            "/v1/runs/chatcmpl-1/stop": .init(contentType: "application/json", body: #"{"run_id":"chatcmpl-1","status":"stopping"}"#),
        ])
        let client = client(stuckAfter: 0)
        let question = Task { try await client.complete(messages, session: "lotti-abc") { _ in } }
        try await eventually { StubHermesProtocol.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(100))  // the opening chunk (with the run id) is in
        question.cancel()
        let result = await question.result
        #expect(throws: (any Error).self) { try result.get() }
        #expect((try? result.get()) == nil)
        if case .failure(let error) = result { #expect(error as? HermesError != .sessionStuck) }  // it had started
        let stop = try #require(StubHermesProtocol.requests.last)
        #expect(stop.request.url?.path() == "/v1/runs/chatcmpl-1/stop")
        #expect(stop.request.httpMethod == "POST")
        #expect(stop.request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func aRunThatNeverStartedMeansTheSessionIsStuck() async throws {
        // Queued behind a turn that won't finish: Hermes cancels the queued run instead of stopping it.
        StubHermesProtocol.reset([
            "/v1/chat/completions": .init(body: Self.opening, hang: true),
            "/v1/runs/chatcmpl-1/stop": .init(contentType: "application/json", body: #"{"run_id":"chatcmpl-1","status":"cancelled"}"#),
        ])
        let client = client(stuckAfter: 0)
        let question = Task { try await client.complete(messages, session: "lotti-abc") { _ in } }
        try await eventually { StubHermesProtocol.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        question.cancel()
        let result = await question.result
        #expect(throws: HermesError.sessionStuck) { try result.get() }
    }

    @Test func aShortWaitInTheQueueIsNotStuck() async throws {
        StubHermesProtocol.reset([
            "/v1/chat/completions": .init(body: Self.opening, hang: true),
            "/v1/runs/chatcmpl-1/stop": .init(contentType: "application/json", body: #"{"run_id":"chatcmpl-1","status":"cancelled"}"#),
        ])
        let client = client(stuckAfter: 60)
        let question = Task { try await client.complete(messages, session: "lotti-abc") { _ in } }
        try await eventually { StubHermesProtocol.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        question.cancel()
        if case .failure(let error) = await question.result { #expect(error as? HermesError != .sessionStuck) }
    }
}
