#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Runs eval cases against any FoundationModels `LanguageModel` and prints `[Eval]` lines.
@available(iOS 27.0, macOS 27.0, *)
public struct EvalRunner: Sendable {
    public let set: EvalSet
    public let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 300)

    public init(set: EvalSet) {
        self.set = set
    }

    /// Runs `cases` in order; one fresh session per case, like one event in Lotti.
    public func run(
        _ model: some LanguageModel, label: String, cases: [EvalCase]? = nil,
        log: @Sendable (String) -> Void = { print($0) }
    ) async -> [CaseResult] {
        var results: [CaseResult] = []
        for evalCase in cases ?? set.cases {
            let result = await run(evalCase, model: model, label: label)
            log(EvalLog.line("case", result))
            results.append(result)
        }
        for summary in TaskSummary.make(results) { log(EvalLog.line("summary", summary)) }
        return results
    }

    public func run(_ evalCase: EvalCase, model: some LanguageModel, label: String) async -> CaseResult {
        let tools = evalCase.task == .tool ? PhoneTools.all : []
        let session = LanguageModelSession(model: model, tools: tools, instructions: Prompts.instructions(for: evalCase.task))
        let prompt = Prompts.prompt(for: evalCase, user: set.user)
        let start = ContinuousClock.now
        var result = CaseResult(
            model: label, caseID: evalCase.id, task: evalCase.task, checks: [], totalMs: 0, footprintMB: 0)
        do {
            let measured: Measured
            switch evalCase.task {
            case .triage:
                let m = try await stream(session, prompt, TriageOutput.self)
                measured = m.with(m.content.output)
            case .summary:
                let m = try await stream(session, prompt, SummaryOutput.self)
                measured = m.with(CaseOutput(text: m.content.sentence))
            case .rail:
                let m = try await stream(session, prompt, RailOutput.self)
                measured = m.with(CaseOutput(choices: m.content.choices))
            case .reply:
                let m = try await stream(session, prompt, ReplyOutput.self)
                measured = m.with(CaseOutput(text: m.content.message))
            case .screen, .tool:
                let m = try await stream(session, prompt, ScreenOutput.self)
                var output = m.content.output
                if evalCase.task == .tool { output.toolCalls = Self.toolCalls(in: session.transcript) }
                measured = m.with(output)
            }
            result.output = measured.output
            result.ttftMs = measured.ttftMs
            result.inputTokens = measured.inputTokens
            result.outputTokens = measured.outputTokens
            result.checks = Scoring.checks(for: evalCase, output: measured.output)
        } catch {
            result.error = String(describing: error)
            if evalCase.task == .tool {
                // Still record which tools were called before the failure.
                result.output = CaseOutput(toolCalls: Self.toolCalls(in: session.transcript))
            }
        }
        result.totalMs = Self.ms(ContinuousClock.now - start)
        result.footprintMB = memoryFootprintMB()
        return result
    }

    // MARK: - Streaming and timing

    struct Measured {
        var output: CaseOutput
        var ttftMs: Int?
        var inputTokens: Int?
        var outputTokens: Int?
    }

    struct Streamed<T> {
        var content: T
        var ttftMs: Int?
        var inputTokens: Int?
        var outputTokens: Int?
        func with(_ output: CaseOutput) -> Measured {
            Measured(output: output, ttftMs: ttftMs, inputTokens: inputTokens, outputTokens: outputTokens)
        }
    }

    private func stream<T: Generable>(_ session: LanguageModelSession, _ prompt: String, _ type: T.Type) async throws -> Streamed<T> {
        let start = ContinuousClock.now
        var ttft: Duration?
        var last: LanguageModelSession.ResponseStream<T>.Snapshot?
        for try await snapshot in session.streamResponse(to: prompt, generating: T.self, options: options) {
            if ttft == nil { ttft = ContinuousClock.now - start }
            last = snapshot
        }
        guard let last else { throw EvalError.emptyResponse }
        return Streamed(
            content: try T(last.rawContent), ttftMs: ttft.map(Self.ms),
            inputTokens: last.usage.input.totalTokenCount, outputTokens: last.usage.output.totalTokenCount)
    }

    static func toolCalls(in transcript: Transcript) -> [CaseOutput.ToolCall] {
        transcript.flatMap { entry -> [CaseOutput.ToolCall] in
            guard case .toolCalls(let calls) = entry else { return [] }
            return calls.map { CaseOutput.ToolCall(name: $0.toolName, arguments: $0.arguments.jsonString) }
        }
    }

    static func ms(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

enum EvalError: Error {
    case emptyResponse
}
#endif
