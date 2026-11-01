#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Synchronization

/// Lotti's chat on Apple's on-device model (decision D11). One model session per conversation,
/// so follow-ups keep their context; a new one starts when the conversation ends or the small
/// (4K) context fills up.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
public final class AppleBrain: Brain {
    public static let persona = """
        You are Lotti, a small assistant on Jan's smart glasses. Jan lives in Berlin. \
        Brief, warm, a bit curious.
        Jan speaks to you; his words come from speech-to-text, so expect small mistakes and guess what he meant.
        Rules:
        - Answer in one or two short sentences, at most 30 words. The display is tiny.
        - Answer in the language of Jan's message (after "Jan:"), even if the facts are in another language: translate them (e.g. "cloudy" → "bewölkt").
        - No lists, no markdown, no emoji.
        - For time, date, calendar and weather use only the facts under "Now" or from a tool. Never invent appointments.
        - If Jan wants something you can't know (news, the web, prices, opening hours, places, research) or names \
        Hermes: call ask_hermes with his question, then say only "Let me ask Hermes."
        - Follow-ups: up to 3 short questions Jan might ask next, each 1 to 3 words, in the language of his message.
        """

    /// The persona plus a rule per tool. A ~3B model only calls tools when told exactly when.
    public static func instructions(tools: [PhoneToolSpec]) -> String {
        var rules: [String] = []
        let names = Set(tools.map(\.name))
        let actions = tools.filter { $0.effect == .action }.map(\.name)
        if !actions.isEmpty {
            rules.append("- To set a timer or reminder, call \(actions.joined(separator: " or ")) first. "
                + "It only prepares it; Jan starts it with one tap. Then say in a few words what you prepared.")
        }
        if names.contains("calendar") {
            rules.append("- If Jan asks about tomorrow, a weekday or a date, call calendar first with that day. "
                + "Never say a day is free without calling calendar.")
        }
        return rules.isEmpty ? persona : persona + "\n" + rules.joined(separator: "\n")
    }

    private let model: SystemLanguageModel
    private let toolbox: Toolbox
    private let turn = TurnCollector()
    private var session: LanguageModelSession?
    private let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 160)

    /// `tools`: the phone tools this model may use. Keep it small: every tool costs prompt
    /// tokens in a 4K context. Reads run right away; actions only become proposals.
    public init(model: SystemLanguageModel = .default, tools: Toolbox = Toolbox()) {
        self.model = model
        self.toolbox = tools
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
        turn.clear()
        let response: LanguageModelSession.Response<ChatOutput>
        do {
            response = try await currentSession().respond(to: prompt, generating: ChatOutput.self, options: options)
        } catch LanguageModelSession.GenerationError.decodingFailure(let context) {
            // The model sometimes answers in prose after a tool call. A hand-off still counts.
            if let handoff = turn.handoff { return Answer(sentence: "Let me ask Hermes.", handoff: handoff) }
            throw LanguageModelSession.GenerationError.decodingFailure(context)
        }
        print(String(format: "[Brain] answered in %.1f s", Date().timeIntervalSince(started)))
        let output = response.content
        let followUps = output.followUps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Answer(sentence: output.sentence.trimmingCharacters(in: .whitespacesAndNewlines), followUps: followUps,
                      actions: turn.actions, handoff: turn.handoff)
    }

    private func currentSession() -> LanguageModelSession {
        if let session { return session }
        let tools: [any Tool] = toolbox.specs.compactMap { ModelTool(spec: $0, toolbox: toolbox, turn: turn) }
            + [AskHermesTool(turn: turn)]
        let new = LanguageModelSession(model: model, tools: tools, instructions: Self.instructions(tools: toolbox.specs))
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

/// Hands the question to Hermes. Always offered: if Hermes isn't set up, the conductor says so.
@available(iOS 26.0, macOS 26.0, *)
struct AskHermesTool: Tool {
    let name = "ask_hermes"
    let description = "Pass Jan's question to Hermes, a bigger assistant with the web and research tools."
    let turn: TurnCollector

    @Generable
    struct Arguments {
        @Guide(description: "Jan's question, in his words")
        var question: String
    }

    func call(arguments: Arguments) async throws -> String {
        print("[Brain] ask_hermes \(arguments.question)")
        turn.handOff(arguments.question)
        return "Hermes will answer. Say only: Let me ask Hermes."
    }
}

/// A phone tool as Foundation Models sees it. Arguments arrive as generated JSON and go through
/// the toolbox's validation; actions are only collected as proposals.
@available(iOS 26.0, macOS 26.0, *)
struct ModelTool: Tool {
    typealias Arguments = GeneratedContent

    let spec: PhoneToolSpec
    let toolbox: Toolbox
    let turn: TurnCollector
    let parameters: GenerationSchema

    init?(spec: PhoneToolSpec, toolbox: Toolbox, turn: TurnCollector) {
        let properties = spec.parameters.map { parameter in
            DynamicGenerationSchema.Property(
                name: parameter.name, description: parameter.description,
                schema: Self.schema(for: parameter, in: spec), isOptional: parameter.isOptional)
        }
        let root = DynamicGenerationSchema(name: spec.name, description: spec.description, properties: properties)
        guard let schema = try? GenerationSchema(root: root, dependencies: []) else { return nil }
        self.spec = spec
        self.toolbox = toolbox
        self.turn = turn
        self.parameters = schema
    }

    var name: String { spec.name }
    var description: String { spec.description }

    func call(arguments: GeneratedContent) async throws -> String {
        let values = (try? JSONValue(json: arguments.jsonString))?.object ?? [:]
        let call = ToolCall(id: spec.name, tool: spec.name, arguments: values)
        print("[Brain] tool \(spec.name) \(JSONValue.object(values).json)")
        guard spec.effect == .action else {
            return await toolbox.run([call], allowed: [spec.name]).first?.content ?? ""
        }
        guard let proposal = toolbox.proposal(for: call) else {
            return "That didn't work: the arguments were wrong. Ask Jan for what's missing."
        }
        turn.add(proposal)
        return "Prepared \"\(proposal.title)\". Jan starts it with one tap. Say what you prepared; don't say it's done."
    }

    static func schema(for parameter: ToolParameter, in spec: PhoneToolSpec) -> DynamicGenerationSchema {
        switch parameter.kind {
        case .string: DynamicGenerationSchema(type: String.self)
        case .integer: DynamicGenerationSchema(type: Int.self)
        case .number: DynamicGenerationSchema(type: Double.self)
        case .boolean: DynamicGenerationSchema(type: Bool.self)
        case .oneOf(let choices): DynamicGenerationSchema(name: "\(spec.name)_\(parameter.name)", anyOf: choices)
        }
    }
}

/// What the model's tool calls left during one answer: prepared actions and a hand-off to
/// Hermes. Tools run off the main actor.
final class TurnCollector: Sendable {
    private let state = Mutex<(actions: [ProposedAction], handoff: String?)>(([], nil))

    func add(_ action: ProposedAction) { state.withLock { $0.actions.append(action) } }
    func handOff(_ question: String) { state.withLock { $0.handoff = question } }
    func clear() { state.withLock { $0 = ([], nil) } }
    var actions: [ProposedAction] { state.withLock { $0.actions } }
    var handoff: String? { state.withLock { $0.handoff } }
}
#endif
