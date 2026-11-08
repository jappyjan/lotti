import Foundation
import Testing
@testable import LottiKit

@MainActor
struct BackendClientTests {
    let backend = MockBackend()

    func ready(tools: [any PhoneTool] = [], toolTimeout: Duration = .seconds(10)) async throws -> BackendClient {
        let client = Fixtures.client(backend, tools: tools, toolTimeout: toolTimeout)
        try await eventually { client.isReachable }
        return client
    }

    // MARK: Connection

    @Test func sendsHelloAndBecomesReachableOnWelcome() async throws {
        let client = try await ready()
        let hello = try #require(backend.received(type: "hello").first)
        #expect(hello["appVersion"]?.string == "1.0")
        #expect(hello["deviceName"]?.string == "Jan's iPhone")
        #expect(backend.headers == ["wss://brain.test/ws Bearer tok"])
        #expect(client.welcome?.conversationId == "c1")
        #expect(client.welcome?.settings["activeProvider"] == "test")
        // The backend sends the whole inbox after `welcome` by itself: no `inbox_sync` on connect.
        try await Task.sleep(for: .milliseconds(50))
        #expect(backend.received(type: "inbox_sync").isEmpty)
    }

    @Test func reconnectsWithBackoffAfterADrop() async throws {
        let client = try await ready()
        backend.refuse(2)
        backend.drop()
        try await eventually { !client.isReachable }
        try await eventually { client.isReachable && backend.connectCount == 4 }
    }

    @Test func reconnectNowSkipsTheWait() async throws {
        let slow = ReconnectPolicy(initial: .seconds(30), maximum: .seconds(30))
        let client = Fixtures.client(backend, policy: slow, start: false)
        backend.refuse(1)
        client.start()
        try await eventually { backend.connectCount == 1 }
        try await eventually { client.state == .disconnected && client.lastError != nil }
        client.reconnectNow()
        try await eventually { client.isReachable }
        #expect(backend.connectCount == 2)
    }

    @Test func stoppingForgetsTheLastError() async throws {
        let slow = ReconnectPolicy(initial: .seconds(30), maximum: .seconds(30))
        let client = Fixtures.client(backend, policy: slow, start: false)
        backend.refuse(1)
        client.start()
        try await eventually { client.state == .disconnected && client.lastError != nil }
        client.stop()
        #expect(client.lastError == nil)
    }

    @Test func reconnectNowOnALiveSocketOnlyChecksIt() async throws {
        let client = try await ready()
        let before = backend.connectCount
        client.reconnectNow()
        try await eventually { backend.received(type: "inbox_sync").count == 1 }
        #expect(backend.connectCount == before)
    }

