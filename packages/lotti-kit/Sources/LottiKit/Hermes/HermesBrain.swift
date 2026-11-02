import Foundation
import Observation

/// Lotti's connector to your Hermes. Runs the loop of Lotti's reply format: Hermes asks for phone
/// facts (several at once), the phone runs them and sends the results back, until Hermes answers.
/// Suggested actions come back as `ProposedAction`s for the rail; nothing changes without a tap.
@MainActor
@Observable
public final class HermesBrain: RemoteBrain {
    /// What happened in this run of the app, for the phone's debug screen. Newest last.
    public private(set) var trace: [String] = []

    @ObservationIgnored private let transport: any HermesTransport
    @ObservationIgnored private let toolbox: Toolbox
    @ObservationIgnored private let allowedReads: () -> Set<String>
    @ObservationIgnored private let configured: () -> Bool
    @ObservationIgnored private let maxRounds: Int
    @ObservationIgnored private let store: (any HermesSessionStore)?
    /// The Hermes session the conversation lives in (`X-Hermes-Session-Id`). Hermes keeps the
    /// history, tool rounds and its own tool results, and compacts it when it gets long; the phone
    /// only remembers which session to continue. Made once, at the first question, then kept forever:
    /// nothing resets it (not inactivity, not glasses-off, not a changed address or hidden read).
    @ObservationIgnored private var session: String?
    /// Bumped by every new question. A question that finds it changed has been superseded (Jan
    /// asked again meanwhile) and sends nothing more.
    @ObservationIgnored private var turn = 0

    /// - Parameters:
    ///   - allowedReads: the read tools you share with Hermes (Settings), read at every call.
    ///   - maxRounds: phone-call rounds per question; after the last one Hermes is told to answer.
    ///   - store: persists the session across app restarts; nil keeps it in memory only.
    public init(transport: any HermesTransport, toolbox: Toolbox, allowedReads: @escaping () -> Set<String>,
                isConfigured: @escaping () -> Bool, maxRounds: Int = 4,
                store: (any HermesSessionStore)? = nil) {
        self.transport = transport
        self.toolbox = toolbox
        self.allowedReads = allowedReads
        self.configured = isConfigured
        self.maxRounds = maxRounds
        self.store = store
        if let id = try? store?.load(), !id.isEmpty { self.session = id }
    }

    public var isConfigured: Bool { configured() }

    /// The Hermes session being continued, nil before the very first question.
    public var sessionID: String? { session }

    public func answer(_ message: String, context: String, status: @escaping @MainActor (String) -> Void) async throws -> Answer {
        let session = self.session ?? "lotti-\(UUID().uuidString.lowercased())"
        if self.session == nil {
            self.session = session
            try? store?.save(session)  // before the first request, so a restart continues it
        }
        turn += 1
        do {
            return try await run(message, context: context, session: session, turn: turn, status: status)
        } catch {
            // Hermes may keep what it got of a failed or cancelled question; "Try again" asks anew
            // in the same session.
            note("✕ \(error.localizedDescription)")
            throw error
        }
    }

    /// One question: each request carries the system prompt and only the newest message (the
    /// question, then the phone's results); Hermes adds it to the session's history.
    private func run(_ message: String, context: String, session: String, turn mine: Int,
                     status: @escaping @MainActor (String) -> Void) async throws -> Answer {
        // A superseded question (a newer one, or double tap) stops before its next request.
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard mine == turn else { throw CancellationError() }
        }
        let allowed = allowedReads()
        // Sent with every request (Hermes applies it on top of the session on every request), so a changed "Hermes may read"
        // applies at the next question.
        let reads = toolbox.reads.filter { allowed.contains($0.name) }
        let system = ChatMessage(.system, HermesFormat.instructions(reads: reads, actions: toolbox.actions))
        // Every question carries a fresh time line, so a follow-up an hour later knows "now".
        var latest = ChatMessage(.user, HermesFormat.question(message, context: context))
        note("→ \(message)")

        var rounds = 0
        while true {
            try checkCurrent()
            let text = try await transport.complete([system, latest], session: session) { progress in
                Task { @MainActor in status(progress) }
            }
            try checkCurrent()

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
                try checkCurrent()
                note("→ results " + results.map { "\($0.id) \($0.ok ? "ok" : "✕ \($0.content)")" }.joined(separator: ", "))
                latest = ChatMessage(.user, HermesFormat.results(results, final: rounds == maxRounds))
            }
        }
    }

    private func note(_ line: String) {
        print("[Hermes] \(line)")
        trace.append(line)
        if trace.count > 60 { trace.removeFirst(trace.count - 60) }
    }
}
