import Foundation
import LottiKit
import Observation

/// The app's own words follow the phone's first language, German or English (like the glasses).
func lang(_ german: String, _ english: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("de") == true ? german : english
}

/// One line in the chat.
struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user, lotti
        /// What Lotti did for you ("Added milk."), with an Undo button when it can be taken back.
        case note
        case error
        case catchup
        /// An inbox item shown inline (`inboxId`).
        case inbox
        /// "New conversation".
        case divider
    }

    let id = UUID()
    var kind: Kind
    var text: String
    /// Where the turn came from: a glasses question shows up here too.
    var channel: BackendChannel = .phone
    var followUps: [String] = []
    var actions: [ProposedAction] = []
    var undo: UndoAction?
    var inboxId: String?
    /// Answered by the offline brain on this phone.
    var offline = false
    var at = Date()
}

/// The chat with Lotti: the same Router as the glasses (Lotti Brain whenever it can be reached,
/// the offline brain otherwise), plus what the backend pushes into it (glasses questions,
/// catch-up briefs, new inbox items).
@MainActor
@Observable
final class ChatModel {
    private(set) var items: [ChatItem] = []
    /// The backend's latest short status line while it works ("Suche Mails …").
    private(set) var statusLine: String?
    private(set) var isAsking = false
    private(set) var isListening = false
    private(set) var voiceError: String?
    /// The text field; filled live while you hold to talk.
    var draft = ""
    /// Loads the turns of a conversation (`conversations.get`); set by the app once the management API exists.
    @ObservationIgnored var loadTurns: @MainActor (String) async throws -> [TurnInfo] = { _ in [] }

    @ObservationIgnored private let backend: BackendClient
    @ObservationIgnored private let offline: any Brain
    @ObservationIgnored private let toolbox: Toolbox
    @ObservationIgnored private let speech: any SpeechRecognizer
    @ObservationIgnored private let microphone: any Microphone
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Like the glasses (`Conductor.Timing`): the backend gets `remoteTimeout` of silence (any
    /// status line or tool call restarts the clock), the offline brain `offlineTimeout` in total.
    @ObservationIgnored private let remoteTimeout: Duration
    @ObservationIgnored private let offlineTimeout: Duration
    @ObservationIgnored private var remoteActivity = ContinuousClock.now
    @ObservationIgnored private var asking: Task<Void, Never>?
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var historyLoaded = false

    /// What a tapped action did, for screens that show it in place (the inbox item).
    struct ActionResult: Equatable {
        var ok: Bool
        var text: String
    }

    init(backend: BackendClient, offline: any Brain, toolbox: Toolbox, speech: any SpeechRecognizer, microphone: any Microphone,
         remoteTimeout: Duration = .seconds(120), offlineTimeout: Duration = .seconds(25),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend
        self.offline = offline
        self.toolbox = toolbox
        self.speech = speech
        self.microphone = microphone
        self.remoteTimeout = remoteTimeout
        self.offlineTimeout = offlineTimeout
        self.now = now
    }

    /// Follows the backend's events until cancelled.
    func run() async {
        let events = backend.events()
        // Connected before we started listening: the welcome is already past.
        if backend.isReachable, let id = backend.welcome?.conversationId { Task { await loadHistory(id) } }
        for await event in events { handle(event) }
    }

    /// True when a question would go to Lotti Brain (the Router's decision).
    var isOnline: Bool { Router.route(backendReachable: backend.isReachable) == .backend }

    // MARK: - Asking

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAsking else { return }
        draft = ""
        items.append(ChatItem(kind: .user, text: text, at: now()))
        isAsking = true
        statusLine = nil
        asking = Task { await answer(text) }
    }

    /// Stops the question in flight (the backend gets `cancel`).
    func cancel() { asking?.cancel() }

    func answer(_ text: String) async {
        defer {
            isAsking = false
            statusLine = nil
            asking = nil
        }
        switch Router.route(backendReachable: backend.isReachable) {
        case .backend:
            let backend = self.backend
            remoteActivity = ContinuousClock.now
            let result: Result<BackendAnswer, Error>? = await withTimeout(remoteTimeout, activity: { [weak self] in
                self?.remoteActivity ?? ContinuousClock.now
            }) { [weak self] in
                do {
                    return .success(try await backend.ask(text, channel: .phone,
                                                          status: { [weak self] line in self?.statusLine = line },
                                                          activity: { [weak self] in self?.remoteActivity = ContinuousClock.now }))
                } catch {
                    return .failure(error)
                }
            }
            switch result {
            case .success(let answer):
                append(answer.answer, offline: false)
            case .failure(let error) where error is CancellationError:
                items.append(ChatItem(kind: .note, text: lang("Abgebrochen.", "Stopped."), at: now()))
            case .failure(let error) where error as? BackendError == .unreachable:
                await askOffline(text)
            case .failure(let error):
                items.append(ChatItem(kind: .error, text: error.localizedDescription, at: now()))
            case nil:
                // The backend was silent for too long; withTimeout cancelled the ask, which sends `cancel`.
                items.append(ChatItem(kind: .error, text: Task.isCancelled ? lang("Abgebrochen.", "Stopped.")
                                          : BackendError.timeout.errorDescription ?? "Lotti Brain is taking too long.", at: now()))
            }
        case .offline:
            await askOffline(text)
        }
    }