    @Test func notPairedStaysDisconnected() async throws {
        let client = BackendClient(transport: backend, configuration: nil)
        client.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.state == .disconnected)
        #expect(backend.connectCount == 0)
        client.stop()
    }

    @Test func backoffDoublesUpToTheMaximum() {
        let policy = ReconnectPolicy(initial: .seconds(1), maximum: .seconds(30))
        #expect([0, 1, 2, 3, 4, 5, 6, 20].map { policy.delay(attempt: $0) } == [1, 2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
    }

    @Test func socketURLFollowsTheBaseURL() {
        #expect(Fixtures.config.socketURL?.absoluteString == "wss://brain.test/ws")
        var lan = Fixtures.config
        lan.baseURL = URL(string: "http://192.168.1.5:8080/")!
        #expect(lan.socketURL?.absoluteString == "ws://192.168.1.5:8080/ws")
    }

    // MARK: Asking

    @Test func askReturnsTheAnswerAndForwardsStatusLines() async throws {
        backend.script = { frame in
            guard frame["type"]?.string == "ask" else { return MockBackend.defaultReply(frame) }
            let id = frame["id"]!.string!
            return [#"{"type":"status","id":"\#(id)","text":"Suche Mails …"}"#,
                    #"{"type":"answer","id":"\#(id)","conversationId":"c1","text":"Zwei Mails von Mara.","followUps":["Original","Antworten","a","b"],"actions":[]}"#]
        }
        let client = try await ready()
        var statuses: [String] = []
        var activity = 0
        let answer = try await client.ask("Was gibt es Neues?", channel: .glasses, status: { statuses.append($0) }, activity: { activity += 1 })
        #expect(answer.text == "Zwei Mails von Mara.")
        #expect(statuses == ["Suche Mails …"])
        #expect(activity == 1)
        #expect(answer.answer.followUps.count == 3)  // Answer keeps at most three

        let ask = try #require(backend.received(type: "ask").first)
        #expect(ask["text"]?.string == "Was gibt es Neues?")
        #expect(ask["channel"]?.string == "glasses")
        #expect(ask["locale"]?.string == "de")
        #expect(ask["now"]?.string?.contains("T") == true)
        #expect(BackendDates.parse(ask["now"]?.string ?? "") != nil)
    }

    @Test func askIdsAreUUIDs() async throws {
        let client = try await ready()
        _ = try await client.ask("Hi")
        _ = try await client.ask("Hi again")
        let ids = backend.received(type: "ask").compactMap { $0["id"]?.string }
        #expect(ids.count == 2 && Set(ids).count == 2)
        #expect(ids.allSatisfy { UUID(uuidString: $0) != nil })
    }

    @Test func aSilentBackendFailsTheAskAsUnreachableAndReconnects() async throws {
        // The socket looks open but nothing comes back for the ask: not even a status line.
        backend.script = { frame in frame["type"]?.string == "ask" ? [] : MockBackend.defaultReply(frame) }
        let client = Fixtures.client(backend, firstFrameTimeout: .milliseconds(150))
        try await eventually { client.isReachable }
        await #expect(throws: BackendError.unreachable) { try await client.ask("Hi") }
        try await eventually { backend.connectCount == 2 && client.isReachable }
    }

    @Test func aStatusLineKeepsTheAskAlive() async throws {
        backend.script = { frame in
            guard frame["type"]?.string == "ask" else { return MockBackend.defaultReply(frame) }
            return [#"{"type":"status","id":"\#(frame["id"]!.string!)","text":"Denke nach …"}"#]
        }
        // The mock answers the ask with the status line at once; the limit leaves a stalled
        // runner a second to deliver it.
        let client = Fixtures.client(backend, firstFrameTimeout: .seconds(1))
        try await eventually { client.isReachable }
        let task = Task { try await client.ask("Hi") }
        try await eventually { !backend.received(type: "ask").isEmpty }
        try await Task.sleep(for: .milliseconds(1500))  // past the first-frame limit: the status line kept it alive
        #expect(client.isReachable && backend.connectCount == 1)
        let id = backend.received(type: "ask")[0]["id"]!.string!
        backend.send(#"{"type":"answer","id":"\#(id)","conversationId":"c1","text":"Spät, aber da.","followUps":[],"actions":[]}"#)
        #expect(try await task.value.text == "Spät, aber da.")
    }

    @Test func askingWithoutASocketThrowsUnreachable() async throws {
        let client = Fixtures.client(backend, start: false)
        await #expect(throws: BackendError.unreachable) { try await client.ask("Hi") }
    }

    @Test func aDropWhileWaitingThrowsUnreachable() async throws {
        backend.script = { frame in frame["type"]?.string == "ask" ? [] : MockBackend.defaultReply(frame) }
        let client = try await ready()
        let task = Task { try await client.ask("Hi") }
        try await eventually { !backend.received(type: "ask").isEmpty }
        backend.drop()
        await #expect(throws: BackendError.unreachable) { try await task.value }
    }

    @Test func aServerErrorForTheAskIsThrown() async throws {
        backend.script = { frame in
            frame["type"]?.string == "ask" ? [#"{"type":"error","id":"\#(frame["id"]!.string!)","message":"No provider."}"#] : MockBackend.defaultReply(frame)
        }
        let client = try await ready()
        await #expect(throws: BackendError.server("No provider.")) { try await client.ask("Hi") }
    }

    @Test func cancellingTheTaskSendsCancel() async throws {
        backend.script = { frame in frame["type"]?.string == "ask" ? [] : MockBackend.defaultReply(frame) }
        let client = try await ready()
        let task = Task { try await client.ask("Hi") }
        try await eventually { !backend.received(type: "ask").isEmpty }
        task.cancel()
        _ = try? await task.value
        try await eventually { !backend.received(type: "cancel").isEmpty }
        let ask = backend.received(type: "ask")[0]
        #expect(backend.received(type: "cancel")[0]["id"] == ask["id"])
    }

    @Test func backendBrainTurnsTheAnswerIntoAnAnswer() async throws {
        backend.script = { frame in
            guard frame["type"]?.string == "ask" else { return MockBackend.defaultReply(frame) }
            return [#"{"type":"answer","id":"\#(frame["id"]!.string!)","text":"Milch ist drauf.","followUps":[],"actions":[],"undo":{"id":"u9","label":"Rückgängig"}}"#]
        }
        let client = try await ready()
        let brain = BackendBrain(client: client)
        #expect(brain.isReachable)
        let answer = try await brain.answer("Milch auf die Liste", context: "Now: x", status: { _ in }, activity: {})
        #expect(answer.sentence == "Milch ist drauf.")
        #expect(answer.undo == UndoAction(id: "u9", label: "Rückgängig"))
    }

    // MARK: Actions

    @Test func serverActionsPassAndPhoneActionsAreValidated() async throws {
        let timer = FakeTool.timer()
        backend.script = { frame in
            guard frame["type"]?.string == "ask" else { return MockBackend.defaultReply(frame) }
            let actions = """
            [{"id":"a1","title":"Auf die Liste","target":"server"},
             {"id":"a2","title":"Timer 10 min","target":"phone","tool":"set_timer","args":{"minutes":10}},
             {"id":"a3","title":"Bad","target":"phone","tool":"set_timer","args":{"minutes":"soon"}},
             {"id":"a4","title":"Nope","target":"phone","tool":"format_disk","args":{}}]
            """
            return [#"{"type":"answer","id":"\#(frame["id"]!.string!)","text":"Ok","followUps":[],"actions":\#(actions)}"#]
        }
        let client = try await ready(tools: [timer])
        let answer = try await client.ask("x")
        #expect(answer.actions.map(\.title) == ["Auf die Liste", "Timer 10 min"])
        #expect(answer.actions[0].target == .server && answer.actions[0].actionId == "a1")
        #expect(answer.actions[1].target == .phone && answer.actions[1].tool == "set_timer")
        #expect(timer.runs.isEmpty)  // nothing runs on the backend's say-so
    }

    @Test func performAndUndoGetPerformed() async throws {
        backend.script = { frame in
            switch frame["type"]?.string {
            case "perform":
                return [#"{"type":"performed","id":"\#(frame["id"]!.string!)","ok":true,"text":"Auf der Liste.","undo":{"id":"u1","label":"Rückgängig"}}"#]
            case "undo":
                return [#"{"type":"performed","id":"\#(frame["id"]!.string!)","ok":true,"text":"Wieder runter."}"#]
            default: return MockBackend.defaultReply(frame)
            }
        }
        let client = try await ready()
        let done = try await client.perform(actionId: "a1")
        #expect(done.ok && done.text == "Auf der Liste." && done.undo == UndoAction(id: "u1", label: "Rückgängig"))
        #expect(backend.received(type: "perform")[0]["actionId"]?.string == "a1")
        let undone = try await client.undo("u1")
        #expect(undone.text == "Wieder runter.")
        #expect(backend.received(type: "undo")[0]["undoId"]?.string == "u1")
    }

    @Test func performWithoutASocketThrows() async throws {
        let client = Fixtures.client(backend, start: false)
        await #expect(throws: BackendError.unreachable) { try await client.perform(actionId: "a") }
    }

    // MARK: Phone tools

    func toolCall(_ name: String, args: String = "{}", id: String = "t1") -> String {
        #"{"type":"tool_call","callId":"\#(id)","askId":"x","name":"\#(name)","args":\#(args)}"#
    }

    @Test func aToolCallRunsThroughTheToolboxAndAnswersWithToolResult() async throws {
        let location = FakeTool("location", result: "Große Elbstraße 39, Hamburg")
        _ = try await ready(tools: [location])
        backend.send(toolCall("location"))
        try await eventually { !backend.received(type: "tool_result").isEmpty }
        let result = backend.received(type: "tool_result")[0]
        #expect(result["callId"]?.string == "t1")
        #expect(result["ok"] == .bool(true))
        #expect(result["text"]?.string == "Große Elbstraße 39, Hamburg")
    }

    @Test func remindersWorkToo() async throws {
        let reminders = FakeTool("reminders", result: "Buy milk")
        _ = try await ready(tools: [reminders])
        backend.send(toolCall("reminders"))
        try await eventually { !backend.received(type: "tool_result").isEmpty }
        #expect(backend.received(type: "tool_result")[0]["text"]?.string == "Buy milk")
    }

    @Test func unknownAndActionToolsAreRefused() async throws {
        let timer = FakeTool.timer()
        _ = try await ready(tools: [timer])
        backend.send(toolCall("camera", id: "t1"))
        backend.send(toolCall("set_timer", args: #"{"minutes":5}"#, id: "t2"))
        try await eventually { backend.received(type: "tool_result").count == 2 }
        let results = backend.received(type: "tool_result")
        #expect(results.allSatisfy { $0["ok"] == .bool(false) })
        #expect(timer.runs.isEmpty)
    }

    @Test func invalidArgumentsGetAnErrorResult() async throws {
        let tool = FakeTool("reminders", parameters: [ToolParameter("limit", .integer, "how many")])
        _ = try await ready(tools: [tool])
        backend.send(toolCall("reminders", args: #"{"limit":"many"}"#))
        try await eventually { !backend.received(type: "tool_result").isEmpty }
        let result = backend.received(type: "tool_result")[0]
        #expect(result["ok"] == .bool(false))
        #expect(result["text"]?.string?.contains("limit") == true)
    }

    @Test func aSlowToolIsCutOff() async throws {
        let slow = FakeTool("location", delay: .seconds(5))
        _ = try await ready(tools: [slow], toolTimeout: .milliseconds(100))
        backend.send(toolCall("location"))
        try await eventually { !backend.received(type: "tool_result").isEmpty }
        #expect(backend.received(type: "tool_result")[0]["ok"] == .bool(false))
    }

    // MARK: Inbox

    static let mail = #"{"id":"m1","kind":"mail","title":"Mara","summary":"Pizza um 8?","body":"Kommst du noch um 8?","createdAt":"2026-11-03T08:15:00+01:00","status":"pending"}"#
    static let event = #"{"id":"e1","kind":"calendar","title":"Zahnarzt","summary":"","body":"","createdAt":"2026-11-03T08:00:00+01:00","status":"pending"}"#

    @Test func inboxSyncPushAndRemovals() async throws {
        let client = try await ready()
        backend.send(#"{"type":"inbox","full":true,"items":[\#(Self.mail),\#(Self.event)],"removedIds":[]}"#)
        try await eventually { client.inbox.items.count == 2 }
        #expect(client.inbox.item("m1")?.kind == .mail)
        #expect(client.inbox.item("m1")?.createdAt == BackendDates.parse("2026-11-03T08:15:00+01:00"))

        backend.send(#"{"type":"push","item":{"id":"j1","kind":"job","title":"Backup","status":"pending"}}"#)
        try await eventually { client.inbox.items.count == 3 }

        backend.send(#"{"type":"inbox","full":false,"items":[],"removedIds":["m1"]}"#)
        try await eventually { client.inbox.items.count == 2 }
        #expect(client.inbox.item("m1") == nil)

        // A full sync replaces everything.
        backend.send(#"{"type":"inbox","full":true,"items":[\#(Self.event)],"removedIds":[]}"#)
        try await eventually { client.inbox.items.map(\.id) == ["e1"] }
    }

    @Test func inboxEventsGoToTheBackendAndUpdateTheStore() async throws {
        let client = try await ready()
        backend.send(#"{"type":"inbox","full":true,"items":[\#(Self.mail)],"removedIds":[]}"#)
        try await eventually { client.inbox.items.count == 1 }
        client.inboxEvent("m1", .opened)
        #expect(client.inbox.item("m1")?.status == .seen)
        client.inboxEvent("m1", .dismissed)
        #expect(client.inbox.item("m1")?.status == .dismissed)
        try await eventually { backend.received(type: "inbox_event").count == 2 }
        #expect(backend.received(type: "inbox_event").map { $0["event"]?.string } == ["opened", "dismissed"])
        #expect(backend.received(type: "inbox_event")[0]["itemId"]?.string == "m1")
    }

    @Test func inboxEventsMadeOfflineAreSentAfterReconnect() async throws {
        let client = Fixtures.client(backend, start: false)
        client.inboxEvent("m1", .dismissed)
        #expect(backend.received(type: "inbox_event").isEmpty)
        client.start()
        try await eventually { backend.received(type: "inbox_event").count == 1 }
    }

    @Test func eventsStreamCarriesPushesWithoutAnythingElse() async throws {
        let client = try await ready()
        let events = client.events()
        backend.send(#"{"type":"push","item":{"id":"j1","kind":"job","title":"Backup","status":"pending"}}"#)
        var seen: [BackendEvent] = []
        for await event in events {
            seen.append(event)
            if seen.count == 2 { break }
        }
        #expect(seen.first == .push(InboxItem(id: "j1", kind: .job, title: "Backup")))
        #expect(seen.last == .inboxChanged)
    }

    // MARK: Presence, catch-up, location, messages

    @Test func presenceIsSentWhileConnectedAndDroppedOtherwise() async throws {
        let client = try await ready()
        client.presence(.gesture, detail: "tap")
        client.presence(.glassesWorn)
        try await eventually { backend.received(type: "presence").count == 2 }
        let first = backend.received(type: "presence")[0]
        #expect(first["event"]?.string == "gesture" && first["detail"]?.string == "tap")
        #expect(BackendDates.parse(first["at"]?.string ?? "") != nil)
        #expect(backend.received(type: "presence")[1]["event"]?.string == "glasses_worn")

    }

    @Test func presenceWithoutASocketIsSentAfterWelcomeIfFresh() async throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_000_000))
        let client = Fixtures.client(backend, now: { clock.now }, start: false)
        client.presence(.glassesRemoved)
        clock.now += 1
        client.presence(.gesture, detail: "tap")
        clock.now += 1
        client.presence(.gesture, detail: "double_tap")  // the latest of a kind wins
        clock.now += 1
        client.presence(.glassesWorn)
        clock.now += 20
        client.start()
        try await eventually { backend.received(type: "presence").count == 3 }
        try await Task.sleep(for: .milliseconds(30))
        let sent = backend.received(type: "presence")
        #expect(sent.map { $0["event"]?.string } == ["glasses_removed", "gesture", "glasses_worn"])
        #expect(sent[1]["detail"]?.string == "double_tap")
        #expect(BackendDates.parse(sent[0]["at"]?.string ?? "") == Date(timeIntervalSince1970: 1_000_000))
    }

    @Test func stalePresenceIsDroppedOnReconnect() async throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_000_000))
        let client = Fixtures.client(backend, now: { clock.now }, start: false)
        client.presence(.headUp)
        clock.now += 31
        client.presence(.glassesWorn)
        client.start()
        try await eventually { client.isReachable }
        try await eventually { backend.received(type: "presence").count == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(backend.received(type: "presence").map { $0["event"]?.string } == ["glasses_worn"])
    }

    @Test func catchupLocationAndMessagesAreExposed() async throws {
        let client = try await ready()
        let catchups = client.catchups()
        let accesses = client.locationAccesses()
        let messages = client.messages()
        backend.send(#"{"type":"catchup","id":"k1","text":"Während du weg warst: zwei Mails.","at":"2026-11-03T08:15:00+01:00"}"#)
        backend.send(#"{"type":"location_access","phase":"start","callId":"t1","at":"2026-11-03T08:15:01+01:00"}"#)
        backend.send(#"{"type":"message","conversationId":"c1","role":"user","text":"Wo ist Mara?","channel":"glasses","at":"2026-11-03T08:16:00+01:00"}"#)
        var catchupIterator = catchups.makeAsyncIterator()
        var accessIterator = accesses.makeAsyncIterator()
        var messageIterator = messages.makeAsyncIterator()
        #expect(await catchupIterator.next()?.text == "Während du weg warst: zwei Mails.")
        #expect(client.lastCatchup?.id == "k1")
        let access = await accessIterator.next()
        #expect(access?.phase == .start && access?.callId == "t1")
        let message = await messageIterator.next()
        #expect(message?.role == .user && message?.channel == .glasses && message?.text == "Wo ist Mara?")
    }

    @Test func unknownMessagesAreIgnored() async throws {
        let client = try await ready()
        let events = client.events()
        backend.send(#"{"type":"from_the_future","x":1}"#)
        backend.send("not json")
        backend.send(#"{"type":"conversation","conversationId":"c3","event":"compacted"}"#)
        for await event in events {
            #expect(event == .conversation(id: "c3", event: "compacted"))
            break
        }
        #expect(client.isReachable)
    }
}

struct BackendProtocolTests {
    @Test func requestsEncodeAsInTheProtocol() throws {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        func json(_ request: BackendRequest) throws -> JSONValue { try JSONValue(json: request.json) }
        #expect(try json(.hello(appVersion: "1.2", deviceName: "iPhone", apnsToken: nil)) == ["type": "hello", "appVersion": "1.2", "deviceName": "iPhone"])
        #expect(try json(.hello(appVersion: "1.2", deviceName: "iPhone", apnsToken: "abc"))["apnsToken"] == "abc")
        #expect(try json(.cancel(id: "a1")) == ["type": "cancel", "id": "a1"])
        #expect(try json(.toolResult(callId: "c", ok: false, text: "no")) == ["type": "tool_result", "callId": "c", "ok": false, "text": "no"])
        #expect(try json(.perform(id: "r1", actionId: "a1")) == ["type": "perform", "id": "r1", "actionId": "a1"])
        #expect(try json(.undo(id: "r2", undoId: "u1")) == ["type": "undo", "id": "r2", "undoId": "u1"])
        #expect(try json(.inboxEvent(itemId: "m1", event: .shown)) == ["type": "inbox_event", "itemId": "m1", "event": "shown"])
        #expect(try json(.inboxSync) == ["type": "inbox_sync"])
        let presence = try json(.presence(.glassesRemoved, at: at, detail: nil))
        #expect(presence["event"] == "glasses_removed" && presence["detail"] == nil)
        let ask = try json(.ask(id: "a1", text: "Hi", channel: .phone, now: at, locale: "en"))
        #expect(ask["channel"] == "phone" && ask["locale"] == "en" && ask["id"] == "a1")
    }

    @Test func decodesTheServerMessages() {
        #expect(BackendMessage.decode(#"{"type":"status","id":"a","text":"x"}"#) == .status(id: "a", text: "x"))
        #expect(BackendMessage.decode(#"{"type":"error","message":"boom"}"#) == .error(id: nil, message: "boom"))
        #expect(BackendMessage.decode(#"{"type":"performed","id":"r","ok":false,"text":"no"}"#) == .performed(BackendPerformed(id: "r", ok: false, text: "no", undo: nil)))
        #expect(BackendMessage.decode(#"{"type":"tool_call","callId":"c","name":"location","args":{"a":1}}"#)
            == .toolCall(BackendToolCall(callId: "c", askId: nil, name: "location", args: ["a": 1])))
        #expect(BackendMessage.decode(#"{"type":"weird"}"#) == .unknown("weird"))
        #expect(BackendMessage.decode("[]") == nil)
        #expect(BackendMessage.decode(#"{"type":"status"}"#) == nil)
    }

    @Test func itemsDecodeTheirKindStatusAndDueTime() throws {
        let json = try JSONValue(json: #"{"id":"e","kind":"calendar","title":"Zahnarzt","expiresAt":"2026-11-03T09:00:00+01:00","status":"seen","actions":[{"id":"x","title":"Route","target":"phone","tool":"start_navigation","args":{"destination":"Praxis"}}]}"#)
        let item = try #require(BackendActions.decodeItem(json))
        #expect(item.kind == .calendar && item.status == .seen)
        #expect(item.due == BackendDates.parse("2026-11-03T09:00:00+01:00"))
        #expect(item.actions.map(\.title) == ["Route"])
        #expect(InboxKind(backend: "newsletter") == .info)
    }

    @Test func datesRoundTripWithAnOffset() throws {
        let date = try #require(BackendDates.parse("2026-11-03T08:15:00+01:00"))
        #expect(BackendDates.format(date, timeZone: TimeZone(secondsFromGMT: 3600)!) == "2026-11-03T08:15:00+01:00")
        #expect(BackendDates.parse("2026-11-03T08:15:00.250+01:00") != nil)
    }
}

// MARK: - Management API

struct MockHTTP: BackendHTTP {
    var respond: @Sendable (URLRequest) -> (Int, String)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = respond(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct BackendManagementTests {
    let base = URL(string: "https://brain.test")!

    @Test func pairingTradesTheCodeForAToken() async throws {
        let http = MockHTTP { request in
            #expect(request.url?.path == "/api/v1/pair")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = try? JSONValue(json: String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            return body?["code"] == "123456" && body?["deviceName"] == "iPhone" ? (200, #"{"token":"T0K"}"#) : (400, #"{"error":"bad"}"#)
        }
        let token = try await BackendManagementClient(baseURL: base, http: http).pair(code: " 123456 ", deviceName: "iPhone")
        #expect(token == "T0K")
    }

    @Test func aWrongCodeIsAnHTTPError() async throws {
        let http = MockHTTP { _ in (403, #"{"error":"wrong code"}"#) }
        await #expect(throws: BackendError.http(403, "wrong code")) {
            try await BackendManagementClient(baseURL: base, http: http).pair(code: "0", deviceName: "x")
        }
    }

    @Test func listsOps() async throws {
        let http = MockHTTP { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            return (200, #"[{"name":"inbox.list","description":"List","inputSchema":{"type":"object"},"risk":"free","group":"inbox"},{"name":"secrets.set","description":"","inputSchema":{},"risk":"app_only","group":"secrets"}]"#)
        }
        let ops = try await BackendManagementClient(baseURL: base, token: "tok", http: http).listOps()
        #expect(ops.map(\.name) == ["inbox.list", "secrets.set"])
        #expect(ops.map(\.risk) == [.free, .appOnly])
        #expect(ops[0].group == "inbox")
    }

    @Test func callSendsTheInputAndReturnsTheResult() async throws {
        let http = MockHTTP { request in
            #expect(request.url?.path == "/api/v1/ops/status.get")
            #expect(request.httpMethod == "POST")
            return (200, #"{"ok":true,"result":{"version":"0.1"}}"#)
        }
        let result = try await BackendManagementClient(baseURL: base, token: "tok", http: http).call("status.get", ["verbose": true])
        #expect(result["version"] == "0.1")
    }

    @Test func aFailedOpThrowsItsMessage() async throws {
        let http = MockHTTP { _ in (200, #"{"ok":false,"error":"Unknown op"}"#) }
        await #expect(throws: BackendError.server("Unknown op")) {
            try await BackendManagementClient(baseURL: base, token: "tok", http: http).call("nope")
        }
    }

    @Test func callsNeedAToken() async throws {
        await #expect(throws: BackendError.notConfigured) {
            try await BackendManagementClient(baseURL: base, http: MockHTTP { _ in (200, "{}") }).call("x")
        }
    }

    @Test func healthIsUnauthenticated() async {
        let http = MockHTTP { request in
            request.value(forHTTPHeaderField: "Authorization") == nil ? (200, #"{"ok":true}"#) : (500, "")
        }
        #expect(await BackendManagementClient(baseURL: base, token: "tok", http: http).health())
    }
}
