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
        _ = try await brain.answer("Second", context: "Now: Sunday") { _ in }
        #expect(hermes.requests[1].map(\.role) == [.system, .user, .assistant, .user])
        #expect(hermes.requests[1].last?.content == "Jan: Second")

        brain.endConversation()
        hermes.replies = [#"{"type":"answer","sentence":"Three."}"#]
        _ = try await brain.answer("Third", context: "Now: Monday") { _ in }
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
}
