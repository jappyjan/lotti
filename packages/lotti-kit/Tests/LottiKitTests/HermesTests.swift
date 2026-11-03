import Foundation
import Testing
@testable import LottiKit

/// Plays Hermes from a script: one reply per request, recording what it was sent.
final class ScriptedHermes: HermesTransport, @unchecked Sendable {
    var replies: [String]
    var progress: [String] = []
    var error: Error?
    var delay: Duration?
    /// Thrown by the next requests, one each, before the script answers.
    var failures: [Error] = []
    /// Called at every request, before it answers.
    var onRequest: (@Sendable () -> Void)?
    private(set) var requests: [[ChatMessage]] = []
    /// The session id of every request, in order.
    private(set) var sessions: [String] = []
    private let activityLock = NSLock()
    private var activityCount = 0

    /// How many times the transport reported activity (any data from Hermes).
    var activities: Int { activityLock.withLock { activityCount } }

    init(_ replies: [String]) { self.replies = replies }

    func complete(
        _ messages: [ChatMessage], session: String,
        progress report: @escaping @Sendable (String) -> Void,
        activity: @escaping @Sendable () -> Void
    ) async throws -> String {
        requests.append(messages)
        sessions.append(session)
        onRequest?()
        if !failures.isEmpty { throw failures.removeFirst() }
        for line in progress {
            report(line)
            activityLock.withLock { activityCount += 1 }
            activity()
        }
        if let delay { try await Task.sleep(for: delay) }
        if let error { throw error }
        guard !replies.isEmpty else { throw HermesError.empty }
        activityLock.withLock { activityCount += 1 }
        activity()
        return replies.removeFirst()
    }
}

/// A transport whose first request hangs until cancelled and then takes a while to unwind, like a
/// URLSession task that is cancelled. Later requests answer from the script straight away.
final class SlowToCancelHermes: HermesTransport, @unchecked Sendable {
    var replies: [String]
    private(set) var requests: [[ChatMessage]] = []

    init(_ replies: [String]) { self.replies = replies }

    func complete(_ messages: [ChatMessage], session: String, progress report: @escaping @Sendable (String) -> Void,
                  activity: @escaping @Sendable () -> Void) async throws -> String {
        requests.append(messages)
        if requests.count == 1 {
            do { try await Task.sleep(for: .seconds(30)) } catch {
                await Task.detached { try? await Task.sleep(for: .milliseconds(150)) }.value
                throw error
            }
        }
        guard !replies.isEmpty else { throw HermesError.empty }
        return replies.removeFirst()
    }
}

/// Remembers the session id it was given and hands back whatever it was seeded with, like UserDefaults.
final class FakeHermesSessionStore: HermesSessionStore, @unchecked Sendable {
    private(set) var stored: String?
    private(set) var saves: [String] = []

    init(stored: String? = nil) { self.stored = stored }

    func load() throws -> String? { stored }

    func save(_ id: String) throws {
        saves.append(id)
        stored = id
    }
}

