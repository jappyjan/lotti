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
    /// The session id of every request, in order.
    private(set) var sessions: [String] = []

    init(_ replies: [String]) { self.replies = replies }

    func complete(_ messages: [ChatMessage], session: String, progress report: @escaping @Sendable (String) -> Void) async throws -> String {
        requests.append(messages)
        sessions.append(session)
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

    func complete(_ messages: [ChatMessage], session: String, progress report: @escaping @Sendable (String) -> Void) async throws -> String {
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

    @Test func passesHermesProgressOn() async throws {
        let hermes = ScriptedHermes([#"{"type":"answer","sentence":"Done."}"#])
        hermes.progress = ["Searching the web"]
        hermes.delay = .milliseconds(50)
        var statuses: [String] = []
        _ = try await brain(hermes).answer("News?", context: "") { statuses.append($0) }
        #expect(statuses == ["Searching the web"])
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
}
