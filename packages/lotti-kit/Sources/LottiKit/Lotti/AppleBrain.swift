#if canImport(FoundationModels) && !LOTTI_SKIP_FOUNDATION_MODELS
import Foundation
import FoundationModels
import Observation

/// Lotti's offline chat on Apple's on-device model (decision D11): timers, navigation, reminders
/// and the local day only; the backend answers everything else, and offline that gets a short
/// "I'm offline" sentence. A pipeline of small steps
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

        // 1. Choose tools: rules first, the model only when no rule matches. Only the offline
        // tools count; anything else is the backend's and gets the offline sentence.
        let language = LocalPipeline.language(of: message)
        let names = Set(toolbox.specs.map(\.name))
        let choice: LocalPipeline.Choice
        switch LocalPipeline.offlinePlan(message, names: names) {
        case .tools(let tools)?:
            note("rules: \(tools.joined(separator: ", "))")
            choice = LocalPipeline.Choice(tools: tools)
        case .unsupported?:
            note("rules: not an offline task")
            return offline(message, language: language, started: started)
        case nil:
            choice = try await choose(message, now: context)
        }
        if choice.tools.isEmpty {
            note("→ offline sentence")
            return offline(message, language: language, started: started)
        }

        // 2. Fill in each chosen tool's arguments. A timer and a destination are parsed from the
        // words first (instant and exact); the model only fills in what the parser can't.
        var calls: [ToolCall] = []
        for name in choice.tools {
            guard let spec = toolbox.tool(named: name)?.spec else { continue }
            if let parsed = OfflineIntents.arguments(for: name, message: message) {
                note("\(name) arguments parsed: \(JSONValue.object(parsed).json)")
                calls.append(ToolCall(id: name, tool: name, arguments: parsed))
                continue
            }
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

    private func offline(_ message: String, language: String, started: Date) -> Answer {
        let sentence = LocalPipeline.offlineSentence(language: language)
        remember(message, sentence, facts: [], started: started)
        return Answer(sentence: sentence)
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
        return LocalPipeline.parseChoice(json, tools: chooserTools)
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
        let prompt = LocalPipeline.answerPrompt(message, now: now, history: history, facts: facts)
        let output: ChatOutput
        do {
            let session = LanguageModelSession(model: model, instructions: LocalPipeline.answerInstructions(language: language))
            output = try await session.respond(to: prompt, generating: ChatOutput.self,
                                               options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 160)).content
        } catch LanguageModelSession.GenerationError.unsupportedLanguageOrLocale {
            // Apple's language check sometimes rejects facts (a street address did it). Shorter
            // instructions, then plain text, then the facts as they are.
            note("unsupported language → retrying with short instructions")
            return try await composeFallback(prompt, language: language, facts: facts)
        }
        if !output.canAnswer || LocalPipeline.soundsUnsure(output.sentence) {
            // The facts don't hold the answer: that is for the backend, which isn't reachable.
            note("can't answer (\(output.sentence)) → offline sentence")
            return Answer(sentence: LocalPipeline.offlineSentence(language: language))
        }
        let followUps = output.followUps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return Answer(sentence: output.sentence.trimmingCharacters(in: .whitespacesAndNewlines), followUps: followUps)
    }

    private func composeFallback(_ prompt: String, language: String, facts: [LocalPipeline.Fact]) async throws -> Answer {
        let instructions = LocalPipeline.shortAnswerInstructions(language: language)
        if let output = try? await LanguageModelSession(model: model, instructions: instructions)
            .respond(to: prompt, generating: ChatOutput.self, options: GenerationOptions(temperature: 0.3)).content {
            return Answer(sentence: output.sentence, followUps: output.followUps)
        }
        if let text = try? await LanguageModelSession(model: model, instructions: instructions)
            .respond(to: prompt, options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 100)).content {
            return Answer(sentence: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        note("still unsupported → showing the facts")
        guard !facts.isEmpty else { throw LanguageModelSession.GenerationError.unsupportedLanguageOrLocale(.init(debugDescription: "")) }
        return Answer(sentence: facts.map(\.text).joined(separator: " "))
    }

    /// The tools the model may pick. Not `location`: the model picked it for "where is the meeting"
    /// and mixed Jan's address into the answer; "wo bin ich / where am I" is a rule.
    private var chooserTools: [PhoneToolSpec] {
        toolbox.specs.filter { !LocalPipeline.rulesOnly.contains($0.name) }
    }

    private func chooserSession() -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: LocalPipeline.chooseInstructions(tools: chooserTools))
    }

    /// The chooser's output: intent, then up to three tools from a fixed list.
    @ObservationIgnored private lazy var chooseSchema: GenerationSchema = {
        let root = DynamicGenerationSchema(name: "Choice", properties: [
            DynamicGenerationSchema.Property(name: "intent", description: "What Jan wants, in a few English words",
                                             schema: DynamicGenerationSchema(type: String.self)),
            DynamicGenerationSchema.Property(
                name: "tools", description: "The tools needed, usually one or none",
                schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(name: "Tool", anyOf: LocalPipeline.options(tools: chooserTools)),
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