    /// Timers, navigation, reminders and the local day; everything else gets the short offline sentence.
    private func askOffline(_ text: String) async {
        let context = TodayComposer().nowLine(TodayInfo(now: now()))
        let offline = self.offline
        let result: Result<Answer, Error>? = await withTimeout(offlineTimeout) { [weak self] in
            do {
                return .success(try await offline.answer(text, context: context) { [weak self] line in self?.statusLine = line })
            } catch {
                return .failure(error)
            }
        }
        switch result {
        case .success(let answer):
            append(answer, offline: true)
        case .failure(let error) where error is CancellationError:
            items.append(ChatItem(kind: .note, text: lang("Abgebrochen.", "Stopped."), at: now()))
        case .failure(let error):
            items.append(ChatItem(kind: .error, text: error.localizedDescription, at: now()))
        case nil:
            offline.endConversation()
            items.append(ChatItem(kind: .error, text: lang("Da bin ich hängen geblieben.", "Sorry, I got stuck on that."), at: now()))
        }
    }

    private func append(_ answer: Answer, offline: Bool) {
        items.append(ChatItem(kind: .lotti, text: answer.sentence, followUps: answer.followUps, actions: answer.actions,
                              undo: answer.undo, offline: offline, at: now()))
    }

    // MARK: - Actions

    /// Runs an action you tapped. Phone actions go through the `Toolbox` (timers, reminders,
    /// navigation), server actions through the backend's `perform`. Nothing runs without the tap.
    /// The result goes into the chat and is returned, for screens that show it in place.
    @discardableResult
    func perform(_ action: ProposedAction, in itemID: UUID? = nil) async -> ActionResult {
        if let itemID, let index = items.firstIndex(where: { $0.id == itemID }) {
            items[index].actions.removeAll { $0 == action }
        }
        switch action.target {
        case .server:
            guard let id = action.actionId else { return report(ok: false, "That action has no id.", undo: nil) }
            do {
                let performed = try await backend.perform(actionId: id)
                return report(ok: performed.ok,
                              performed.text.isEmpty ? (performed.ok ? lang("Erledigt.", "Done.") : lang("Hat nicht geklappt.", "That didn't work.")) : performed.text,
                              undo: performed.undo)
            } catch {
                return report(ok: false, error.localizedDescription, undo: nil)
            }
        case .phone:
            let result = await toolbox.perform(action)
            return report(ok: result.ok, result.content, undo: nil)
        }
    }

    /// Takes back what Lotti just did. The backend's text repeats its raw label ("Undone: Remove
    /// Milch again"), so success just says Undone.
    func undo(_ undo: UndoAction, in itemID: UUID? = nil) async {
        if let itemID, let index = items.firstIndex(where: { $0.id == itemID }) { items[index].undo = nil }
        do {
            let performed = try await backend.undo(undo.id)
            report(ok: performed.ok, performed.ok ? lang("Rückgängig gemacht.", "Undone.") : performed.text, undo: nil)
        } catch {
            report(ok: false, error.localizedDescription, undo: nil)
        }
    }

    @discardableResult
    private func report(ok: Bool, _ text: String, undo: UndoAction?) -> ActionResult {
        items.append(ChatItem(kind: ok ? .note : .error, text: text, undo: undo, at: now()))
        return ActionResult(ok: ok, text: text)
    }

    // MARK: - Voice

    /// Hold to talk: the phone's microphone feeds the speech recognizer, the words fill `draft`.
    func beginTalking() {
        guard !isListening, !isAsking else { return }
        isListening = true
        voiceError = nil
        draft = ""
        listening = Task {
            do {
                let audio = try await microphone.start()
                // Let go before the microphone was up: stop it again.
                guard isListening else { return await microphone.stop() }
                for try await transcript in speech.transcribe(audio) { draft = transcript.text }
            } catch {
                voiceError = error.localizedDescription
            }
        }
    }

    /// Let go: the words so far (plus whatever the recognizer finishes within 3 s) are sent.
    func endTalking() {
        guard isListening else { return }
        isListening = false
        let task = listening
        Task {
            await microphone.stop()
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(3))
                task?.cancel()
            }
            await task?.value
            watchdog.cancel()
            listening = nil
            send(draft)
        }
    }

    // MARK: - From the backend

    func handle(_ event: BackendEvent) {
        switch event {
        case .connected(let welcome):
            Task { await loadHistory(welcome.conversationId) }
        case .message(let message):
            // Turns of this surface are already here; the other one (glasses) shows up.
            guard message.channel != .phone else { return }
            items.append(ChatItem(kind: message.role == .user ? .user : .lotti, text: message.text, channel: message.channel, at: message.at))
        case .catchup(let catchup):
            items.append(ChatItem(kind: .catchup, text: catchup.text, at: catchup.at))
        case .push(let item):
            guard item.isActive(at: now()) else { return }
            items.append(ChatItem(kind: .inbox, text: item.title, inboxId: item.id, at: item.createdAt ?? now()))
        case .conversation(_, let kind):
            if kind == "new" { items.append(ChatItem(kind: .divider, text: "New conversation", at: now())) }
        default:
            break
        }
    }

    /// The current conversation, once: what was said before the app started. After a reconnect only
    /// glasses turns newer than the last line are added (they came in while the socket was down).
    func loadHistory(_ conversationId: String) async {
        guard !conversationId.isEmpty, let turns = try? await loadTurns(conversationId) else { return }
        let made = turns.map {
            ChatItem(kind: $0.role == .user ? .user : .lotti, text: $0.text, channel: $0.channel, at: $0.at ?? now())
        }
        if !historyLoaded {
            historyLoaded = true
            items = made + items
        } else if let last = items.last(where: { $0.kind != .inbox })?.at {
            items += made.filter { $0.channel == .glasses && $0.at > last }
        }
    }
}
