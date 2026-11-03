import Foundation
import Testing
@testable import LottiKit

/// The Conductor with a real `BackendClient` talking to the in-process `MockBackend`.
@MainActor
struct ConductorBackendTests {
    let link = FakeGlassesLink()
    let brain = FakeBrain()
    let backend = MockBackend()
    let client: BackendClient
    let conductor: Conductor

    static let mail1 = #"{"id":"m1","kind":"mail","title":"Mara","summary":"Pizza um 8?","body":"Kommst du noch um 8?","createdAt":"2026-11-03T08:15:00+01:00","status":"pending"}"#
    static let mail2 = #"{"id":"m2","kind":"mail","title":"Ben","summary":"Rechnung","body":"Die Rechnung ist da.","createdAt":"2026-11-03T08:10:00+01:00","status":"pending"}"#
    static let job = #"{"id":"j1","kind":"job","title":"Backup","summary":"Fertig","body":"Backup ok.","createdAt":"2026-11-03T08:00:00+01:00","status":"pending","actions":[{"id":"act1","title":"Neu starten","target":"server"}]}"#

    init(reachable: Bool = true, locationAfter: Duration = .milliseconds(100)) async throws {
        await link.connect(DiscoveredGlasses(id: "32", name: "G2"))
        client = Fixtures.client(backend, start: reachable)
        conductor = Conductor(
            link: link, brain: brain, remote: BackendBrain(client: client), backend: client, speech: FakeSpeech(),
            today: FixedToday(info: TodayInfo(now: Date())), inboxSummary: InboxSummary(german: true),
            timing: .init(idle: .seconds(5), done: .milliseconds(100), answer: .milliseconds(300),
                          finalTranscript: .milliseconds(200), remote: .seconds(2), locationAfter: locationAfter))
        if reachable { try await eventually { client.isReachable } }
    }

    func press(_ gesture: InputEvent.Gesture) { conductor.handle(InputEvent(gesture, from: .ring)) }

