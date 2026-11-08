import Foundation
import Testing
@testable import LottiKit

/// A tool with a canned result, an optional delay, and a log of its runs.
final class FakeTool: PhoneTool, @unchecked Sendable {
    let spec: PhoneToolSpec
    var result: String
    var delay: Duration?
    var error: Error?
    private let lock = NSLock()
    private var _runs: [ToolArguments] = []
    var runs: [ToolArguments] { lock.withLock { _runs } }

    init(_ name: String, _ effect: PhoneToolSpec.Effect = .read, parameters: [ToolParameter] = [], result: String = "ok",
         delay: Duration? = nil, timeout: Duration? = nil) {
        spec = PhoneToolSpec(name: name, description: "Fake \(name).", parameters: parameters, effect: effect,
                             progress: "Checking \(name)…", timeout: timeout)
        self.result = result
        self.delay = delay
    }

    func run(_ arguments: ToolArguments) async throws -> String {
        lock.withLock { _runs.append(arguments) }
        if let delay { try await Task.sleep(for: delay) }
        if let error { throw error }
        return result
    }

    func title(for arguments: ToolArguments) -> String {
        spec.name == "set_timer" ? "Timer \(arguments.int("minutes") ?? 0) min" : spec.name
    }
}

extension FakeTool {
    static func timer() -> FakeTool {
        FakeTool("set_timer", .action, parameters: [
            ToolParameter("minutes", .integer, "Length in minutes"),
            ToolParameter("label", .string, "What it's for", optional: true),
        ], result: "Timer set for 10 minutes.")
    }
}

