import Foundation
import Testing
@testable import LottiKit

struct OfflineIntentsTests {
    @Test(arguments: [
        ("Stell einen Timer auf 10 Minuten", 10),
        ("Timer 5 Minuten", 5),
        ("Set a timer for 25 minutes", 25),
        ("set a timer for ten minutes for the pasta", 10),
        ("Timer für fünf Minuten", 5),
        ("Timer auf eine halbe Stunde", 30),
        ("timer for half an hour", 30),
        ("Timer für eine Stunde", 60),
        ("Timer 1 hour 30 minutes", 90),
        ("Timer 2 Stunden", 120),
        ("Timer 10", 10),
        ("Stell mir einen Timer auf 1,5 Stunden", 90),
        ("Eine Viertelstunde Timer bitte", 15),
    ])
    func timerMinutes(_ message: String, _ minutes: Int) {
        #expect(OfflineIntents.timerMinutes(message) == minutes)
    }

    @Test(arguments: ["Stell einen Timer", "Set a timer", "Timer auf 0 Minuten", "Timer 20 Stunden", "Wie wird das Wetter?"])
    func timerWithoutAUsableDuration(_ message: String) {
        #expect(OfflineIntents.timerMinutes(message) == nil)
    }

    @Test(arguments: [
        ("Wie komme ich von hier zum Media Markt Altenach?", "Media Markt Altenach", nil as String?),
        ("Walk me home", "home", nil),
        ("Bring mich nach Hause", "Zuhause", nil),
        ("Bring mich mit dem Rad zum Mauerpark", "Mauerpark", "bike"),
        ("navigiere mich zur nächsten Apotheke", "nächsten Apotheke", nil),
        ("Navigation zu Media Markt.", "Media Markt", nil),
        ("starte die Navigation zum nächstengelegenen MediaMarkt", "nächstengelegenen MediaMarkt", nil),
        ("Wo ist der nächste MediaMarkt?", "nächste MediaMarkt", nil),
        ("Where is the nearest pharmacy?", "nearest pharmacy", nil),
        ("We're done, take me to the Hauptbahnhof", "Hauptbahnhof", nil),
        ("Fährst du mich zum Zahnarzt?", "Zahnarzt", nil),
        ("Give me directions to the Späti", "Späti", nil),
        ("Bike me to the office, please", "office", "bike"),
        ("Bring mich zum Mauerpark mit dem Rad", "Mauerpark", "bike"),
    ])
    func destination(_ message: String, _ place: String, _ mode: String?) {
        let result = OfflineIntents.destination(message)
        #expect(result?.destination == place)
        #expect(result?.mode == mode)
    }

    @Test func navigationWithoutAPlaceHasNoDestination() {
        #expect(OfflineIntents.destination("Navigier mich") == nil)
    }

    @Test func remindersCarryTheirTextAndTime() {
        let a = OfflineIntents.reminder("Erinner mich morgen um 9 an die Wäsche")
        #expect(a?.text == "die Wäsche" && a?.due == "morgen 9:00")
        let b = OfflineIntents.reminder("Remind me to call Mara")
        #expect(b?.text == "call Mara" && b?.due == nil)
        #expect(OfflineIntents.reminder("Hello") == nil)
    }
}

@MainActor
struct OfflineBrainTests {
    func brain() -> (OfflineBrain, [String: FakeTool]) {
        let navigation = FakeTool("start_navigation", .action, parameters: [
            ToolParameter("destination", .string, "the place"),
            ToolParameter("mode", .oneOf(["walk", "bike"]), "how", optional: true),
        ])
        let fakes: [FakeTool] = [
            FakeTool.timer(), navigation, FakeTool("reminders", result: "Buy milk"),
            FakeTool("calendar", parameters: [ToolParameter("from", .string, "day", optional: true)], result: "09:30 Standup"),
            FakeTool("weather", result: "9°C"), FakeTool("location", result: "Hamburg"),
            FakeTool("create_reminder", .action, parameters: [
                ToolParameter("text", .string, "what"), ToolParameter("due", .string, "when", optional: true),
            ]),
        ]
        return (OfflineBrain(tools: Toolbox(fakes)), Dictionary(uniqueKeysWithValues: fakes.map { ($0.spec.name, $0) }))
    }

    func ask(_ brain: OfflineBrain, _ message: String) async throws -> Answer {
        try await brain.answer(message, context: "Now: Tuesday", status: { _ in })
    }