    func fill(_ items: String...) async throws {
        backend.send(#"{"type":"inbox","full":true,"items":[\#(items.joined(separator: ","))],"removedIds":[]}"#)
        try await eventually { client.inbox.items.count == items.count }
    }

    var attention: G2ImageBox? { link.frames.last?.images.first { $0.id == G2ImageBox.attentionID } }

    // MARK: Attention indicator

    @Test func aPushShowsOnlyTheIndicatorNeverAScreen() async throws {
        try await fill()
        backend.send(#"{"type":"push","item":\#(Self.mail1)}"#)
        try await eventually { attention != nil }
        #expect(conductor.mode == .off && conductor.screen == nil)
        #expect(link.frames.last?.isDark == true)  // the display stays off; only the icon is lit
        #expect(link.frames.last?.images.count == 1)
        // A second push of the same kind only changes the count.
        let before = attention
        backend.send(#"{"type":"push","item":\#(Self.mail2)}"#)
        try await eventually { attention != nil && attention != before }
        #expect(conductor.mode == .off && conductor.screen == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(link.frames.allSatisfy { $0.main.isEmpty && $0.rail == nil })  // never any text on the display
    }

    @Test func anItemWhileSomethingElseIsOnTheDisplayDoesNotOpenOrInterrupt() async throws {
        brain.answers = [:]
        conductor.ask("Hi")
        try await eventually { conductor.mode == .showing }
        let screen = conductor.screen
        backend.send(#"{"type":"push","item":\#(Self.mail1)}"#)
        try await eventually { client.inbox.items.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(conductor.screen == screen && conductor.mode == .showing)
        #expect(link.frames.last?.images.isEmpty == true)  // never over Lotti's sentence
    }

    @Test func theIndicatorDisappearsWhenTheInboxIsEmpty() async throws {
        try await fill(Self.mail1, Self.job)
        try await eventually { attention != nil }
        backend.send(#"{"type":"inbox","full":false,"items":[],"removedIds":["m1","j1"]}"#)  // dismissed by voice
        try await eventually { link.frames.last?.images.isEmpty == true }
        #expect(link.frames.last == .dark)
    }

    @Test func theIndicatorGoesWhenTheDisplayOpensAndComesBackWhenItCloses() async throws {
        try await fill(Self.mail1)
        try await eventually { attention != nil }
        press(.doubleTap)
        try await eventually { link.frames.last?.images.isEmpty == true && link.frames.last?.isDark == false }
        press(.doubleTap)
        try await eventually { attention != nil && link.frames.last?.isDark == true }
    }

    // MARK: Today view

    @Test func todayShowsAShortSummaryAndAChoiceForTheList() async throws {
        try await fill(Self.mail1, Self.mail2, Self.job)
        press(.doubleTap)
        try await eventually { conductor.screen?.text.hasPrefix("2 Mails, 1 Job. ") == true }
        #expect(conductor.screen?.rail?.items.first?.title == "Alle ansehen")
        #expect(conductor.screen?.rail?.items.first?.action == .openInbox(page: 0))
        // shown is reported once per item
        try await eventually { backend.received(type: "inbox_event").count == 3 }
        #expect(Set(backend.received(type: "inbox_event").map { $0["itemId"]?.string }) == ["m1", "m2", "j1"])
        #expect(backend.received(type: "inbox_event").allSatisfy { $0["event"]?.string == "shown" })
    }

    @Test func noPendingItemsLeavesTodayAsItWas() async throws {
        press(.doubleTap)
        try await eventually { link.frames.last?.main.contains("Your calendar is free today.") == true }
        #expect(conductor.screen?.rail == nil)
    }

    @Test func theListOpensAnItemInFullAndReportsOpened() async throws {
        try await fill(Self.mail1, Self.mail2, Self.job)
        press(.doubleTap)
        try await eventually { conductor.screen?.rail?.items.first?.action == .openInbox(page: 0) }
        press(.tap)
        try await eventually { conductor.screen?.kind == .list }
        #expect(conductor.screen?.text == "3 offen.")
        #expect(conductor.screen?.rail?.items.map(\.title) == ["Mail: Mara", "Mail: Ben", "Job: Backup"])

        press(.tap)  // Mara first: newest first
        try await eventually { conductor.screen?.kind == .original }
        #expect(conductor.screen?.text == "Kommst du noch um 8?")  // word for word
        #expect(conductor.screen?.details == ["Mail · Mara"])
        #expect(conductor.screen?.rail?.items.map(\.title) == ["Verwerfen"])
        try await eventually { backend.received(type: "inbox_event").contains { $0["event"]?.string == "opened" && $0["itemId"]?.string == "m1" } }
        #expect(client.inbox.item("m1")?.status == .seen)

        press(.doubleTap)  // back to the list
        #expect(conductor.screen?.kind == .list)
    }

    @Test func dismissGoesBackToTheListWithoutTheItem() async throws {
        try await fill(Self.mail1, Self.mail2)
        press(.doubleTap)
        try await eventually { conductor.screen?.rail?.items.first?.action == .openInbox(page: 0) }
        press(.tap)
        try await eventually { conductor.screen?.kind == .list }
        press(.tap)  // Mara
        try await eventually { conductor.screen?.kind == .original }
        press(.tap)  // Verwerfen
        try await eventually { conductor.screen?.kind == .list }
        #expect(conductor.screen?.rail?.items.map(\.title) == ["Mail: Ben"])
        try await eventually { backend.received(type: "inbox_event").contains { $0["event"]?.string == "dismissed" && $0["itemId"]?.string == "m1" } }

        // Dismiss the last one: nothing left, a short done line.
        press(.tap)
        try await eventually { conductor.screen?.kind == .original }
        press(.tap)
        try await eventually { conductor.screen?.text == "Verworfen." }
        #expect(conductor.mode == .done)
        try await eventually { conductor.mode == .off }
        try await eventually { link.frames.last == .dark }  // and no indicator: nothing is pending
    }

    @Test func anItemsServerActionRunsThroughPerformAndOffersUndo() async throws {
        backend.script = { frame in
            switch frame["type"]?.string {
            case "perform":
                return [#"{"type":"performed","id":"\#(frame["id"]!.string!)","ok":true,"text":"Neu gestartet.","undo":{"id":"u1","label":"Rückgängig"}}"#]
            case "undo":
                return [#"{"type":"performed","id":"\#(frame["id"]!.string!)","ok":true,"text":"Zurückgenommen."}"#]
            default: return MockBackend.defaultReply(frame)
            }
        }
        try await fill(Self.job)
        press(.doubleTap)
        try await eventually { conductor.screen?.rail?.items.first?.action == .openInbox(page: 0) }
        press(.tap)
        try await eventually { conductor.screen?.kind == .list }
        press(.tap)
        try await eventually { conductor.screen?.kind == .original }
        #expect(conductor.screen?.rail?.items.map(\.title) == ["Neu starten", "Verwerfen"])
        press(.tap)  // Neu starten
        try await eventually { conductor.screen?.text == "Neu gestartet." }
        #expect(backend.received(type: "perform")[0]["actionId"]?.string == "act1")
        #expect(conductor.screen?.rail?.items.map(\.title) == ["Rückgängig"])
        press(.tap)
        try await eventually { conductor.screen?.text == "Zurückgenommen." }
        #expect(backend.received(type: "undo")[0]["undoId"]?.string == "u1")
        #expect(conductor.mode == .done)
    }

    // MARK: Catch-up

    @Test func aCatchupShowsAsAShortAnswerWhenTheDisplayIsOff() async throws {
        backend.send(#"{"type":"catchup","id":"k1","text":"Zwei Mails, nichts Dringendes.","at":"2026-11-03T08:15:00+01:00"}"#)
        try await eventually { conductor.screen?.text == "Zwei Mails, nichts Dringendes." }
        #expect(conductor.screen?.kind == .says && conductor.screen?.rail == nil)
        #expect(client.lastCatchup?.id == "k1")  // and the phone chat has it
    }

    @Test func aCatchupNeverInterruptsAConversation() async throws {
        conductor.ask("Hi")
        try await eventually { conductor.mode == .showing }
        let screen = conductor.screen
        backend.send(#"{"type":"catchup","id":"k1","text":"Während du weg warst …","at":"2026-11-03T08:15:00+01:00"}"#)
        try await eventually { client.lastCatchup != nil }
        try await Task.sleep(for: .milliseconds(30))
        #expect(conductor.screen == screen)
    }

    // MARK: Location indicator

    @Test func theLocationIconShowsWhileTheBackendReadsAndBrieflyAfter() async throws {
        func location() -> G2ImageBox? { link.frames.last?.images.first { $0.id == G2ImageBox.locationID } }
        backend.send(#"{"type":"location_access","phase":"start","callId":"t1","at":"2026-11-03T08:15:00+01:00"}"#)
        try await eventually { location() != nil }
        #expect(conductor.locationActive && conductor.mode == .off && link.frames.last?.isDark == true)
        backend.send(#"{"type":"location_access","phase":"end","callId":"t1","at":"2026-11-03T08:15:02+01:00"}"#)
        try await Task.sleep(for: .milliseconds(40))
        #expect(location() != nil)  // still there a moment after
        try await eventually { location() == nil }
        #expect(!conductor.locationActive)
    }

    @Test func theLocationIconStaysWhileAnotherReadRuns() async throws {
        func location() -> G2ImageBox? { link.frames.last?.images.first { $0.id == G2ImageBox.locationID } }
        backend.send(#"{"type":"location_access","phase":"start","callId":"t1","at":"2026-11-03T08:15:00+01:00"}"#)
        backend.send(#"{"type":"location_access","phase":"start","callId":"t2","at":"2026-11-03T08:15:00+01:00"}"#)
        backend.send(#"{"type":"location_access","phase":"end","callId":"t1","at":"2026-11-03T08:15:01+01:00"}"#)
        try await eventually { location() != nil }
        try await Task.sleep(for: .milliseconds(250))
        #expect(location() != nil)
    }

    @Test func theLocationIconDoesNotCoverTheChoices() async throws {
        backend.script = { frame in
            guard frame["type"]?.string == "ask" else { return MockBackend.defaultReply(frame) }
            return [#"{"type":"answer","id":"\#(frame["id"]!.string!)","text":"Hier ist es.","followUps":["Route","Mehr"],"actions":[]}"#]
        }
        conductor.ask("Wo ist das Café?")
        try await eventually { conductor.screen?.rail != nil }
        backend.send(#"{"type":"location_access","phase":"start","callId":"t1","at":"2026-11-03T08:15:00+01:00"}"#)
        try await eventually { conductor.locationActive }
        try await Task.sleep(for: .milliseconds(30))
        // Choices are up: the bottom right belongs to them, so no icon is drawn.
        #expect(link.frames.last?.rail != nil && link.frames.last?.images.isEmpty == true)
    }

    // MARK: Questions through the real client

    @Test func aQuestionGoesToTheBackendOverTheSocket() async throws {
        backend.script = { frame in
            guard frame["type"]?.string == "ask" else { return MockBackend.defaultReply(frame) }
            let id = frame["id"]!.string!
            return [#"{"type":"status","id":"\#(id)","text":"Suche Mails …"}"#,
                    #"{"type":"answer","id":"\#(id)","text":"Zwei Mails von Mara.","followUps":["Original"],"actions":[]}"#]
        }
        conductor.ask("Was gibt es Neues?")
        try await eventually { conductor.screen?.text == "Zwei Mails von Mara." }
        #expect(conductor.screen?.rail?.items.map(\.title) == ["Original"])
        #expect(brain.asked.isEmpty)
        #expect(backend.received(type: "ask")[0]["channel"]?.string == "glasses")
    }

    @Test func withoutASocketTheOfflineBrainAnswers() async throws {
        let offline = try await ConductorBackendTests(reachable: false)
        offline.brain.answers = ["Timer 5 Minuten": Answer(sentence: "Bereit: Timer 5 min. Tipp zum Starten.")]
        offline.conductor.ask("Timer 5 Minuten")
        try await eventually { offline.conductor.screen?.text == "Bereit: Timer 5 min. Tipp zum Starten." }
        #expect(offline.backend.connectCount == 0)
    }

    @Test func aServerActionFromAnAnswerRunsThroughPerform() async throws {
        backend.script = { frame in
            switch frame["type"]?.string {
            case "ask":
                return [#"{"type":"answer","id":"\#(frame["id"]!.string!)","text":"Soll ich Milch auf die Liste setzen?","followUps":[],"actions":[{"id":"a1","title":"Ja, Milch","target":"server"}]}"#]
            case "perform":
                return [#"{"type":"performed","id":"\#(frame["id"]!.string!)","ok":true,"text":"Milch ist drauf."}"#]
            default: return MockBackend.defaultReply(frame)
            }
        }
        conductor.ask("Milch")
        try await eventually { conductor.screen?.rail?.current?.title == "Ja, Milch" }
        press(.tap)
        try await eventually { conductor.screen?.text == "Milch ist drauf." }
        #expect(conductor.mode == .done)
        #expect(backend.received(type: "perform")[0]["actionId"]?.string == "a1")
    }

    @Test func aFailedServerActionSaysWhy() async throws {
        backend.script = { frame in
            switch frame["type"]?.string {
            case "ask":
                return [#"{"type":"answer","id":"\#(frame["id"]!.string!)","text":"Ok?","followUps":[],"actions":[{"id":"a1","title":"Los","target":"server"}]}"#]
            case "perform":
                return [#"{"type":"performed","id":"\#(frame["id"]!.string!)","ok":false,"text":"Bring! ist offline."}"#]
            default: return MockBackend.defaultReply(frame)
            }
        }
        conductor.ask("x")
        try await eventually { conductor.screen?.rail?.current?.title == "Los" }
        press(.tap)
        try await eventually { conductor.screen?.text == "That didn't work: Bring! ist offline." }
    }

    @Test func answerImmediateActionUndoGoesThroughTheBackend() async throws {
        backend.script = { frame in
            switch frame["type"]?.string {
            case "ask":
                return [#"{"type":"answer","id":"\#(frame["id"]!.string!)","text":"Milch ist auf der Liste.","followUps":[],"actions":[],"undo":{"id":"u7","label":"Rückgängig"}}"#]
            case "undo":
                return [#"{"type":"performed","id":"\#(frame["id"]!.string!)","ok":true,"text":"Milch ist wieder runter."}"#]
            default: return MockBackend.defaultReply(frame)
            }
        }
        conductor.ask("Milch auf die Liste")
        try await eventually { conductor.screen?.rail?.current?.title == "Rückgängig" }
        press(.tap)
        try await eventually { conductor.screen?.text == "Milch ist wieder runter." }
        #expect(backend.received(type: "undo")[0]["undoId"]?.string == "u7")
    }

    // MARK: Presence

    @Test func presenceSignalsGoToTheBackend() async throws {
        conductor.handle(InputEvent(.worn, from: .glasses))
        conductor.handle(InputEvent(.headUp, from: .imu))
        conductor.handle(InputEvent(.headDown, from: .imu))
        conductor.handle(InputEvent(.scrollDown, from: .ring))
        conductor.handle(InputEvent(.tap, from: .ring))
        conductor.handle(InputEvent(.tap, from: .ring))  // throttled
        conductor.handle(InputEvent(.removed, from: .glasses))
        await conductor.glassesConnected()
        conductor.glassesDisconnected()
        try await eventually { backend.received(type: "presence").count == 6 }
        #expect(backend.received(type: "presence").map { $0["event"]?.string } == [
            "glasses_worn", "head_up", "gesture", "glasses_removed", "glasses_connected", "glasses_disconnected",
        ])
        #expect(backend.received(type: "presence")[2]["detail"]?.string == "tap")
    }

    @Test func takingTheGlassesOffTurnsTheDisplayOff() async throws {
        press(.doubleTap)
        #expect(conductor.mode == .today(byHead: false))
        conductor.handle(InputEvent(.removed, from: .glasses))
        #expect(conductor.mode == .off)
    }

    @Test func wearingThemChangesNothingOnTheDisplay() async throws {
        conductor.handle(InputEvent(.worn, from: .glasses))
        #expect(conductor.mode == .off && conductor.screen == nil)
    }
}