struct ToolboxTests {
    @Test func runsSeveralCallsAtOnceAndKeepsTheirOrder() async {
        // Each call takes 2 s: one after the other would take 4 s. The margin is for slow CI machines.
        let calendar = FakeTool("calendar", result: "Standup 9:30", delay: .seconds(2))
        let weather = FakeTool("weather", result: "12°, cloudy", delay: .seconds(2))
        let toolbox = Toolbox([calendar, weather])
        let started = Date()
        let results = await toolbox.run([ToolCall(id: "c1", tool: "calendar"), ToolCall(id: "c2", tool: "weather")],
                                        allowed: ["calendar", "weather"])
        #expect(Date().timeIntervalSince(started) < 3.6)
        #expect(results == [ToolResult(id: "c1", ok: true, content: "Standup 9:30"),
                            ToolResult(id: "c2", ok: true, content: "12°, cloudy")])
    }

    @Test func refusesUnknownToolsActionsAndUnsharedReads() async {
        let timer = FakeTool.timer()
        let toolbox = Toolbox([FakeTool("location"), timer])
        let results = await toolbox.run([
            ToolCall(id: "1", tool: "teleport"),
            ToolCall(id: "2", tool: "set_timer", arguments: ["minutes": 5]),
            ToolCall(id: "3", tool: "location"),
        ], allowed: [])
        #expect(results.map(\.ok) == [false, false, false])
        #expect(results[1].content.contains("actions"))
        #expect(results[2].content.contains("doesn't share"))
        #expect(timer.runs.isEmpty)
    }

    @Test func checksArguments() async {
        let tool = FakeTool("calendar", parameters: [
            ToolParameter("from", .string, ""),
            ToolParameter("days", .integer, "", optional: true),
            ToolParameter("kind", .oneOf(["work", "home"]), "", optional: true),
        ])
        let toolbox = Toolbox([tool])
        let missing = await toolbox.run([ToolCall(id: "1", tool: "calendar", arguments: ["days": 2])], allowed: ["calendar"])
        #expect(missing.first?.ok == false)
        #expect(missing.first?.content == "calendar: missing from")

        let coerced = await toolbox.run([ToolCall(id: "2", tool: "calendar",
                                                  arguments: ["from": "2026-11-02", "days": "3", "kind": "Work", "extra": 1])],
                                        allowed: ["calendar"])
        #expect(coerced.first?.ok == true)
        #expect(tool.runs.last == ToolArguments(["from": "2026-11-02", "days": 3, "kind": "work"]))

        let wrong = await toolbox.run([ToolCall(id: "3", tool: "calendar", arguments: ["from": "x", "days": 1.5])],
                                      allowed: ["calendar"])
        #expect(wrong.first?.content == "calendar: days should be an integer")
    }

    @Test func aSlowToolTimesOut() async {
        let toolbox = Toolbox([FakeTool("slow", delay: .seconds(5))], callTimeout: .milliseconds(100))
        let results = await toolbox.run([ToolCall(id: "1", tool: "slow")], allowed: ["slow"])
        #expect(results == [ToolResult(id: "1", ok: false, content: "slow took too long.")])
    }

    @Test func aToolCanTakeLongerThanTheToolboxDefault() async {
        let toolbox = Toolbox([FakeTool("slow", delay: .milliseconds(300), timeout: .seconds(30))],
                              callTimeout: .milliseconds(100))
        let results = await toolbox.run([ToolCall(id: "1", tool: "slow")], allowed: ["slow"])
        #expect(results == [ToolResult(id: "1", ok: true, content: "ok")])
    }

    @Test func aFailingToolReportsItsError() async {
        let tool = FakeTool("reminders")
        tool.error = ToolError("No access to reminders.")
        let results = await Toolbox([tool]).run([ToolCall(id: "1", tool: "reminders")], allowed: ["reminders"])
        #expect(results == [ToolResult(id: "1", ok: false, content: "No access to reminders.")])
    }

    @Test func actionsBecomeProposalsAndRunOnlyWhenPerformed() async {
        let timer = FakeTool.timer()
        let toolbox = Toolbox([timer, FakeTool("weather")])
        let proposal = toolbox.proposal(for: ToolCall(id: "a1", tool: "set_timer", arguments: ["minutes": 10, "label": "Pasta"]))
        #expect(proposal?.title == "Timer 10 min")
        #expect(timer.runs.isEmpty)
        #expect(toolbox.proposal(for: ToolCall(id: "a2", tool: "set_timer", arguments: [:])) == nil)
        #expect(toolbox.proposal(for: ToolCall(id: "a3", tool: "weather")) == nil)

        let result = await toolbox.perform(proposal!)
        #expect(result.ok)
        #expect(timer.runs == [ToolArguments(["minutes": 10, "label": "Pasta"])])
    }

    @Test func progressLine() {
        let toolbox = Toolbox([FakeTool("calendar"), FakeTool("weather")])
        #expect(toolbox.progress(for: [ToolCall(id: "1", tool: "calendar")]) == "Checking calendar…")
        #expect(toolbox.progress(for: [ToolCall(id: "1", tool: "calendar"), ToolCall(id: "2", tool: "weather")])
                == "Checking your phone…")
    }
}

struct ToolTextTests {
    var text: ToolText {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return ToolText(calendar: calendar)
    }
    var now: Date { text.moment("2026-11-01 14:05")! }

    @Test func readsDays() {
        #expect(text.dayName(text.day(nil, now: now)!) == "Sun 1 Nov")
        #expect(text.dayName(text.day("tomorrow", now: now)!) == "Mon 2 Nov")
        #expect(text.dayName(text.day("2026-11-05", now: now)!) == "Thu 5 Nov")
        #expect(text.day("next week", now: now) == nil)
        #expect(text.day("2026-02-31", now: now) == nil)
    }

