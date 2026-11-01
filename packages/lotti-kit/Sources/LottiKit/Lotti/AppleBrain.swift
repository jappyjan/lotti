#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Observation

/// Lotti's chat on Apple's on-device model (decision D11), as a pipeline of small steps
/// (see `LocalPipeline`): choose tools from a list, fill in each tool's arguments, run the reads,
/// shorten long results, then write the answer from the facts. Every step is a fresh model
/// session with a small prompt, so the 4K context never fills up; the conversation is carried
/// as a few earlier turns.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
@Observable
public final class AppleBrain: Brain {
    /// What happened in the last answer, for the phone's debug screen.
    public private(set) var trace: [String] = []

    @ObservationIgnored private let model: SystemLanguageModel
    @ObservationIgnored private let toolbox: Toolbox
    @ObservationIgnored private var history: [LocalPipeline.Turn] = []
    @ObservationIgnored private var warmChooser: LanguageModelSession?

    /// `tools`: the phone tools this brain may use. Reads run right away; actions only become
    /// proposals for the rail.
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
        guard unavailableReason == nil, warmChooser == nil else { return }
        let session = chooserSession()
        session.prewarm()
        warmChooser = session
    }

    public func endConversation() {
        history = []
    }

    public func answer(_ message: String, context: String,
                       status: @escaping @MainActor (String) -> Void) async throws -> Answer {
        if let reason = unavailableReason { throw BrainError.unavailable(reason) }
        trace = []
        let started = Date()
        note("Jan: \(message)")

        // 1. Choose tools: rules first, the model only when no rule matches.
        let language = LocalPipeline.language(of: message)
        let choice: LocalPipeline.Choice
        if let tools = LocalPipeline.ruleTools(message, tools: toolbox.specs) {
            note("rules: \(tools.joined(separator: ", "))")
            choice = LocalPipeline.Choice(tools: tools)
        } else {
            choice = try await choose(message, now: context)
        }
        if choice.tools.contains("hermes") {
            note("→ Hermes")
            return Answer(sentence: LocalPipeline.handoffSentence(language: language), handoff: message)
        }

        // 2. Fill in each chosen tool's arguments.
        var calls: [ToolCall] = []
        for name in choice.tools {
            guard let spec = toolbox.tool(named: name)?.spec else { continue }
            let arguments = spec.parameters.isEmpty ? [:] : try await fillIn(spec, message: message, now: context)
            calls.append(ToolCall(id: name, tool: name, arguments: arguments))
        }

        // 3. Actions are only prepared; with one, the sentence is fixed.
        let prepared = calls.filter { toolbox.tool(named: $0.tool)?.spec.effect == .action }.compactMap { call in
            let proposal = toolbox.proposal(for: call)
            if proposal == nil { note("✕ invalid \(call.tool)\(JSONValue.object(call.arguments).json)") }
            return proposal
        }
        if !prepared.isEmpty {
            let sentence = LocalPipeline.preparedSentence(prepared, language: language)
            remember(message, sentence, facts: [], started: started)
            return Answer(sentence: sentence, actions: prepared)
        }

        // 4. Run the reads, all at once.
        var facts: [LocalPipeline.Fact] = []
        let reads = calls.filter { toolbox.tool(named: $0.tool)?.spec.effect == .read }
        if !reads.isEmpty {
            status(toolbox.progress(for: reads))
            let results = await toolbox.run(reads, allowed: Set(toolbox.reads.map(\.name)))
            for (call, result) in zip(reads, results) {
                note("\(call.tool)\(JSONValue.object(call.arguments).json) → \(result.content.prefix(100))")
                facts.append(LocalPipeline.Fact(tool: call.tool, text: result.ok ? result.content : "unavailable (\(result.content))"))
            }
        }

        // 5. Shorten long results to what the question needs.
        for index in facts.indices where facts[index].text.count > LocalPipeline.compactAbove {
            facts[index].text = try await compact(message, fact: facts[index])
        }

        // 6. The answer, from the facts only.
        let answer = try await compose(message, now: context, language: language, facts: facts)
        remember(message, answer.sentence, facts: facts, started: started)
        return answer
    }

    private func remember(_ message: String, _ sentence: String, facts: [LocalPipeline.Fact], started: Date) {
        history.append(LocalPipeline.Turn(jan: message, lotti: sentence, facts: facts))
        if history.count > 3 { history.removeFirst(history.count - 3) }
        note(String(format: "Lotti (%.1f s): %@", Date().timeIntervalSince(started), sentence))
    }

    // MARK: Steps

    private func choose(_ message: String, now: String) async throws -> LocalPipeline.Choice {
        let session = warmChooser ?? chooserSession()
        warmChooser = nil
        let started = Date()
        let response = try await session.respond(to: LocalPipeline.questionPrompt(message, now: now, history: history),
                                                 schema: chooseSchema, options: GenerationOptions(temperature: 0))
        let json = (try? JSONValue(json: response.content.jsonString)) ?? .object([:])
        note(String(format: "choose (%.1f s): %@", Date().timeIntervalSince(started), json.json))
        return LocalPipeline.parseChoice(json, tools: toolbox.specs)
    }

    private func fillIn(_ spec: PhoneToolSpec, message: String, now: String) async throws -> [String: JSONValue] {
        let session = LanguageModelSession(model: model, instructions: LocalPipeline.argumentsInstructions(spec))
        let properties = spec.parameters.map { parameter in
            DynamicGenerationSchema.Property(name: parameter.name, description: parameter.description,
                                             schema: Self.schema(for: parameter, in: spec), isOptional: parameter.isOptional)
        }
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: spec.name, properties: properties), dependencies: [])
        let started = Date()
        // No date in this prompt: the model would copy it instead of writing "tomorrow".
        let response = try await session.respond(to: LocalPipeline.questionPrompt(message, now: nil, history: history),
                                                 schema: schema, options: GenerationOptions(temperature: 0))
        let json = (try? JSONValue(json: response.content.jsonString)) ?? .object([:])
        note(String(format: "\(spec.name) arguments (%.1f s): %@", Date().timeIntervalSince(started), json.json))
        return json.object ?? [:]
    }

    private func compact(_ message: String, fact: LocalPipeline.Fact) async throws -> String {
        let session = LanguageModelSession(model: model)
        let response = try await session.respond(to: LocalPipeline.compactPrompt(message, fact: fact),
                                                 options: GenerationOptions(temperature: 0, maximumResponseTokens: 120))
        let short = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        note("shortened \(fact.tool): \(short.prefix(100))")
        return short.isEmpty ? fact.text : short
    }

    private func compose(_ message: String, now: String, language: String,
                         facts: [LocalPipeline.Fact]) async throws -> Answer {
        let session = LanguageModelSession(model: model, instructions: LocalPipeline.answerInstructions(language: language))
        let prompt = LocalPipeline.answerPrompt(message, now: now, history: history, facts: facts)
        let response = try await session.respond(to: prompt, generating: ChatOutput.self,
                                                 options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 160))
        let output = response.content
        if !output.canAnswer {
            // The facts don't hold the answer: Hermes may know. The conductor says so if Hermes isn't set up.
            note("can't answer (\(output.sentence)) → Hermes")
            return Answer(sentence: LocalPipeline.handoffSentence(language: language), handoff: message)
        }
        let followUps = output.followUps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return Answer(sentence: output.sentence.trimmingCharacters(in: .whitespacesAndNewlines), followUps: followUps)
    }

    private func chooserSession() -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: LocalPipeline.chooseInstructions(tools: toolbox.specs))
    }

    /// The chooser's output: intent, then up to three tools from a fixed list.
    @ObservationIgnored private lazy var chooseSchema: GenerationSchema = {
        let root = DynamicGenerationSchema(name: "Choice", properties: [
            DynamicGenerationSchema.Property(name: "intent", description: "What Jan wants, in a few English words",
                                             schema: DynamicGenerationSchema(type: String.self)),
            DynamicGenerationSchema.Property(
                name: "tools", description: "The tools needed, usually one or none",
                schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(name: "Tool", anyOf: LocalPipeline.options(tools: toolbox.specs)),
                                                minimumElements: 0, maximumElements: 3)),
        ])
        return try! GenerationSchema(root: root, dependencies: [])
    }()

    static func schema(for parameter: ToolParameter, in spec: PhoneToolSpec) -> DynamicGenerationSchema {
        switch parameter.kind {
        case .string: DynamicGenerationSchema(type: String.self)
        case .integer: DynamicGenerationSchema(type: Int.self)
        case .number: DynamicGenerationSchema(type: Double.self)
        case .boolean: DynamicGenerationSchema(type: Bool.self)
        case .oneOf(let choices): DynamicGenerationSchema(name: "\(spec.name)_\(parameter.name)", anyOf: choices)
        }
    }

    private func note(_ line: String) {
        print("[Brain] \(line)")
        trace.append(line)
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
    @Guide(description: "true if the facts, the conversation or the date and time answer Jan, or it is small talk; false if they don't (you would have to guess or say you don't know)")
    var canAnswer: Bool
    @Guide(description: "Lotti's answer: one or two short sentences, at most 30 words")
    var sentence: String
    @Guide(description: "Up to 3 things Jan might ask next, each 1 to 3 words", .maximumCount(3))
    var followUps: [String]
}
#endif