    @Test func timersWorkOffline() async throws {
        let (brain, tools) = brain()
        let answer = try await ask(brain, "Stell einen Timer auf 10 Minuten")
        #expect(answer.actions.map(\.title) == ["Timer 10 min"])
        #expect(answer.actions.first?.target == .phone)
        #expect(answer.sentence == "Bereit: Timer 10 min. Tipp zum Starten.")
        #expect(tools["set_timer"]!.runs.isEmpty)  // runs only when tapped
        let english = try await ask(brain, "Set a timer for 5 minutes")
        #expect(english.sentence == "Ready: Timer 5 min. Tap to start.")
    }

    @Test func navigationWorksOffline() async throws {
        let (brain, _) = brain()
        let answer = try await ask(brain, "Bring mich mit dem Rad zum Mauerpark")
        let action = try #require(answer.actions.first)
        #expect(action.tool == "start_navigation")
        #expect(action.arguments.string("destination") == "Mauerpark")
        #expect(action.arguments.string("mode") == "bike")
        let home = try await ask(brain, "Walk me home")
        #expect(home.actions.first?.arguments.string("destination") == "home")
    }

    @Test func aMissingDurationOrPlaceIsAskedFor() async throws {
        let (brain, _) = brain()
        #expect(try await ask(brain, "Stell einen Timer").sentence == "Wie viele Minuten soll der Timer laufen?")
        #expect(try await ask(brain, "Navigier mich").sentence == "Wohin soll es gehen?")
        #expect(try await ask(brain, "Set a timer").actions.isEmpty)
    }

    @Test func remindersAndTheLocalDayWork() async throws {
        let (brain, _) = brain()
        #expect(try await ask(brain, "Was steht auf meinen Erinnerungen?").sentence == "Buy milk")
        #expect(try await ask(brain, "Was steht morgen an?").sentence == "09:30 Standup")
        let reminder = try await ask(brain, "Remind me to call Mara")
        #expect(reminder.actions.first?.arguments.string("text") == "call Mara")
    }

    @Test func everythingElseGetsAShortOfflineSentence() async throws {
        let (brain, tools) = brain()
        let german = try await ask(brain, "Brauche ich heute einen Schirm?")
        #expect(german.sentence == LocalPipeline.offlineSentence(language: "German"))
        #expect(german.sentence.contains("offline"))
        let english = try await ask(brain, "Who won the game yesterday?")
        #expect(english.sentence == "I'm offline right now, so I can't help with that. Timers and navigation still work.")
        let location = try await ask(brain, "Where am I?")
        #expect(location.sentence.contains("offline"))
        #expect(tools["weather"]!.runs.isEmpty && tools["location"]!.runs.isEmpty)
        #expect(try await ask(brain, "How are you?").actions.isEmpty)
    }

    @Test func offlinePlanSeparatesWhatTheBackendDoes() {
        let names: Set<String> = ["set_timer", "start_navigation", "calendar", "weather", "location", "reminders", "create_reminder"]
        #expect(LocalPipeline.offlinePlan("Timer 5 Minuten", names: names) == .tools(["set_timer"]))
        #expect(LocalPipeline.offlinePlan("Walk me home", names: names) == .tools(["start_navigation"]))
        #expect(LocalPipeline.offlinePlan("Brauche ich einen Schirm?", names: names) == .unsupported)
        #expect(LocalPipeline.offlinePlan("Wo bin ich?", names: names) == .unsupported)
        #expect(LocalPipeline.offlinePlan("Termine und Wetter morgen?", names: names) == .tools(["calendar"]))
        #expect(LocalPipeline.offlinePlan("How are you?", names: names) == nil)
        #expect(LocalPipeline.offlineTools == ["set_timer", "start_navigation", "create_reminder", "reminders", "calendar"])
    }

    @Test func appleBrainParsesTimerAndNavigationArguments() {
        #expect(OfflineIntents.arguments(for: "set_timer", message: "Timer 10 Minuten") == ["minutes": 10])
        #expect(OfflineIntents.arguments(for: "start_navigation", message: "Walk me home") == ["destination": "home"])
        #expect(OfflineIntents.arguments(for: "calendar", message: "x") == nil)
    }
}

struct RouterTests {
    @Test func theBackendWinsWhenReachable() {
        #expect(Router.route(backendReachable: true) == .backend)
        #expect(Router.route(backendReachable: false) == .offline)
    }
}