    @Test func readsMoments() {
        #expect(text.dayAndTime(text.moment("2026-11-02 18:30")!) == "Mon 2 Nov 18:30")
        #expect(text.dayAndTime(text.moment("2026-11-02T07:15:00")!) == "Mon 2 Nov 07:15")
        #expect(text.dayAndTime(text.moment("2026-11-02")!) == "Mon 2 Nov 09:00")
        // ISO with a zone is an exact instant (the zone is honoured, not read as digits)
        #expect(text.moment("2026-11-02T07:15:00+01:00") == ISO8601DateFormatter().date(from: "2026-11-02T07:15:00+01:00"))
        #expect(text.moment("2026-11-02T06:15:00Z") == ISO8601DateFormatter().date(from: "2026-11-02T07:15:00+01:00"))
        // without seconds, with fractions, west of UTC; never digits with the zone dropped
        #expect(text.moment("2026-11-02T07:15+01:00") == ISO8601DateFormatter().date(from: "2026-11-02T07:15:00+01:00"))
        #expect(text.moment("2026-11-02T06:15Z") == ISO8601DateFormatter().date(from: "2026-11-02T07:15:00+01:00"))
        #expect(text.moment("2026-11-02T01:15-05:00") == ISO8601DateFormatter().date(from: "2026-11-02T07:15:00+01:00"))
        #expect(text.moment("2026-11-02T07:15:00.250+01:00") == ISO8601DateFormatter().date(from: "2026-11-02T07:15:00+01:00")!.addingTimeInterval(0.25))
        #expect(text.moment("2026-02-31T09:00:00Z") == nil)
        #expect(text.moment("2026-11-02T07:1+01:00") == nil)
        #expect(text.moment("2026-11-02 01:15:00-05:00") == ISO8601DateFormatter().date(from: "2026-11-02T07:15:00+01:00"))
        // day() lowers the text first; a zoned ISO day still counts
        #expect(text.day("2026-11-02T00:30:00+01:00", now: now) == text.moment("2026-11-02 00:00"))
    }

