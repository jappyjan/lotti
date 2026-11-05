import Foundation
import LottiKit
import Testing
@testable import Lotti

@MainActor
struct AppModelTests {
    func model(_ link: FakeGlassesLink, store: BackendStore = .testing(), http: (any BackendHTTP)? = nil) -> AppModel {
        let model = AppModel(link: link, conductor: Conductor(link: link, brain: SilentBrain(), speech: SilentSpeech(), today: NoToday()),
                             store: store, locationLog: LocationReadLog(defaults: .testing()))
        if let http { model.http = http }
        return model
    }

    let glasses = DiscoveredGlasses(id: "32", name: "Even G2 · 32", leftArm: .init(), rightArm: .init())

    @Test func launchReconnectsToLastGlasses() async {
        let link = FakeGlassesLink(last: glasses)
        await model(link).launch()
        #expect(link.connected == ["32"])
        #expect(!link.scanned)
    }

    @Test func launchScansWhenNothingIsRemembered() async {
        let link = FakeGlassesLink()
        await model(link).launch()
        #expect(link.scanned)
        #expect(link.connected.isEmpty)
    }

    @Test func reconnectsAfterADrop() async throws {
        let link = FakeGlassesLink(last: glasses)
        let model = model(link)
        let keeper = Task { await model.keepConnected(pollEvery: .milliseconds(10)) }
        defer { keeper.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(link.status.isConnected)
        #expect(link.headTracking)
        link.disconnect()
        try await Task.sleep(for: .milliseconds(100))
        #expect(link.status.isConnected)
        #expect(model.reconnects == 2)
    }

    @Test func staysDisconnectedWhenAsked() async throws {
        let link = FakeGlassesLink(last: glasses)
        let model = model(link)
        await model.connect(glasses)
        model.disconnect()
        let keeper = Task { await model.keepConnected(pollEvery: .milliseconds(10)) }
        defer { keeper.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!link.status.isConnected)
    }

    // MARK: Lotti Brain

    @Test func notPairedByDefault() async {
        let model = model(FakeGlassesLink())
        #expect(!model.isPaired)
        #expect(model.management == nil)
        await #expect(throws: BackendError.notConfigured) { try await model.call("status.get") }
    }

    @Test func pairingKeepsTheTokenAndConfiguresTheBackend() async throws {
        let store = BackendStore.testing()
        let http = StubHTTP { request in
            switch request.url?.path {
            case "/api/v1/pair": (200, #"{"ok":true,"token":"tok-1"}"#)
            case "/api/v1/ops": (200, #"[{"name":"status.get","description":"","inputSchema":{},"risk":"free","group":"status"}]"#)
            default: (404, "{}")
            }
        }
        let model = model(FakeGlassesLink(), store: store, http: http)
        let url = URL(string: "http://lotti.local:8787")!
        try await model.pair(url: url, code: "ABC-123")
        defer { model.unpair() }
        #expect(model.isPaired)
        #expect(store.token == "tok-1")
        #expect(store.url == url)
        #expect(model.backend.configuration?.token == "tok-1")
        #expect(model.management != nil)

        // Before the op list is known every op is tried; afterwards only the listed ones count.
        #expect(model.supports("providers.codex_login_start"))
        await model.refreshOps()
        #expect(model.supports("status.get"))
        #expect(!model.supports("providers.codex_login_start"))
    }

    @Test func pairingFromALink() async throws {
        let http = StubHTTP { _ in (200, #"{"token":"t"}"#) }
        let model = model(FakeGlassesLink(), http: http)
        defer { model.unpair() }
        let handled = try await model.pair(link: "lotti://pair?url=https%3A%2F%2Flotti.example.com&code=XYZ")
        #expect(handled)
        #expect(model.baseURL == URL(string: "https://lotti.example.com"))
        #expect(try await model.pair(link: "https://example.com") == false)
    }

    @Test func aWrongCodeLeavesThePhoneUnpaired() async {
        let http = StubHTTP { _ in (401, #"{"ok":false,"error":"Invalid or used pairing code"}"#) }
        let model = model(FakeGlassesLink(), http: http)
        await #expect(throws: BackendError.self) {
            try await model.pair(url: URL(string: "http://x:1")!, code: "nope")
        }
        #expect(!model.isPaired)
    }

    @Test func unpairingForgetsEverything() async throws {
        let store = BackendStore.testing()
        let model = model(FakeGlassesLink(), store: store, http: StubHTTP { _ in (200, #"{"token":"t"}"#) })
        try await model.pair(url: URL(string: "http://x:1")!, code: "c")
        model.unpair()
        #expect(!model.isPaired)
        #expect(store.token == nil)
        #expect(model.backend.configuration == nil)
        #expect(model.management == nil)
    }

    @Test func theAPNsTokenRidesInTheConfiguration() async throws {
        let model = model(FakeGlassesLink(), http: StubHTTP { _ in (200, #"{"token":"t"}"#) })
        try await model.pair(url: URL(string: "http://x:1")!, code: "c")
        defer { model.unpair() }
        model.setAPNsToken("abcd")
        #expect(model.backend.configuration?.apnsToken == "abcd")
    }

    @Test func locationReadsAreLogged() {
        let defaults = UserDefaults.testing()
        let log = LocationReadLog(defaults: defaults, limit: 2)
        let start = Date(timeIntervalSince1970: 1_000)
        log.record(access("start", "a", start))
        log.record(access("end", "a", start.addingTimeInterval(2)))
        log.record(access("start", "b", start.addingTimeInterval(10)))
        log.record(access("start", "c", start.addingTimeInterval(20)))
        #expect(log.entries.map(\.callId) == ["c", "b"])
        #expect(LocationReadLog(defaults: defaults).entries.count == 2)
        log.clear()
        #expect(log.entries.isEmpty)
    }
}

// MARK: - Pairing links and stores

@MainActor
struct BackendStoreTests {
    @Test func readsAPairingLink() throws {
        let link = try #require(PairingLink("lotti://pair?url=http://192.168.1.5:8787&code=K7-QQ"))
        #expect(link.url == URL(string: "http://192.168.1.5:8787"))
        #expect(link.code == "K7-QQ")
        #expect(PairingLink(" lotti://pair?url=lotti.example.com/&code=1 ")?.url == URL(string: "http://lotti.example.com"))
    }

    @Test func rejectsOtherLinks() {
        #expect(PairingLink("https://pair?url=http://x&code=1") == nil)
        #expect(PairingLink("lotti://pair?url=http://x") == nil)
        #expect(PairingLink("lotti://pair?code=1") == nil)
        #expect(PairingLink("lotti://oauth?code=1") == nil)
        #expect(PairingLink("garbage") == nil)
    }

    @Test func normalizesServerAddresses() {
        #expect(BackendStore.normalizedURL("lotti.local:8787") == URL(string: "http://lotti.local:8787"))
        #expect(BackendStore.normalizedURL("https://brain.example.com///") == URL(string: "https://brain.example.com"))
        #expect(BackendStore.normalizedURL("") == nil)
        #expect(BackendStore.normalizedURL("ftp://x") == nil)
    }

    @Test func storesTheTokenInTheKeychain() {
        let store = BackendStore.testing()
        #expect(store.configuration(deviceName: "d", appVersion: "1") == nil)
        store.url = URL(string: "http://x:1")
        store.token = "secret"
        store.apnsToken = "ff"
        let configuration = store.configuration(deviceName: "d", appVersion: "1")
        #expect(configuration?.token == "secret")
        #expect(configuration?.apnsToken == "ff")
        #expect(store.defaults.string(forKey: BackendStore.urlKey) == "http://x:1")
        #expect(store.defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "secret" } == false)
        store.clear()
        #expect(!store.isPaired)
    }

    @Test func readsTheOAuthReturn() throws {
        let ok = try #require(OAuthCallback(URL(string: "lotti://oauth?code=c1&state=s1")!))
        #expect(ok.code == "c1" && ok.state == "s1" && ok.error == nil)
        #expect(OAuthCallback(URL(string: "lotti://oauth?error=access_denied")!)?.error == "access denied")
        #expect(OAuthCallback(URL(string: "lotti://oauth?error=access_denied&error_description=No%20thanks")!)?.error == "No thanks")
        #expect(OAuthCallback(URL(string: "lotti://oauth")!) == nil)
    }

    @Test func readsTheOAuthReturnOfAGoogleIosClient() throws {
        let url = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?code=c2&state=s2")!
        let ok = try #require(OAuthCallback(url))
        #expect(ok.code == "c2" && ok.state == "s2")
        let start: JSONValue = ["callbackScheme": "com.googleusercontent.apps.123-abc", "state": "s2"]
        #expect(OAuthFlow.callbackScheme(start) == "com.googleusercontent.apps.123-abc")
        #expect(OAuthFlow.callbackScheme(["url": "https://x"]) == "lotti")
        let result = try OAuthFlow.result(url, start: start)
        #expect(result.code == "c2" && result.state == "s2")
        // The state of the start answer fills in when the redirect carries none.
        #expect(try OAuthFlow.result(URL(string: "lotti://oauth?code=c3")!, start: start).state == "s2")
        #expect(throws: BackendError.self) { try OAuthFlow.result(URL(string: "lotti://oauth?error=access_denied")!, start: start) }
    }

    @Test func readsTheGoogleClientInfo() {
        let ios = GoogleClientInfo(["configured": true, "mode": "ios", "redirectUri": "com.googleusercontent.apps.1:/oauth2redirect"])
        #expect(ios.consoleRedirect == nil && ios.modeTitle == "iOS")
        let web = GoogleClientInfo(["configured": true, "mode": "web", "redirectUri": "https://lotti.example/oauth/callback"])
        #expect(web.consoleRedirect == "https://lotti.example/oauth/callback")
        #expect(!GoogleClientInfo(["configured": false]).configured)
    }

    @Test func showsTheMcpSignInState() throws {
        let needs = try #require(McpServer(["id": "m", "name": "Docs", "status": "error", "authRequired": true]))
        #expect(needs.summary == "Needs sign-in")
        let signed = try #require(McpServer(["id": "m", "name": "Docs", "status": "ok", "signedIn": true, "hasCredential": true]))
        #expect(signed.summary == "Signed in" && signed.hasCredential)
        #expect(try #require(McpServer(["id": "m", "name": "Docs", "enabled": false])).summary == "Off")
    }

    @Test func offersIcsCalendars() {
        #expect(AccountKind.allCases.contains(.ics))
        #expect(AccountKind.ics.title == "Add ICS calendar")
        // An account left unnamed is not called after the action that created it.
        #expect(AccountKind.ics.defaultName == "ICS calendar")
        #expect(AccountKind.imap.defaultName == AccountKind.imap.title)
    }

    @Test func readsACodexDeviceLogin() throws {
        let login = try #require(ProviderDetailView.deviceLogin(["verification_uri": "https://auth.openai.com/device", "user_code": "AB12-CD34"]))
        #expect(login.code == "AB12-CD34")
        #expect(login.url == "https://auth.openai.com/device")
        #expect(ProviderDetailView.deviceLogin(["url": "https://x"]) == nil)
    }
}

// MARK: - Schedules and models

struct ScheduleDraftTests {
    @Test func buildsTheFriendlyText() {
        var draft = ScheduleDraft()
        #expect(draft.text == "daily at 08:00")
        draft.kind = .weekdays; (draft.hour, draft.minute) = (7, 30)
        #expect(draft.text == "weekdays at 07:30")
        draft.kind = .weekly; draft.weekday = 4
        #expect(draft.text == "every friday at 07:30")
        draft.kind = .everyMinutes; draft.minutes = 15
        #expect(draft.text == "every 15 minutes")
        draft.kind = .hourly
        #expect(draft.text == "hourly")
        draft.kind = .monthly
        #expect(draft.text == "monthly at 07:30")
        draft.kind = .custom; draft.custom = " 0 8 * * 1 "
        #expect(draft.text == "0 8 * * 1")
    }

    @Test func readsAScheduleBack() {
        for text in ["daily at 08:00", "weekdays at 07:30", "every monday at 09:00", "every 30 minutes", "hourly", "monthly at 09:00"] {
            #expect(ScheduleDraft(text: text).text == text)
        }
        let cron = ScheduleDraft(text: nil, cron: "*/5 * * * *")
        #expect(cron.kind == .custom)
        #expect(cron.text == "*/5 * * * *")
        #expect(ScheduleDraft(text: "täglich um 7:30").kind == .custom)
    }
}

struct ModelParsingTests {
    @Test func parsesAJob() throws {
        let job = try #require(JobInfo(["id": "j1", "name": "Morning", "kind": "user", "prompt": "Brief me", "cron": "0 8 * * *",
                                        "scheduleText": "daily at 08:00", "enabled": false,
                                        "nextRunAt": "2026-11-04T08:00:00+01:00", "lastRunAt": .null]))
        #expect(job.scheduleLabel == "daily at 08:00")
        #expect(!job.enabled && !job.isBuiltin)
        #expect(job.nextRunAt != nil && job.lastRunAt == nil)
        #expect(JobInfo(["kind": "builtin"]) == nil)
    }

    @Test func mcpToolsNeedConfirmationUnlessSwitchedOff() throws {
        let server = try #require(McpServer(["id": "m", "name": "Files", "transport": "stdio", "command": "npx", "args": ["a", "b"],
                                             "enabled": true, "toolFlags": ["read": ["needsConfirmation": false]]]))
        #expect(!server.needsConfirmation("read"))
        #expect(server.needsConfirmation("write"))
        #expect(server.args == ["a", "b"])
    }

    @Test func catchupSettingsRoundTrip() {
        var settings = CatchupSettings(["away_hours": 3, "night_start": "23:00", "enabled": false])
        #expect(settings.awayHours == 3 && settings.nightStart == "23:00" && !settings.enabled)
        #expect(settings.nightEnd == "09:00")
        settings.useWeather = false
        #expect(CatchupSettings(settings.json) == settings)
    }

    @Test func parsesAnAccountAndAProvider() throws {
        let account = try #require(AccountInfo(["id": "a", "kind": "imap", "label": "Work", "status": "ok",
                                                "lastSyncAt": "2026-11-03T08:15:00+01:00",
                                                "config": ["mailboxes": ["Inbox", "Work"]]]))
        #expect(account.isConnected)
        #expect(account.list("mailboxes") == ["Inbox", "Work"])
        #expect(account.lastSync != nil)
        let provider = try #require(ProviderInfo(["id": "codex", "kind": "agent", "configured": true, "active": false, "fallback": true]))
        #expect(provider.isRuntime && provider.fallback && provider.label == "codex")
    }

    @Test func parsesTurnsAndConversations() throws {
        let turn = try #require(TurnInfo(["id": 7, "role": "assistant", "text": "Hi", "channel": "glasses", "at": "2026-11-03T08:15:00+01:00"]))
        #expect(turn.role == .assistant && turn.channel == .glasses && turn.id == 7)
        #expect(TurnInfo(["role": "system", "text": "x"]) == nil)
        let conversation = try #require(ConversationInfo(["id": "c1", "status": "open", "title": .null]))
        #expect(conversation.isOpen && conversation.title.isEmpty)
    }
}

// MARK: - Chat

@MainActor
struct ChatModelTests {
    private func makeChat(brain: any Brain = EchoBrain(), tools: [any PhoneTool] = [], speech: any SpeechRecognizer = SilentSpeech()) -> (ChatModel, BackendClient) {
        let backend = BackendClient()
        return (ChatModel(backend: backend, offline: brain, toolbox: Toolbox(tools), speech: speech, microphone: SilentMicrophone()), backend)
    }

    @Test func offlineQuestionsGoToTheOfflineBrain() async {
        let (chat, _) = makeChat()
        #expect(!chat.isOnline)
        chat.send("  Wie spät ist es?  ")
        await eventually { !chat.isAsking }
        #expect(chat.items.map(\.kind) == [.user, .lotti])
        #expect(chat.items[0].text == "Wie spät ist es?")
        #expect(chat.items[1].text == "echo: Wie spät ist es?")
        #expect(chat.items[1].offline)
        #expect(chat.items[1].followUps == ["Again"])
    }

    @Test func emptyAndOverlappingQuestionsAreIgnored() async {
        let (chat, _) = makeChat()
        chat.send("   ")
        #expect(chat.items.isEmpty)
        chat.send("one")
        chat.send("two")
        await eventually { !chat.isAsking }
        #expect(chat.items.filter { $0.kind == .user }.count == 1)
    }

    @Test func aFailingBrainShowsAnError() async {
        let (chat, _) = makeChat(brain: FailingBrain())
        chat.send("hi")
        await eventually { !chat.isAsking }
        #expect(chat.items.last?.kind == .error)
    }

    @Test func tappingAPhoneActionRunsItAndReports() async throws {
        let tool = CountingTool()
        let (chat, _) = makeChat(brain: ActionBrain(), tools: [tool])
        chat.send("timer")
        await eventually { !chat.isAsking }
        let item = try #require(chat.items.last)
        let action = try #require(item.actions.first)
        #expect(await tool.runs == 0)
        await chat.perform(action, in: item.id)
        #expect(await tool.runs == 1)
        #expect(chat.items.last?.kind == .note)
        #expect(chat.items.last?.text == "Timer set.")
        #expect(chat.items.first { $0.id == item.id }?.actions.isEmpty == true)
    }

    @Test func aServerActionWithoutABackendFails() async throws {
        let (chat, _) = makeChat()
        await chat.perform(.server(id: "act-1", title: "Add milk"))
        #expect(chat.items.last?.kind == .error)
        await chat.undo(UndoAction(id: "u", label: "Undo"))
        #expect(chat.items.last?.kind == .error)
    }

    @Test func holdToTalkSendsWhatWasHeard() async throws {
        let (chat, _) = makeChat(speech: ScriptedSpeech(words: "set a timer"))
        chat.beginTalking()
        #expect(chat.isListening)
        for _ in 0..<100 where chat.draft.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(chat.draft == "set a timer")
        chat.endTalking()
        await eventually { chat.items.count >= 2 && !chat.isAsking }
        #expect(chat.items.first?.text == "set a timer")
        #expect(!chat.isListening)
        #expect(chat.draft.isEmpty)
    }

    @Test func messagesFromTheGlassesAppearInTheChat() {
        let (chat, _) = makeChat()
        let at = Date()
        chat.handle(message("user", "Wetter?", "glasses", at))
        chat.handle(message("assistant", "Sonnig.", "glasses", at))
        chat.handle(message("user", "from phone", "phone", at))
        #expect(chat.items.map(\.text) == ["Wetter?", "Sonnig."])
        #expect(chat.items.map(\.kind) == [.user, .lotti])
        #expect(chat.items.allSatisfy { $0.channel == .glasses })
    }

    @Test func catchUpsPushesAndNewConversationsShowInline() {
        let (chat, _) = makeChat()
        chat.handle(catchup("Guten Morgen", .now))
        chat.handle(.push(InboxItem(id: "i1", kind: .mail, title: "Mail from Anna")))
        chat.handle(.push(InboxItem(id: "i2", kind: .mail, title: "Old", status: .dismissed)))
        chat.handle(.conversation(id: "c2", event: "new"))
        chat.handle(.conversation(id: "c2", event: "compacted"))
        #expect(chat.items.map(\.kind) == [.catchup, .inbox, .divider])
        #expect(chat.items[1].inboxId == "i1")
    }

    @Test func historyLoadsOnceAndThenOnlyNewGlassesTurns() async {
        let (chat, _) = makeChat()
        let t0 = Date(timeIntervalSince1970: 1_000)
        var turns = [TurnInfo(["id": 1, "role": "user", "text": "old q", "channel": "phone", "at": .string(BackendDates.format(t0))])!,
                                         TurnInfo(["id": 2, "role": "assistant", "text": "old a", "channel": "phone", "at": .string(BackendDates.format(t0))])!]
        chat.loadTurns = { _ in turns }
        chat.handle(catchup("brief", t0.addingTimeInterval(5)))
        await chat.loadHistory("c1")
        #expect(chat.items.map(\.text) == ["old q", "old a", "brief"])
        turns.append(TurnInfo(["id": 3, "role": "user", "text": "glasses q", "channel": "glasses", "at": .string(BackendDates.format(t0.addingTimeInterval(60)))])!)
        turns.append(TurnInfo(["id": 4, "role": "user", "text": "phone q", "channel": "phone", "at": .string(BackendDates.format(t0.addingTimeInterval(61)))])!)
        await chat.loadHistory("c1")
        #expect(chat.items.map(\.text) == ["old q", "old a", "brief", "glasses q"])
    }

    @Test func theOfflineChoiceUsesTheModelOnlyWhenItIsThere() async throws {
        var available = true
        let choice = OfflineChoice(primary: EchoBrain(prefix: "apple"), primaryAvailable: { available }, fallback: EchoBrain(prefix: "rules"))
        #expect(try await choice.answer("a", context: "", status: { _ in }).sentence == "apple: a")
        available = false
        #expect(try await choice.answer("b", context: "", status: { _ in }).sentence == "rules: b")
    }
}

/// Polls until `condition` holds. Records an issue after `timeout` seconds instead of hanging the run.
@MainActor
func eventually(timeout: Double = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            Issue.record("condition not met in \(timeout) s")
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - Fakes

/// LottiKit builds its messages by decoding the backend's JSON; so do the tests.
private func access(_ phase: String, _ callId: String, _ at: Date) -> LocationAccess {
    guard case .locationAccess(let access)? = BackendMessage.decode(
        #"{"type":"location_access","phase":"\#(phase)","callId":"\#(callId)","at":"\#(BackendDates.format(at))"}"#)
    else { fatalError("bad location_access") }
    return access
}

private func message(_ role: String, _ text: String, _ channel: String, _ at: Date) -> BackendEvent {
    guard case .message(let message)? = BackendMessage.decode(
        #"{"type":"message","conversationId":"c","role":"\#(role)","text":"\#(text)","channel":"\#(channel)","at":"\#(BackendDates.format(at))"}"#)
    else { fatalError("bad message") }
    return .message(message)
}

private func catchup(_ text: String, _ at: Date) -> BackendEvent {
    guard case .catchup(let catchup)? = BackendMessage.decode(
        #"{"type":"catchup","id":"1","text":"\#(text)","at":"\#(BackendDates.format(at))"}"#)
    else { fatalError("bad catchup") }
    return .catchup(catchup)
}

extension UserDefaults {
    static func testing() -> UserDefaults { UserDefaults(suiteName: "lotti-tests-\(UUID().uuidString)")! }
}

extension BackendStore {
    /// A store that touches neither the app's defaults nor its Keychain items.
    static func testing() -> BackendStore {
        BackendStore(defaults: .testing(), keychain: Keychain(memory: MemorySecrets()))
    }
}

/// Answers HTTP from a closure: (status, body) per request.
private struct StubHTTP: BackendHTTP {
    let respond: @Sendable (URLRequest) -> (Int, String)

    init(_ respond: @escaping @Sendable (URLRequest) -> (Int, String)) { self.respond = respond }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = respond(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor private final class EchoBrain: Brain {
    let prefix: String
    init(prefix: String = "echo") { self.prefix = prefix }
    func prewarm() {}
    func answer(_ message: String, context: String, status: @escaping @MainActor (String) -> Void) async throws -> Answer {
        Answer(sentence: "\(prefix): \(message)", followUps: ["Again"])
    }
    func endConversation() {}
}

@MainActor private final class FailingBrain: Brain {
    func prewarm() {}
    func answer(_ message: String, context: String, status: @escaping @MainActor (String) -> Void) async throws -> Answer {
        throw ToolError("model is asleep")
    }
    func endConversation() {}
}

@MainActor private final class ActionBrain: Brain {
    func prewarm() {}
    func answer(_ message: String, context: String, status: @escaping @MainActor (String) -> Void) async throws -> Answer {
        Answer(sentence: "Shall I?", actions: [ProposedAction(tool: "count", arguments: ToolArguments(), title: "Set timer")])
    }
    func endConversation() {}
}

private actor Counter {
    var runs = 0
    func hit() { runs += 1 }
}

private struct CountingTool: PhoneTool {
    let counter = Counter()
    let spec = PhoneToolSpec(name: "count", description: "counts", effect: .action, progress: "Counting…")
    var runs: Int { get async { await counter.runs } }

    func run(_ arguments: ToolArguments) async throws -> String {
        await counter.hit()
        return "Timer set."
    }
}

@MainActor private final class SilentMicrophone: Microphone {
    func start() async throws -> AsyncStream<[Int16]> { AsyncStream { $0.yield([0]) } }
    func stop() async {}
}

/// Hears `words` as soon as audio starts, then waits for the audio to end.
@MainActor private final class ScriptedSpeech: SpeechRecognizer {
    let words: String
    init(words: String) { self.words = words }
    func prepare() async {}
    func transcribe(_ audio: AsyncStream<[Int16]>) -> AsyncThrowingStream<Transcript, Error> {
        let words = words
        return AsyncThrowingStream { continuation in
            continuation.yield(Transcript(words, isFinal: true))
            continuation.finish()
        }
    }
}


@MainActor private final class SilentBrain: Brain {
    func prewarm() {}
    func answer(_ message: String, context: String, status: @escaping @MainActor (String) -> Void) async throws -> Answer {
        Answer(sentence: "")
    }
    func endConversation() {}
}

@MainActor private final class SilentSpeech: SpeechRecognizer {
    func prepare() async {}
    func transcribe(_ audio: AsyncStream<[Int16]>) -> AsyncThrowingStream<Transcript, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct NoToday: TodayProvider {
    func today(at now: Date) async -> TodayInfo { TodayInfo(now: now) }
}
