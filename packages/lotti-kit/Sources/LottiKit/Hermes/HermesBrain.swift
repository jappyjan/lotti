import Foundation
import Observation

/// Lotti's connector to your Hermes. Runs the loop of Lotti's reply format: Hermes asks for phone
/// facts (several at once), the phone runs them and sends the results back, until Hermes answers.
/// Suggested actions come back as `ProposedAction`s for the rail; nothing changes without a tap.
@MainActor
@Observable
public final class HermesBrain: RemoteBrain {
    /// What happened in the current conversation, for the phone's debug screen. Newest last.
    public private(set) var trace: [String] = []

    @ObservationIgnored private let transport: any HermesTransport
    @ObservationIgnored private let toolbox: Toolbox
    @ObservationIgnored private let allowedReads: () -> Set<String>
    @ObservationIgnored private let configured: () -> Bool
    @ObservationIgnored private let maxRounds: Int
    @ObservationIgnored private let store: (any HermesHistoryStore)?
    @ObservationIgnored private let resetThreshold: @MainActor () -> Duration
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var messages: [ChatMessage] = []
    /// When Jan last asked, persisted with the messages. A gap longer than `resetThreshold()`
    /// starts a fresh conversation. This is the Hermes clock; `Conductor` has its own for the
    /// on-device brain, and the two never reset each other.
    @ObservationIgnored private var lastAsked: Date?

    /// The most recent messages kept alongside the system prompt, so a long conversation can't grow
    /// forever. Truncation drops whole question rounds only (see `capped`), at the start of every
    /// question and on load, so requests to Hermes and the stored copy are both bounded.
    ///
    /// Persistence stores committed states only: the messages before a question (with the new
    /// `lastAsked`), the messages after a successful answer, the rollback after a failure, and the
    /// empty state after a reset. A half-finished round (dangling call or results) never reaches
    /// the store, so a kill mid-question reloads the pre-question conversation.
    ///
    /// The system prompt (including what Hermes may read) is fixed when a conversation starts; a
    /// changed "Hermes may read" setting applies from the next fresh conversation. Accepted.
    static let maxTurns = 40