    @Test func describesEventsPerDay() {
        let day = text.day("2026-11-02", now: now)!
        let events = [
            CalendarEntry(title: "Ben", start: text.moment("2026-11-02 11:00")!, end: text.moment("2026-11-02 12:00")!,
                          location: "Café"),
            CalendarEntry(title: "Standup", start: text.moment("2026-11-02 09:30")!, end: text.moment("2026-11-02 09:45")!),
            CalendarEntry(title: "Holiday", start: text.moment("2026-11-04 00:00")!, end: text.moment("2026-11-05 00:00")!,
                          isAllDay: true),
        ]
        #expect(text.events(events, from: day, days: 3) == """
            Mon 2 Nov: 09:30–09:45 Standup; 11:00–12:00 Ben (Café)
            Tue 3 Nov: nothing
            Wed 4 Nov: all day: Holiday
            """)
    }
}

struct LocalPipelineTests {
    let specs = ["location", "start_navigation", "calendar", "weather", "reminders", "set_timer", "create_reminder"].map {
        PhoneToolSpec(name: $0, description: "", effect: .read, progress: "")
    }

    @Test(arguments: [
        ("Wo bin ich?", ["location"]),
        ("Where am I right now?", ["location"]),
        ("Was steht morgen an?", ["calendar"]),
        ("What's on tomorrow?", ["calendar"]),
        ("Hab ich heute noch Termine?", ["calendar"]),
        ("Brauche ich heute einen Schirm?", ["weather"]),
        ("Erinner mich morgen um 9 an die Wäsche", ["create_reminder"]),
        ("Remind me to call Mara", ["create_reminder"]),
        ("Was steht auf meinen Erinnerungen?", ["reminders"]),
        ("Stell einen Timer auf 10 Minuten", ["set_timer"]),
        ("Termine und Wetter morgen?", ["calendar", "weather"]),
        ("Wie komme ich von hier zum Media Markt Altenach?", ["start_navigation"]),
        ("Walk me home", ["start_navigation"]),
        ("Bring mich mit dem Rad zum Mauerpark", ["start_navigation"]),
        ("navigiere mich zur nächsten Apotheke", ["start_navigation"]),
        ("Navigation zu Media Markt.", ["start_navigation"]),
        ("starte die Navigation zum nächstengelegenen MediaMarkt", ["start_navigation"]),
        ("Wo ist der nächste MediaMarkt?", ["start_navigation"]),
        ("Where is the nearest pharmacy?", ["start_navigation"]),
        ("We're done, take me to the Hauptbahnhof", ["start_navigation"]),
        ("lotse mich zum nächsten Späti", ["start_navigation"]),
        ("Fährst du mich zum Zahnarzt?", ["start_navigation"]),
        ("Give me directions to the Späti", ["start_navigation"]),
    ])
    func rulesPickTools(_ message: String, _ tools: [String]) {
        #expect(LocalPipeline.ruleTools(message, tools: specs) == tools)
    }

    @Test(arguments: [
        "How far is the main station?",
        "Wie lange brauche ich zum Hauptbahnhof?",
        "How long does it take to walk to the office?",
        "Wie weit ist es noch bis zum Mauerpark?",
        "Walk me through the setup",
    ])
    func distanceQuestionsHaveNoRule(_ message: String) {
        // A distance / duration question is not "start navigating": the rule must not match.
        #expect(!(LocalPipeline.ruleTools(message, tools: specs) ?? []).contains("start_navigation"))
    }

    @Test func noRuleLeavesItToTheModel() {
        #expect(LocalPipeline.ruleTools("How are you?", tools: specs) == nil)
        #expect(LocalPipeline.ruleTools("Wie hoch ist der Eiffelturm?", tools: specs) == nil)
        #expect(LocalPipeline.ruleTools("Was kostet gerade ein Bitcoin?", tools: specs) == nil)
        #expect(LocalPipeline.ruleTools("Wo bin ich?", tools: []) == nil)
    }

    @Test func detectsTheLanguage() {
        #expect(LocalPipeline.language(of: "Wie spät ist es?") == "German")
        #expect(LocalPipeline.language(of: "How are you?") == "English")
        #expect(LocalPipeline.language(of: "Wo bin ich?") == "German")
    }

    @Test func parsesTheChoiceFromLabels() {
        let json: JSONValue = ["intent": "remind", "tools": ["remind_me_later", "weather", "weather", "nonsense"]]
        #expect(LocalPipeline.parseChoice(json, tools: specs).tools == ["create_reminder"])  // weather is the backend's
        #expect(LocalPipeline.parseChoice(["tools": ["hermes_web_news_research"]], tools: specs).tools == [])
        #expect(LocalPipeline.parseChoice(["tools": ["where_jan_is", "jan_calendar"]], tools: specs).tools == ["calendar"])  // location is the backend's
    }

    @Test func fixedSentencesForActions() {
        let timer = ProposedAction(tool: "set_timer", arguments: ToolArguments(), title: "Timer 10 min")
        #expect(LocalPipeline.preparedSentence([timer], language: "German") == "Bereit: Timer 10 min. Tipp zum Starten.")
        #expect(LocalPipeline.preparedSentence([timer], language: "English") == "Ready: Timer 10 min. Tap to start.")
    }

    @Test func historyCarriesFacts() {
        let turn = LocalPipeline.Turn(jan: "What's on tomorrow?", lotti: "Standup at 9:30.",
                                      facts: [LocalPipeline.Fact(tool: "calendar", text: "11:00 Ben (Café)")])
        let prompt = LocalPipeline.answerPrompt("Where is Ben?", now: "Now: Sunday", history: [turn], facts: [])
        #expect(prompt.contains("(Jan's calendar: 11:00 Ben (Café))"))
        #expect(!prompt.contains("Berlin"))
    }
}

struct UnsureAnswerTests {
    @Test func noticesUnsureAnswers() {
        #expect(LocalPipeline.soundsUnsure("Ich weiß nicht, wie du zum Media Markt Altenach kommst."))
        #expect(LocalPipeline.soundsUnsure("I don't know that, sorry."))
        #expect(LocalPipeline.soundsUnsure("Das kann ich dir nicht sagen."))
        #expect(!LocalPipeline.soundsUnsure("Du bist an der Großen Elbstraße 39."))
    }
}
