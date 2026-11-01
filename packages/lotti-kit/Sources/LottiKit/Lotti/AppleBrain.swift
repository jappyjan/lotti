#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Lotti's chat on Apple's on-device model (decision D11). One model session per conversation,
/// so follow-ups keep their context; a new one starts when the conversation ends or the small
/// (4K) context fills up.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
public final class AppleBrain: Brain {
    public static let instructions = """
        You are Lotti, a small assistant on Jan's smart glasses. Jan lives in Berlin. \
        Brief, warm, a bit curious.
        Jan speaks to you; his words come from speech-to-text, so expect small mistakes and guess what he meant.
        Rules:
        - Answer in one or two short sentences, at most 30 words. The display is tiny.
        - Answer in the language of Jan's message (after "Jan:"), even if the facts are in another language.
        - No lists, no markdown, no emoji.
        - For time, date, calendar and weather use only the facts under "Now". Never invent appointments.
        - If you can't know something (news, prices, the web), say so in a few words.
        - Follow-ups: up to 3 short questions Jan might ask next, each 1 to 3 words, in the language of his message.
        """

    private let model: SystemLanguageModel
    private var session: LanguageModelSession?
    private let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 160)

    public init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    /// Why the model can't run, or nil if it can.
    public var unavailableReason: String? {
        switch model.availability {
        case .available: nil
        case .unavailable(let reason): "Apple Intelligence unavailable: \(reason)"
        }
    }

    public func prewarm() {
        guard unavailableReason == nil else { return }
        currentSession().prewarm()
    }

    public func answer(_ message: String, context: String) async throws -> Answer {
        if let reason = unavailableReason { throw BrainError.unavailable(reason) }
        let prompt = "Now:\n\(context)\n\nJan: \(message)"
        do {
            return try await respond(prompt)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // Start over with only this question; the older turns no longer fit.
            print("[Brain] context full, starting a new conversation")
            session = nil
            return try await respond(prompt)
        }
    }

    public func endConversation() {
        session = nil
    }

    private func respond(_ prompt: String) async throws -> Answer {
        let started = Date()
        let response = try await currentSession().respond(to: prompt, generating: ChatOutput.self, options: options)
        print(String(format: "[Brain] answered in %.1f s", Date().timeIntervalSince(started)))
        let output = response.content
        let followUps = output.followUps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Answer(sentence: output.sentence.trimmingCharacters(in: .whitespacesAndNewlines), followUps: followUps)
    }

    private func currentSession() -> LanguageModelSession {
        if let session { return session }
        let new = LanguageModelSession(model: model, instructions: Self.instructions)
        session = new
        return new
    }
}

public enum BrainError: Error, LocalizedError {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct ChatOutput {
    @Guide(description: "Lotti's answer: one or two short sentences, at most 30 words")
    var sentence: String
    @Guide(description: "Up to 3 things Jan might ask next, each 1 to 3 words", .maximumCount(3))
    var followUps: [String]
}
#endif
