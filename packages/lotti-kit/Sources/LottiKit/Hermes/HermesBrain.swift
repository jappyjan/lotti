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
    @ObservationIgnored private var messages: [ChatMessage] = []
    /// How many of Hermes's own tool-progress lines were logged this question (the rest are
    /// dropped: they'd flood the log, and they're never shown on the glasses anyway).
    @ObservationIgnored private var progressNotes = 0

    /// - Parameters:
    ///   - allowedReads: the read tools you share with Hermes (Settings), read at every call.
    ///   - maxRounds: phone-call rounds per question; after the last one Hermes is told to answer.
    public init(transport: any HermesTransport, toolbox: Toolbox, allowedReads: @escaping () -> Set<String>,
                isConfigured: @escaping () -> Bool, maxRounds: Int = 4) {
        self.transport = transport
        self.toolbox = toolbox
        self.allowedReads = allowedReads
        self.configured = isConfigured
        self.maxRounds = maxRounds
    }

    public var isConfigured: Bool { configured() }

    /// The messages so far (system prompt first), for tests and debugging.
    public var conversation: [ChatMessage] { messages }

    public func answer(
        _ message: String, context: String,
        status: @escaping @MainActor (String) -> Void,
        activity: @escaping @MainActor () -> Void = {}
    ) async throws -> Answer {
        let before = messages
        progressNotes = 0
        do {
            return try await run(message, context: context, status: status, activity: activity)
        } catch {
            // A failed or cancelled question leaves no trace, so "Try again" starts clean.
            messages = before
            note("✕ \(error.localizedDescription)")
            throw error
        }
    }

    public func endConversation() {
        messages = []
        trace = []
    }

    private func run(
        _ message: String, context: String,
        status: @escaping @MainActor (String) -> Void,
        activity: @escaping @MainActor () -> Void
    ) async throws -> Answer {
        let allowed = allowedReads()
        if messages.isEmpty {
            let reads = toolbox.reads.filter { allowed.contains($0.name) }
            messages = [ChatMessage(.system, HermesFormat.instructions(reads: reads, actions: toolbox.actions))]
            messages.append(ChatMessage(.user, HermesFormat.question(message, context: context)))
        } else {
            messages.append(ChatMessage(.user, HermesFormat.question(message, context: nil)))
        }
        note("→ \(message)")

        var rounds = 0
        while true {
            try Task.checkCancellation()
            // Hermes's own tool activity ("web_search", a raw command) goes to the log only:
            // it's noise on the glasses. But every byte restarts the caller's quiet clock.
            let text = try await transport.complete(messages) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.progressNotes < 10 else { return }
                    self.progressNotes += 1
                    self.note("· \(String(progress.prefix(60)))")
                }
            } activity: {
                Task { @MainActor in activity() }
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
                activity()
                let results = await toolbox.run(calls, allowed: allowed)
                try Task.checkCancellation()
                note("→ results " + results.map { "\($0.id) \($0.ok ? "ok" : "✕ \($0.content)")" }.joined(separator: ", "))
                messages.append(ChatMessage(.user, HermesFormat.results(results, final: rounds == maxRounds)))
            }
        }
    }

    private func note(_ line: String) {
        print("[Hermes] \(line)")
        trace.append(line)
        if trace.count > 60 { trace.removeFirst(trace.count - 60) }
    }
}