struct HermesFormatTests {
    @Test func parsesSeveralCalls() {
        let reply = HermesFormat.parse(#"""
            {"type":"call","status":"Checking your day","calls":[
              {"id":"c1","tool":"calendar","args":{"from":"2026-11-02","days":2}},
              {"tool":"weather","arguments":{}}]}
            """#)
        #expect(reply == .calls([
            ToolCall(id: "c1", tool: "calendar", arguments: ["from": "2026-11-02", "days": 2]),
            ToolCall(id: "c2", tool: "weather"),
        ], status: "Checking your day"))
    }

    @Test func parsesAnAnswerWithActions() {
        let reply = HermesFormat.parse(#"""
            {"type":"answer","sentence":"Pasta takes 10 minutes.","followUps":["Sauce?"],
             "actions":[{"tool":"set_timer","args":{"minutes":10,"label":"Pasta"}}]}
            """#)
        #expect(reply == .answer(sentence: "Pasta takes 10 minutes.", followUps: ["Sauce?"],
                                 actions: [ToolCall(id: "a1", tool: "set_timer", arguments: ["minutes": 10, "label": "Pasta"])]))
    }

    @Test func findsJSONInsideFencesAndProse() {
        let reply = HermesFormat.parse("Sure!\n```json\n{\"type\":\"answer\",\"sentence\":\"Hi.\"}\n```")
        #expect(reply == .answer(sentence: "Hi.", followUps: [], actions: []))
    }

    @Test func plainTextIsNotAReply() {
        #expect(HermesFormat.parse("The museum opens at 10.") == nil)
        #expect(HermesFormat.parse(#"{"type":"call","calls":[]}"#) == nil)
        #expect(HermesFormat.plainSentence("**Yes.** It opens\nat 10.") == "Yes. It opens at 10.")
    }

    @Test func resultsMessage() throws {
        let text = HermesFormat.results([ToolResult(id: "c1", ok: true, content: "Standup 9:30")], final: true)
        let json = try JSONValue(json: text)
        #expect(json["type"] == "results")
        #expect(json["results"]?.array?.first == ["id": "c1", "ok": true, "content": "Standup 9:30"])
        #expect(json["note"]?.string?.contains("Answer now") == true)
    }

    @Test func instructionsListReadsAndActionsSeparately() {
        let reads = [FakeTool("calendar", parameters: [ToolParameter("from", .string, "first day, YYYY-MM-DD"),
                                                       ToolParameter("days", .integer, "", optional: true)]).spec]
        let text = HermesFormat.instructions(reads: reads, actions: [FakeTool.timer().spec])
        #expect(text.contains("- calendar(from: string, days?: integer): Fake calendar. from: first day, YYYY-MM-DD."))
        #expect(text.contains("Phone actions you may suggest"))
        #expect(text.contains("- set_timer(minutes: integer, label?: string)"))
        #expect(text.contains("they run at the same time"))
    }

    @Test func configAcceptsWhatPeoplePaste() {
        let bare = HermesConfig(address: "hermes.example.ts.net/", key: "k")
        #expect(bare?.endpoint("chat/completions").absoluteString == "https://hermes.example.ts.net/v1/chat/completions")
        let withV1 = HermesConfig(address: "http://192.168.1.20:8642/v1", key: "k")
        #expect(withV1?.endpoint("models").absoluteString == "http://192.168.1.20:8642/v1/models")
        #expect(HermesConfig(address: "", key: "k") == nil)
        #expect(HermesConfig(address: "hermes.local", key: " ") == nil)
    }

    @Test func routesExplicitQuestions() {
        #expect(HermesRoute.explicitQuestion("Hermes, what's new in Swift?") == "what's new in Swift?")
        #expect(HermesRoute.explicitQuestion("ask Hermes when the museum opens") == "when the museum opens")
        #expect(HermesRoute.explicitQuestion("Frag Hermes, wann fährt die S-Bahn?") == "wann fährt die S-Bahn?")
        #expect(HermesRoute.explicitQuestion("Dig into flights to Lisbon") == "Dig into flights to Lisbon")
        #expect(HermesRoute.explicitQuestion("What's on today?") == nil)
        #expect(HermesRoute.explicitQuestion("Hermesbrief") == nil)
    }
}

struct ServerSentEventsTests {
    @Test func collectsContentAndProgress() throws {
        var parser = ServerSentEvents()
        let lines = [
            ": keepalive",
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
            "event: hermes.tool.progress",
            #"data: {"tool":"web_search","label":"Searching the web"}"#,
            "",
            #"data: {"choices":[{"delta":{"content":"{\"type\":"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"\"answer\"}"}}]}"#,
            "data: [DONE]",
        ]
        var signals: [ServerSentEvents.Signal] = []
        for line in lines { if let signal = parser.feed(line) { signals.append(signal) } }
        #expect(signals == [.progress("Searching the web"), .done])
        #expect(try parser.finish() == #"{"type":"answer"}"#)
    }

    @Test func anEmptyStreamIsAnError() {
        #expect(throws: HermesError.empty) { try ServerSentEvents().finish() }
    }
}

@MainActor
struct HermesBrainTests {
    let calendar = FakeTool("calendar", parameters: [ToolParameter("from", .string, "")], result: "09:30 Standup",
                            delay: .milliseconds(150))
    let weather = FakeTool("weather", result: "8°, rain from 15:00", delay: .milliseconds(150))
    let location = FakeTool("location", result: "Kreuzberg")
    let timer = FakeTool.timer()
    var toolbox: Toolbox { Toolbox([calendar, weather, location, timer]) }

    func brain(_ hermes: ScriptedHermes, allowed: Set<String> = ["calendar", "weather"], maxRounds: Int = 4) -> HermesBrain {
        HermesBrain(transport: hermes, toolbox: toolbox, allowedReads: { allowed }, isConfigured: { true }, maxRounds: maxRounds)
    }

    @Test func runsSeveralPhoneCallsAtOnceThenAnswers() async throws {
        let hermes = ScriptedHermes([
            #"{"type":"call","status":"Checking your morning","calls":[{"id":"c1","tool":"calendar","args":{"from":"2026-11-02"}},{"id":"c2","tool":"weather","args":{}}]}"#,
            #"{"type":"answer","sentence":"Standup at 9:30, take an umbrella.","followUps":["Later?"]}"#,
        ])
        let brain = brain(hermes)
        var statuses: [String] = []
        let started = Date()
        let answer = try await brain.answer("How's tomorrow?", context: "Now: Sunday") { statuses.append($0) }
        #expect(Date().timeIntervalSince(started) < 0.3)  // both calls ran together
        #expect(answer == Answer(sentence: "Standup at 9:30, take an umbrella.", followUps: ["Later?"]))
        #expect(statuses == ["Checking your morning"])

        // Each request is the system prompt plus only the newest message; Hermes holds the rest.
        #expect(hermes.requests.map(\.count) == [2, 2])
        #expect(hermes.requests[0].first?.role == .system)
        #expect(hermes.requests[0][1] == ChatMessage(.user, "Now: Sunday\n\nJan: How's tomorrow?"))
        let second = try #require(hermes.requests.last)
        #expect(second.first?.role == .system)
        let results = try JSONValue(json: second.last!.content)
        #expect(results["results"]?.array?.map { $0["content"]?.string } == ["09:30 Standup", "8°, rain from 15:00"])
    }

    @Test func onlySharedReadsAreOffered() async throws {
        let hermes = ScriptedHermes([#"{"type":"answer","sentence":"Hi."}"#])
        _ = try await brain(hermes, allowed: ["weather"]).answer("Hi", context: "") { _ in }
        let system = try #require(hermes.requests.first?.first?.content)
        #expect(system.contains("- weather()"))
        #expect(!system.contains("- calendar("))
        #expect(!system.contains("- location("))
        #expect(system.contains("- set_timer("))
    }

    @Test func actionsComeBackAsProposalsAndNeverRun() async throws {
        let hermes = ScriptedHermes([
            #"{"type":"call","calls":[{"id":"c1","tool":"set_timer","args":{"minutes":10}}]}"#,
            #"{"type":"answer","sentence":"Ready.","actions":[{"tool":"set_timer","args":{"minutes":10,"label":"Pasta"}},{"tool":"set_timer","args":{}}]}"#,
        ])
        let answer = try await brain(hermes).answer("Pasta timer", context: "") { _ in }
        #expect(answer.actions.map(\.title) == ["Timer 10 min"])  // the invalid one is dropped
        #expect(timer.runs.isEmpty)
        let refusal = try JSONValue(json: hermes.requests[1].last!.content)
        #expect(refusal["results"]?.array?.first?["ok"] == false)
    }

    @Test func followUpsContinueTheSessionWithAFreshTimeLine() async throws {
        let hermes = ScriptedHermes([#"{"type":"answer","sentence":"One."}"#, #"{"type":"answer","sentence":"Two."}"#])
        let brain = brain(hermes)
        _ = try await brain.answer("First", context: "Now: Sunday") { _ in }
        _ = try await brain.answer("Second", context: "Now: Monday") { _ in }
        #expect(hermes.requests[0].map(\.role) == [.system, .user])
        #expect(hermes.requests[0].last?.content == "Now: Sunday\n\nJan: First")
        #expect(hermes.requests[1].map(\.role) == [.system, .user])  // never the earlier turns
        #expect(hermes.requests[1].last?.content == "Now: Monday\n\nJan: Second")
        #expect(Set(hermes.sessions).count == 1)
        #expect(brain.sessionID == hermes.sessions.first)
    }

    @Test func stopsAfterTheRoundLimit() async throws {
        let call = #"{"type":"call","calls":[{"tool":"weather"}]}"#
        let hermes = ScriptedHermes([call, call, call])
        let answer = try await brain(hermes, maxRounds: 2).answer("Weather?", context: "") { _ in }
        #expect(answer.sentence.contains("more than I could check"))
        let last = try JSONValue(json: hermes.requests[2].last!.content)
        #expect(last["note"] != nil)  // told to answer now
    }

    @Test func plainTextIsShownAsItIs() async throws {
        let hermes = ScriptedHermes(["The museum opens at 10."])
        let answer = try await brain(hermes).answer("Museum?", context: "") { _ in }
        #expect(answer.sentence == "The museum opens at 10.")
    }

    @Test func hermesToolProgressIsLoggedNotShown() async throws {
        let hermes = ScriptedHermes([#"{"type":"answer","sentence":"Hi."}"#])
        hermes.progress = ["web_search", "curl -s https://example.com/news"]
        var statuses: [String] = []
        let brain = brain(hermes)
        _ = try await brain.answer("What's new?", context: "") { statuses.append($0) }
        #expect(statuses.isEmpty)  // Hermes's own tool activity never reaches the glasses
        #expect(brain.trace.contains { $0.hasPrefix("· web_search") })
        #expect(hermes.activities == 3)  // both progress lines plus the reply itself
    }

    @Test func progressNotesAreCapped() async throws {
        let hermes = ScriptedHermes([#"{"type":"answer","sentence":"Hi."}"#])
        hermes.progress = (0..<50).map { "step \($0)" }
        let brain = brain(hermes)
        _ = try await brain.answer("Hi", context: "") { _ in }
        #expect(brain.trace.filter { $0.hasPrefix("· ") }.count == 10)
    }

    @Test func activityReachesTheCallerButProgressDoesnt() async throws {
        let hermes = ScriptedHermes([#"{"type":"answer","sentence":"Done."}"#])
        hermes.progress = ["Searching the web"]
        hermes.delay = .milliseconds(50)
        var statuses: [String] = []
        var pulses = 0
        _ = try await brain(hermes).answer("News?", context: "") { statuses.append($0) } activity: { pulses += 1 }
        try? await Task.sleep(for: .milliseconds(50))  // activity hops to the main actor through a task
        #expect(statuses.isEmpty)  // tool progress is not a status line
        #expect(pulses == 2)  // one for the progress line, one for the reply
    }

    // MARK: Session

    private static let plainReply = #"{"type":"answer","sentence":"yep."}"#
    private static let callReply = #"{"type":"call","calls":[{"id":"c1","tool":"weather","args":{}}]}"#

    func brain(_ hermes: some HermesTransport, store: FakeHermesSessionStore? = nil,
               allowed: @escaping () -> Set<String> = { ["calendar", "weather"] }) -> HermesBrain {
        HermesBrain(transport: hermes, toolbox: toolbox, allowedReads: allowed, isConfigured: { true }, store: store)
    }

    @Test func theSessionIsMadeOnceAndSavedBeforeTheFirstRequest() async throws {
        let store = FakeHermesSessionStore()
        let hermes = ScriptedHermes([Self.plainReply, Self.callReply, Self.plainReply])
        let brain = brain(hermes, store: store)
        #expect(brain.sessionID == nil)
        _ = try await brain.answer("First", context: "") { _ in }
        let id = try #require(store.stored)
        #expect(id.hasPrefix("lotti-"))
        #expect(id == id.lowercased())
        _ = try await brain.answer("Second", context: "") { _ in }  // a call round and an answer
        #expect(hermes.sessions.count == 3)
        #expect(hermes.sessions.allSatisfy { $0 == id })  // across questions and rounds
        #expect(store.saves == [id])  // saved once, never rewritten
    }

    @Test func aRestartContinuesTheSameSession() async throws {
        let store = FakeHermesSessionStore()
        let first = ScriptedHermes([Self.plainReply])
        _ = try await brain(first, store: store).answer("First", context: "") { _ in }

        let second = ScriptedHermes([Self.plainReply])
        let reborn = brain(second, store: store)
        #expect(reborn.sessionID == store.stored)
        _ = try await reborn.answer("A day later", context: "") { _ in }
        #expect(second.sessions == first.sessions)
        #expect(store.saves.count == 1)
    }

    @Test func aStoredSessionIsUsedAsItIs() async throws {
        let hermes = ScriptedHermes([Self.plainReply])
        _ = try await brain(hermes, store: FakeHermesSessionStore(stored: "lotti-abc")).answer("Hi", context: "") { _ in }
        #expect(hermes.sessions == ["lotti-abc"])
    }

    @Test func failuresAndCancellationKeepTheSession() async throws {
        let store = FakeHermesSessionStore()
        let hermes = ScriptedHermes([Self.plainReply])
        let brain = brain(hermes, store: store)
        _ = try await brain.answer("First", context: "") { _ in }
        let id = try #require(brain.sessionID)

        hermes.error = HermesError.http(500, "boom")
        await #expect(throws: HermesError.http(500, "boom")) { try await brain.answer("Fails", context: "") { _ in } }
        #expect(brain.sessionID == id)

        hermes.error = nil
        hermes.delay = .seconds(5)
        let task = Task { try await brain.answer("Cancelled", context: "") { _ in } }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.result

        hermes.delay = nil
        hermes.replies = [Self.plainReply]
        _ = try await brain.answer("Again", context: "") { _ in }
        #expect(hermes.sessions.allSatisfy { $0 == id })
        #expect(store.saves == [id])
    }

    @Test func hidingAReadChangesTheSystemPromptNotTheSession() async throws {
        var allowed: Set<String> = ["calendar", "weather"]
        let hermes = ScriptedHermes([Self.plainReply, Self.plainReply])
        let brain = brain(hermes) { allowed }
        _ = try await brain.answer("First", context: "") { _ in }
        allowed = ["weather"]
        _ = try await brain.answer("Second", context: "") { _ in }
        #expect(try #require(hermes.requests[0].first?.content).contains("- calendar("))
        #expect(!(try #require(hermes.requests[1].first?.content)).contains("- calendar("))
        #expect(Set(hermes.sessions).count == 1)
    }

    @Test func aNewerQuestionSupersedesOneStillUnwinding() async throws {
        // Jan asks again while the first question is still unwinding from its cancellation.
        let hermes = SlowToCancelHermes([#"{"type":"answer","sentence":"Two."}"#])
        let brain = brain(hermes)
        let first = Task { try await brain.answer("First", context: "") { _ in } }
        try await Task.sleep(for: .milliseconds(50))
        first.cancel()
        let second = Task { try await brain.answer("Second", context: "") { _ in } }
        let answer = try await second.value
        _ = await first.result
        #expect(answer.sentence == "Two.")
        #expect(hermes.requests[1].map(\.role) == [.system, .user])
        #expect(hermes.requests[1].last?.content.hasSuffix("Jan: Second") == true)
    }

    @Test func aSupersededQuestionSendsNothingMoreAfterAToolRound() async throws {
        // A newer question starts while the first one's tool round runs; the first must not send results.
        let hermes = ScriptedHermes([
            #"{"type":"call","calls":[{"id":"c1","tool":"calendar","args":{"from":"2026-11-02"}}]}"#,
            #"{"type":"answer","sentence":"Newer."}"#,
        ])
        let brain = brain(hermes)
        let first = Task { try await brain.answer("My day?", context: "") { _ in } }
        try await eventually { hermes.requests.count == 1 && hermes.replies.count == 1 }  // calendar is running
        let second = Task { try await brain.answer("Never mind, weather?", context: "") { _ in } }
        let result = await first.result
        #expect(throws: CancellationError.self) { try result.get() }
        _ = try await second.value
        #expect(hermes.requests.count == 2)  // the first one's results never went out
        #expect(hermes.requests[1].last?.content.hasSuffix("Jan: Never mind, weather?") == true)
    }

    @Test func theIdIsStoredBeforeTheFirstRequestGoesOut() async throws {
        let store = FakeHermesSessionStore()
        let hermes = ScriptedHermes([])
        hermes.failures = [HermesError.http(500, "boom")]
        let storedAtRequest = Locked<String?>(nil)
        hermes.onRequest = { storedAtRequest.value = store.stored }
        let brain = brain(hermes, store: store)
        await #expect(throws: HermesError.http(500, "boom")) { try await brain.answer("Hi", context: "") { _ in } }
        #expect(storedAtRequest.value == hermes.sessions.first)
        #expect(store.stored == hermes.sessions.first)  // a failed first question still keeps it
    }

    @Test(arguments: ["", " ", "lotti-a/../b", "lotti a", String(repeating: "x", count: 300)])
    func anUnusableStoredIdIsReplaced(_ stored: String) async throws {
        let store = FakeHermesSessionStore(stored: stored)
        let hermes = ScriptedHermes([Self.plainReply])
        let brain = brain(hermes, store: store)
        #expect(brain.sessionID == nil)
        _ = try await brain.answer("Hi", context: "") { _ in }
        #expect(hermes.sessions.first?.hasPrefix("lotti-") == true)
        #expect(store.saves == hermes.sessions)
    }

    @Test func aSessionHermesLostIsReplacedAndTheQuestionAskedAgain() async throws {
        // Deleted in Hermes's dashboard: its id stays retired, so only a new one works again.
        let store = FakeHermesSessionStore(stored: "lotti-old")
        let hermes = ScriptedHermes([Self.plainReply, Self.plainReply])
        hermes.failures = [HermesError.sessionGone]
        let brain = brain(hermes, store: store)
        let answer = try await brain.answer("Hi", context: "Now: Monday") { _ in }
        #expect(answer.sentence == "yep.")
        #expect(hermes.sessions.count == 2)
        #expect(hermes.sessions[0] == "lotti-old")
        #expect(hermes.sessions[1] != "lotti-old" && hermes.sessions[1].hasPrefix("lotti-"))
        #expect(hermes.requests[1].last?.content == "Now: Monday\n\nJan: Hi")  // the same question, asked anew
        #expect(store.stored == hermes.sessions[1])

        _ = try await brain.answer("Then", context: "") { _ in }
        #expect(hermes.sessions[2] == hermes.sessions[1])  // and kept from then on
    }

    @Test func aSessionLostTwiceIsNotRetriedForever() async throws {
        let hermes = ScriptedHermes([])
        hermes.failures = [HermesError.sessionGone, HermesError.sessionGone]
        await #expect(throws: HermesError.sessionGone) { try await brain(hermes).answer("Hi", context: "") { _ in } }
        #expect(hermes.requests.count == 2)
    }

    @Test func aStuckSessionIsReplacedForTheNextQuestion() async throws {
        // Hermes restarted mid-question and paused the session: questions just wait in its queue.
        let store = FakeHermesSessionStore(stored: "lotti-old")
        let hermes = ScriptedHermes([Self.plainReply])
        hermes.failures = [HermesError.sessionStuck]
        let brain = brain(hermes, store: store)
        await #expect(throws: HermesError.sessionStuck) { try await brain.answer("Hi", context: "") { _ in } }
        let new = try #require(brain.sessionID)
        #expect(new != "lotti-old")
        #expect(store.stored == new)  // saved right away, so a restart doesn't reload the stuck one
        _ = try await brain.answer("Again", context: "") { _ in }
        #expect(hermes.sessions == ["lotti-old", new])
    }

    @Test func aStuckQuestionDoesNotReplaceASessionANewerOneMovedTo() async throws {
        // A was stuck in "lotti-old"; meanwhile B found it gone and moved to a new session. A's late
        // "stuck" must not throw B's healthy session away.
        let hermes = PerRequestHermes([
            { try await Task.sleep(for: .milliseconds(200)); throw HermesError.sessionStuck },
            { throw HermesError.sessionGone },
            { #"{"type":"answer","sentence":"yep."}"# },
        ])
        let store = FakeHermesSessionStore(stored: "lotti-old")
        let brain = brain(hermes, store: store)
        let first = Task { try await brain.answer("A", context: "") { _ in } }
        try await eventually { hermes.sessions.count == 1 }
        _ = try await brain.answer("B", context: "") { _ in }
        let moved = try #require(brain.sessionID)
        #expect(moved != "lotti-old")
        _ = await first.result
        #expect(brain.sessionID == moved)
        #expect(store.stored == moved)
    }

    @Test func aReadHiddenDuringAQuestionIsGoneFromTheNextRequest() async throws {
        let allowed = Locked<Set<String>>(["calendar", "weather"])
        let hermes = ScriptedHermes([Self.callReply, Self.plainReply])
        hermes.onRequest = { allowed.value = ["weather"] }  // hidden while the first request runs
        _ = try await brain(hermes) { allowed.value }.answer("Weather?", context: "") { _ in }
        #expect(try #require(hermes.requests[0].first?.content).contains("- calendar("))
        #expect(!(try #require(hermes.requests[1].first?.content)).contains("- calendar("))
    }

    @Test func theInstructionsKeepEverythingInTheReply() async throws {
        let hermes = ScriptedHermes([Self.plainReply])
        _ = try await brain(hermes).answer("Hi", context: "") { _ in }
        let system = try #require(hermes.requests.first?.first?.content)
        #expect(system.contains("never leave work running in the background"))
        #expect(system.contains("Answer Jan's newest message"))
    }
}

/// Answers each request with its own step, in order, recording the session ids.
final class PerRequestHermes: HermesTransport, @unchecked Sendable {
    private var steps: [@Sendable () async throws -> String]
    private(set) var sessions: [String] = []

    init(_ steps: [@Sendable () async throws -> String]) { self.steps = steps }

    func complete(_ messages: [ChatMessage], session: String, progress: @escaping @Sendable (String) -> Void,
                  activity: @escaping @Sendable () -> Void) async throws -> String {
        sessions.append(session)
        return try await steps.removeFirst()()
    }
}

/// A value shared with a `@Sendable` closure in tests.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

struct RouterTests {
    @Test(arguments: [
        "Brauche ich heute einen Schirm?", "Wie wird das Wetter?", "Stell einen Timer auf 10 Minuten",
        "Erinner mich morgen an die Wäsche", "Was steht morgen an?", "Wo bin ich?", "Wie komme ich zum Hauptbahnhof?",
        "Navigation zu Media Markt.", "Walk me home", "Wie geht's dir?", "Wie hoch ist der Eiffelturm?",
        "Wie ist das Wetter in Lissabon?", "Stell einen Timer für Pasta",
    ])
    func everythingGoesToHermesWhenItsSetUp(_ question: String) {
        #expect(Router.route(question, hermesAvailable: true) == .hermes(question))
    }

    @Test func explicitHermesAsksGoToHermesEitherWay() {
        #expect(Router.route("Hermes, plan my week", hermesAvailable: true) == .hermes("plan my week"))
        #expect(Router.route("Hermes, plan my week", hermesAvailable: false) == .hermes("plan my week"))
    }

    @Test func withoutHermesEverythingIsLocal() {
        #expect(Router.route("Wie geht's dir?", hermesAvailable: false) == .local)
        #expect(Router.route("Was kostet ein Bitcoin?", hermesAvailable: false) == .local)
        #expect(Router.route("Brauche ich heute einen Schirm?", hermesAvailable: false) == .local)
    }
}