    /// - Parameters:
    ///   - allowedReads: the read tools you share with Hermes (Settings), read at every call.
    ///   - maxRounds: phone-call rounds per question; after the last one Hermes is told to answer.
    ///   - store: persists the conversation across app restarts; nil keeps it in memory only.
    ///   - resetThreshold: a gap since the last question longer than this starts fresh, read at
    ///     every call so the setting applies right away.
    ///   - now: the clock, injectable for tests.
    public init(transport: any HermesTransport, toolbox: Toolbox, allowedReads: @escaping () -> Set<String>,
                isConfigured: @escaping () -> Bool, maxRounds: Int = 4,
                store: (any HermesHistoryStore)? = nil,
                resetThreshold: @escaping @MainActor () -> Duration = { .seconds(7200) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.toolbox = toolbox
        self.allowedReads = allowedReads
        self.configured = isConfigured
        self.maxRounds = maxRounds
        self.store = store
        self.resetThreshold = resetThreshold
        self.now = now
        if let store, let loaded = try? store.load() {
            self.messages = Self.capped(loaded.messages)
            self.lastAsked = loaded.lastAsked
        }
    }

    public var isConfigured: Bool { configured() }

    /// The messages so far (system prompt first), for tests and debugging.
    public var conversation: [ChatMessage] { messages }

    public func answer(_ message: String, context: String, status: @escaping @MainActor (String) -> Void) async throws -> Answer {
        resetIfStale()
        messages = Self.capped(messages)
        let before = messages
        // Jan did ask, so the clock restarts now, even if the question fails. Stored with the
        // pre-question messages: the round in flight is not committed yet.
        lastAsked = now()
        save(before)
        do {
            let answer = try await run(message, context: context, status: status)
            save(messages)
            return answer
        } catch {
            // A failed or cancelled question leaves no trace, so "Try again" starts clean.
            messages = before
            save(before)
            note("✕ \(error.localizedDescription)")
            throw error
        }
    }

    public func endConversation() {
        messages = []
        trace = []
        lastAsked = nil
        save(messages)
    }

    /// A question asked after longer than the threshold starts a fresh conversation.
    private func resetIfStale() {
        guard let lastAsked, now().timeIntervalSince(lastAsked) > Double(resetThreshold().components.seconds) else { return }
        messages = []
        trace = []
    }

    private func run(_ message: String, context: String, status: @escaping @MainActor (String) -> Void) async throws -> Answer {
        let allowed = allowedReads()
        if messages.isEmpty {
            let reads = toolbox.reads.filter { allowed.contains($0.name) }
            messages = [ChatMessage(.system, HermesFormat.instructions(reads: reads, actions: toolbox.actions))]
        }
        // Every question carries a fresh time line, so a follow-up an hour later knows "now".
        messages.append(ChatMessage(.user, HermesFormat.question(message, context: context)))
        note("→ \(message)")

        var rounds = 0
        while true {
            try Task.checkCancellation()
            let text = try await transport.complete(messages) { progress in
                Task { @MainActor in status(progress) }
            }
            try Task.checkCancellation()
            messages.append(ChatMessage(.assistant, text))

            guard let reply = HermesFormat.parse(text) else {
                note("← text (not JSON): \(text.prefix(80))")
                return Answer(sentence: HermesFormat.plainSentence(text))
            }
            switch reply {
            case .answer(let sentence, let followUps, let suggested):
                let actions = suggested.compactMap(toolbox.proposal)
                note("← \(sentence)" + (actions.isEmpty ? "" : " [\(actions.map(\.title).joined(separator: ", "))]"))
                if actions.count < suggested.count { note("  dropped \(suggested.count - actions.count) invalid action(s)") }
                return Answer(sentence: sentence, followUps: followUps, actions: actions)

            case .calls(let calls, let statusText):
                rounds += 1
                if rounds > maxRounds {
                    note("✕ still calling after \(maxRounds) rounds")
                    return Answer(sentence: "Hermes needed more than I could check. Try asking more narrowly.")
                }
                note("← call " + calls.map { "\($0.tool)\(JSONValue.object($0.arguments).json)" }.joined(separator: ", "))
                status(statusText ?? toolbox.progress(for: calls))
                let results = await toolbox.run(calls, allowed: allowed)
                try Task.checkCancellation()
                note("→ results " + results.map { "\($0.id) \($0.ok ? "ok" : "✕ \($0.content)")" }.joined(separator: ", "))
                messages.append(ChatMessage(.user, HermesFormat.results(results, final: rounds == maxRounds)))
            }
        }
    }

    /// A user message that starts a round: a question built by `HermesFormat.question`, as opposed
    /// to the phone's `results` reply inside a round.
    private static func isQuestion(_ message: ChatMessage) -> Bool {
        message.role == .user && !(message.content.hasPrefix("{") && message.content.contains(#""type":"results""#))
    }

    /// Keeps the system prompt and drops the oldest whole question rounds until at most
    /// `maxTurns` messages follow it. The first kept message after the system prompt is always a
    /// question, never a results reply or an assistant call. A single round that alone exceeds the
    /// cap is kept whole.
    static func capped(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard messages.count > maxTurns + 1 else { return messages }
        let starts = messages.indices.dropFirst().filter { isQuestion(messages[$0]) }
        guard let last = starts.last else { return messages }
        let start = starts.first { messages.count - $0 <= maxTurns } ?? last
        return [messages[0]] + messages[start...]
    }

    private func save(_ messages: [ChatMessage]) {
        guard let store else { return }
        try? store.save(PersistedHermesSession(messages: Self.capped(messages), lastAsked: lastAsked))
    }

    private func note(_ line: String) {
        print("[Hermes] \(line)")
        trace.append(line)
        if trace.count > 60 { trace.removeFirst(trace.count - 60) }
    }
}
