import Foundation
import Testing
@testable import LottiKit

/// Plays Hermes from a script: one reply per request, recording what it was sent.
final class ScriptedHermes: HermesTransport, @unchecked Sendable {
    var replies: [String]
    var progress: [String] = []
    var error: Error?
    var delay: Duration?
    private(set) var requests: [[ChatMessage]] = []

    init(_ replies: [String]) { self.replies = replies }

    func complete(_ messages: [ChatMessage], progress report: @escaping @Sendable (String) -> Void) async throws -> String {
        requests.append(messages)
        for line in progress { report(line) }
        if let delay { try await Task.sleep(for: delay) }
        if let error { throw error }
        guard !replies.isEmpty else { throw HermesError.empty }
        return replies.removeFirst()
    }
}

/// A transport whose first request hangs until cancelled and then takes a while to unwind, like a
/// URLSession task that is cancelled. Later requests answer from the script straight away.
final class SlowToCancelHermes: HermesTransport, @unchecked Sendable {
    var replies: [String]
    private(set) var requests: [[ChatMessage]] = []

    init(_ replies: [String]) { self.replies = replies }

    func complete(_ messages: [ChatMessage], progress report: @escaping @Sendable (String) -> Void) async throws -> String {
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

/// Remembers what was saved and hands back whatever it was seeded with, like UserDefaults.
final class FakeHermesHistoryStore: HermesHistoryStore, @unchecked Sendable {
    private(set) var stored: PersistedHermesSession?
    private(set) var saved: [PersistedHermesSession] = []

    init(stored: PersistedHermesSession? = nil) { self.stored = stored }

    func load() throws -> PersistedHermesSession? { stored }

    func save(_ session: PersistedHermesSession) throws {
        saved.append(session)
        stored = session
    }
}

/// A settable clock for tests that move time forward.
final class ManualClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
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

        let second = try #require(hermes.requests.last)
        #expect(second.first?.role == .system)
        #expect(second[1] == ChatMessage(.user, "Now: Sunday\n\nJan: How's tomorrow?"))
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

    @Test func followUpsKeepTheConversation() async throws {
        let hermes = ScriptedHermes([#"{"type":"answer","sentence":"One."}"#, #"{"type":"answer","sentence":"Two."}"#])
        let brain = brain(hermes)
        _ = try await brain.answer("First", context: "Now: Sunday") { _ in }
        _ = try await brain.answer("Second", context: "Now: Monday") { _ in }
        #expect(hermes.requests[1].map(\.role) == [.system, .user, .assistant, .user])
        #expect(hermes.requests[1].last?.content == "Now: Monday\n\nJan: Second")

        brain.endConversation()
        hermes.replies = [#"{"type":"answer","sentence":"Three."}"#]
        _ = try await brain.answer("Third", context: "Now: Tuesday") { _ in }
        #expect(hermes.requests[2].count == 2)
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

    @Test func aFailedQuestionLeavesNoTrace() async throws {
        let hermes = ScriptedHermes([])
        hermes.error = HermesError.http(500, "boom")
        let brain = brain(hermes)
        await #expect(throws: HermesError.http(500, "boom")) {
            try await brain.answer("Hi", context: "") { _ in }
        }
        #expect(brain.conversation.isEmpty)
    }

    @Test func passesHermesProgressOn() async throws {
        let hermes = ScriptedHermes([#"{"type":"answer","sentence":"Done."}"#])
        hermes.progress = ["Searching the web"]
        hermes.delay = .milliseconds(50)
        var statuses: [String] = []
        _ = try await brain(hermes).answer("News?", context: "") { statuses.append($0) }
        #expect(statuses == ["Searching the web"])
    }

    // MARK: Persistence and reset

    @Test func loadsPersistedMessagesOnInit() {
        let stored = PersistedHermesSession(
            messages: [ChatMessage(.system, "prompt"), ChatMessage(.user, "Jan: Hi"), ChatMessage(.assistant, "Hey.")],
            lastAsked: Date())
        let store = FakeHermesHistoryStore(stored: stored)
        let brain = HermesBrain(transport: ScriptedHermes([]), toolbox: toolbox,
                                allowedReads: { ["calendar", "weather"] }, isConfigured: { true }, store: store)
        #expect(brain.conversation == stored.messages)
    }

    @Test func savesMessagesAndLastAskedOnEveryChange() async throws {
        let store = FakeHermesHistoryStore()
        let hermes = ScriptedHermes([#"{"type":"answer","sentence":"One."}"#])
        let brain = HermesBrain(transport: hermes, toolbox: toolbox,
                                allowedReads: { ["calendar", "weather"] }, isConfigured: { true }, store: store)
        _ = try await brain.answer("First", context: "Now: Sunday") { _ in }
        let last = try #require(store.saved.last)
        #expect(last.messages.map(\.role) == [.system, .user, .assistant])
        #expect(last.lastAsked != nil)
    }

    @Test func aStaleConversationStartsFresh() async throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 0))
        let hermes = ScriptedHermes([#"{"type":"answer","sentence":"One."}"#, #"{"type":"answer","sentence":"Two."}"#])
        let brain = HermesBrain(transport: hermes, toolbox: toolbox, allowedReads: { ["calendar", "weather"] },
                                isConfigured: { true }, resetThreshold: { .seconds(100) }, now: { clock.now })
        _ = try await brain.answer("First", context: "") { _ in }
        clock.now = Date(timeIntervalSince1970: 200)  // gap > 100 s → fresh chat
        _ = try await brain.answer("Second", context: "") { _ in }
        #expect(hermes.requests[1].count == 2)  // system + user, old history gone
        #expect(hermes.requests[1].first?.role == .system)
        #expect(hermes.requests[1].last?.content == "Jan: Second")
    }

    @Test func restartKeepsTheConversationWithinTheThreshold() async throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 0))
        let hermes = ScriptedHermes([#"{"type":"answer","sentence":"One."}"#])
        let store = FakeHermesHistoryStore()
        let brain = HermesBrain(transport: hermes, toolbox: toolbox, allowedReads: { ["calendar", "weather"] },
                                isConfigured: { true }, store: store, resetThreshold: { .seconds(7200) }, now: { clock.now })
        _ = try await brain.answer("First", context: "") { _ in }

        // "Relaunch" an hour later: a fresh brain over the same store keeps the conversation.
        clock.now = Date(timeIntervalSince1970: 3600)
        let hermes2 = ScriptedHermes([#"{"type":"answer","sentence":"Two."}"#])
        let reborn = HermesBrain(transport: hermes2, toolbox: toolbox, allowedReads: { ["calendar", "weather"] },
                                 isConfigured: { true }, store: store, resetThreshold: { .seconds(7200) }, now: { clock.now })
        _ = try await reborn.answer("Second", context: "") { _ in }
        #expect(hermes2.requests.first?.map(\.role) == [.system, .user, .assistant, .user])
    }

    @Test func aCancelledQuestionDoesNotUndoANewerOne() async throws {
        // Jan asks again while the first question is still unwinding from its cancellation.
        let hermes = SlowToCancelHermes([#"{"type":"answer","sentence":"Two."}"#])
        let store = FakeHermesHistoryStore()
        let brain = HermesBrain(transport: hermes, toolbox: toolbox, allowedReads: { ["calendar", "weather"] },
                                isConfigured: { true }, store: store)
        let first = Task { try await brain.answer("First", context: "") { _ in } }
        try await Task.sleep(for: .milliseconds(50))
        first.cancel()
        let second = Task { try await brain.answer("Second", context: "") { _ in } }
        _ = try await second.value
        _ = await first.result

        // The second question's request carried no trace of the cancelled one, and the history
        // that ended up kept (and stored) is system → question → answer.
        #expect(hermes.requests[1].map(\.role) == [.system, .user])
        #expect(brain.conversation.map(\.role) == [.system, .user, .assistant])
        #expect(brain.conversation[1].content.hasSuffix("Jan: Second"))
        #expect(store.stored?.messages == brain.conversation)
    }

    @Test func aResetWhileAQuestionIsInFlightStays() async throws {
        // "Neues Gespräch" while Hermes is still thinking: the cancelled question must not bring
        // the old conversation back when it unwinds.
        let hermes = ScriptedHermes([#"{"type":"answer","sentence":"One."}"#])
        let store = FakeHermesHistoryStore()
        let brain = HermesBrain(transport: hermes, toolbox: toolbox, allowedReads: { ["calendar", "weather"] },
                                isConfigured: { true }, store: store)
        _ = try await brain.answer("First", context: "") { _ in }
        #expect(brain.conversation.count == 3)

        hermes.delay = .seconds(30)
        let second = Task { try await brain.answer("Second", context: "") { _ in } }
        try await Task.sleep(for: .milliseconds(50))
        second.cancel()
        brain.endConversation()
        _ = await second.result

        #expect(brain.conversation.isEmpty)
        #expect(store.stored?.messages.isEmpty == true)
    }

    private static let plainReply = #"{"type":"answer","sentence":"yep."}"#
    private static let callReply = #"{"type":"call","calls":[{"id":"c1","tool":"weather","args":{}}]}"#

    private func isQuestion(_ message: ChatMessage) -> Bool {
        message.role == .user && message.content.contains("Jan: ")
    }

    @Test func historyIsCappedAtTheQuestionBoundary() async throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 0))
        // Alternating 2-message and 4-message rounds, so the cut lands inside a tool-call round.
        var replies: [String] = []
        for index in 0..<40 {
            if index % 2 == 1 { replies.append(Self.callReply) }
            replies.append(Self.plainReply)
        }
        let hermes = ScriptedHermes(replies)
        let store = FakeHermesHistoryStore()
        let brain = HermesBrain(transport: hermes, toolbox: toolbox, allowedReads: { ["calendar", "weather"] },
                                isConfigured: { true }, store: store, resetThreshold: { .seconds(7200) }, now: { clock.now })
        for index in 0..<40 {
            clock.now = Date(timeIntervalSince1970: TimeInterval(index * 60))
            _ = try await brain.answer("Q\(index)", context: "") { _ in }
            // The in-memory history is capped at the start of each question; one round may sit on top.
            #expect(brain.conversation.count <= HermesBrain.maxTurns + 1 + 4)
        }
        for session in store.saved where !session.messages.isEmpty {  // the first save is the empty pre-question state
            #expect(session.messages.count <= HermesBrain.maxTurns + 1 + 4)
            #expect(session.messages.first?.role == .system)
            let first = try #require(session.messages.dropFirst().first)
            #expect(isQuestion(first))
        }
        let last = try #require(store.saved.last)
        #expect(last.messages.count <= HermesBrain.maxTurns + 1)
        // Requests sent to Hermes stay bounded too, and never open with a results message.
        for request in hermes.requests {
            #expect(request.count <= HermesBrain.maxTurns + 1 + 4)
            #expect(request.first?.role == .system)
            #expect(request.dropFirst().first.map(isQuestion) == true)
        }
        #expect(brain.conversation.last?.role == .assistant)
        #expect(brain.conversation.contains { $0.content == "Jan: Q39" })
        #expect(!brain.conversation.contains { $0.content == "Jan: Q0" })
    }

    @Test func aSingleOversizedRoundIsKeptWhole() {
        var messages = [ChatMessage(.system, "prompt"), ChatMessage(.user, "Jan: old"), ChatMessage(.assistant, "x"),
                        ChatMessage(.user, "Jan: big")]
        for _ in 0..<30 {
            messages.append(ChatMessage(.assistant, Self.callReply))
            messages.append(ChatMessage(.user, HermesFormat.results([ToolResult(id: "c1", ok: true, content: "sunny")])))
        }
        messages.append(ChatMessage(.assistant, Self.plainReply))
        let capped = HermesBrain.capped(messages)
        #expect(capped.count == messages.count - 2)
        #expect(capped[1].content == "Jan: big")
    }

    @Test func aQuestionFailingMidRoundPersistsThePreQuestionState() async throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 0))
        let store = FakeHermesHistoryStore()
        // First question works; the second calls a tool, then Hermes has nothing left to say.
        let hermes = ScriptedHermes([Self.plainReply, Self.callReply])
        let brain = HermesBrain(transport: hermes, toolbox: toolbox, allowedReads: { ["calendar", "weather"] },
                                isConfigured: { true }, store: store, now: { clock.now })
        _ = try await brain.answer("First", context: "") { _ in }
        let committed = try #require(store.saved.last).messages
        clock.now = Date(timeIntervalSince1970: 60)
        await #expect(throws: (any Error).self) { _ = try await brain.answer("Second", context: "") { _ in } }
        let last = try #require(store.saved.last)
        #expect(last.messages == committed)
        #expect(brain.conversation == committed)
        #expect(last.lastAsked == Date(timeIntervalSince1970: 60))
        // No save in between ever held the half-finished round.
        for session in store.saved.dropFirst(2) { #expect(session.messages == committed) }
    }

    @Test func aCancelledQuestionPersistsThePreQuestionState() async throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 0))
        let store = FakeHermesHistoryStore()
        let hermes = ScriptedHermes([Self.plainReply, Self.plainReply])
        let brain = HermesBrain(transport: hermes, toolbox: toolbox, allowedReads: { ["calendar", "weather"] },
                                isConfigured: { true }, store: store, now: { clock.now })
        _ = try await brain.answer("First", context: "") { _ in }
        let committed = try #require(store.saved.last).messages
        clock.now = Date(timeIntervalSince1970: 60)
        hermes.delay = .seconds(5)
        let task = Task { @MainActor in try await brain.answer("Second", context: "") { _ in } }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = try? await task.value
        let last = try #require(store.saved.last)
        #expect(last.messages == committed)
        #expect(last.lastAsked == Date(timeIntervalSince1970: 60))
    }

    @Test func endConversationClearsAndPersists() async throws {
        let store = FakeHermesHistoryStore()
        let hermes = ScriptedHermes([#"{"type":"answer","sentence":"One."}"#])
        let brain = HermesBrain(transport: hermes, toolbox: toolbox,
                                allowedReads: { ["calendar", "weather"] }, isConfigured: { true }, store: store)
        _ = try await brain.answer("First", context: "") { _ in }
        brain.endConversation()
        #expect(brain.conversation.isEmpty)
        #expect(store.saved.last?.messages.isEmpty == true)
        #expect(store.saved.last?.lastAsked == nil)
    }
}

struct RouterTests {
    @Test(arguments: [
        "Brauche ich heute einen Schirm?", "Wie wird das Wetter?", "Stell einen Timer auf 10 Minuten",
        "Erinner mich morgen an die Wäsche", "Was steht morgen an?", "Wo bin ich?", "Wie komme ich zum Hauptbahnhof?",
    ])
    func simpleTasksStayLocal(_ question: String) {
        #expect(Router.route(question, hermesAvailable: true) == .local)
    }

    @Test func everythingElseGoesToHermesWithTheFallback() {
        #expect(Router.route("Wie geht's dir?", hermesAvailable: true) == .hermes("Wie geht's dir?", fallback: true))
        #expect(Router.route("Wie hoch ist der Eiffelturm?", hermesAvailable: true)
                == .hermes("Wie hoch ist der Eiffelturm?", fallback: true))
    }

    @Test func anotherPlaceGoesToHermes() {
        #expect(Router.route("Wie ist das Wetter in Lissabon?", hermesAvailable: true)
                == .hermes("Wie ist das Wetter in Lissabon?", fallback: true))
        #expect(Router.route("How far is it to Hamburg Airport from Berlin?", hermesAvailable: true) != .local)
        #expect(Router.route("Stell einen Timer für Pasta", hermesAvailable: true) == .local)  // actions stay local
        #expect(Router.route("Wie wird das Wetter morgen?", hermesAvailable: true) == .local)
    }

    @Test func onlyHermesKnowsSoNoFallback() {
        #expect(Router.route("Was kostet ein Bitcoin?", hermesAvailable: true) == .hermes("Was kostet ein Bitcoin?", fallback: false))
        #expect(Router.route("Hermes, plan my week", hermesAvailable: true) == .hermes("plan my week", fallback: false))
    }

    @Test func withoutHermesEverythingIsLocal() {
        #expect(Router.route("Wie geht's dir?", hermesAvailable: false) == .local)
        #expect(Router.route("Was kostet ein Bitcoin?", hermesAvailable: false) == .local)
    }

    @Test func resetPhrasesMatchWholeAndCaseInsensitively() {
        #expect(HermesRoute.resetRequest("Neues Gespräch"))
        #expect(HermesRoute.resetRequest("neuer chat"))
        #expect(HermesRoute.resetRequest("new chat"))
        #expect(HermesRoute.resetRequest("New conversation."))
        #expect(HermesRoute.resetRequest("start over"))
        #expect(HermesRoute.resetRequest("reset"))
        #expect(HermesRoute.resetRequest("Reset."))
        #expect(HermesRoute.resetConfirmation("Neues Gespräch") == "Neues Gespräch.")
        #expect(HermesRoute.resetConfirmation("new chat") == "New conversation.")

        #expect(!HermesRoute.resetRequest("reset my timer"))
        #expect(!HermesRoute.resetRequest("start over the meeting"))
        #expect(!HermesRoute.resetRequest("What's new?"))
    }
}
