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
    /// Only a dead end replaces it: Hermes no longer has the session, or it is stuck behind a turn
    /// that will never finish (see `HermesError.sessionGone`, `.sessionStuck`).
    private var session: String?
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
        do {
            if let id = try store?.load(), Self.isUsable(id) { self.session = id }
        } catch {
            print("[Hermes] ✕ couldn't load the session: \(error.localizedDescription)")
        }
    }

    public var isConfigured: Bool { configured() }

    /// The Hermes session being continued, nil before the very first question.
    public var sessionID: String? { session }

    public func answer(_ message: String, context: String, status: @escaping @MainActor (String) -> Void) async throws -> Answer {
        turn += 1
        let mine = turn
        var used = currentSession()
        do {
            do {
                return try await run(message, context: context, session: used, turn: mine, status: status)
            } catch HermesError.sessionGone where mine == turn && session == used {
                // Deleted at Hermes (its id stays retired): continue in a new session, asking again.
                note("✕ Hermes lost the session, starting a new one")
                startNewSession()
                used = currentSession()
                return try await run(message, context: context, session: used, turn: mine, status: status)
            }
        } catch {
            // Stuck behind a turn that never finishes (Hermes restarted mid-question): the next
            // question goes to a new session, unless a newer question already moved on.
            if case HermesError.sessionStuck = error, session == used {
                note("✕ the session is stuck, the next question starts a new one")
                startNewSession()
            }
            // Hermes may keep what it got of a failed or cancelled question; "Try again" asks anew
            // in the same session.
            note("✕ \(error.localizedDescription)")
            throw error
        }
    }

    /// The session to continue, made (and saved, before the first request, so a restart
    /// continues it) when there is none yet.
    private func currentSession() -> String {
        if let session { return session }
        let new = "lotti-\(UUID().uuidString.lowercased())"
        session = new
        do { try store?.save(new) } catch { note("✕ couldn't save the session: \(error.localizedDescription)") }
        return new
    }

    /// Replaces a dead-end session right away (saved), so a restart doesn't reload it.
    private func startNewSession() {
        session = nil
        _ = currentSession()
    }

    /// What Hermes accepts as a session id (no spaces, path characters or control characters, at
    /// most 256 long); anything else in the store is replaced by a new id.
    static func isUsable(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 256 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
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
        // Every question carries a fresh time line, so a follow-up an hour later knows "now".
        var latest = ChatMessage(.user, HermesFormat.question(message, context: context))
        note("→ \(message)")

        var rounds = 0
        while true {
            try checkCurrent()
            // Hermes doesn't store the system prompt; it is rebuilt for every request, so a changed
            // "Hermes may read" applies at the next request (and a hidden read can't run).
            let allowed = allowedReads()
            let reads = toolbox.reads.filter { allowed.contains($0.name) }
            let system = ChatMessage(.system, HermesFormat.instructions(reads: reads, actions: toolbox.actions))
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
