import Foundation
import Testing
@testable import LottiKit

/// Talks to a real Hermes (or `scripts/mock-hermes.py`) over HTTP. Skipped unless HERMES_URL
/// and HERMES_KEY are set:
///
///     HERMES_URL=http://127.0.0.1:8642 HERMES_KEY=test swift test --filter LiveHermes
@MainActor
@Suite(.enabled(if: liveHermesConfig() != nil, "set HERMES_URL and HERMES_KEY"))
struct LiveHermesTests {
    let client = HermesClient { liveHermesConfig() }

    @Test func keyWorks() async throws {
        let model = try await client.check()
        print("[Live] model: \(model)")
    }

    @Test func answersWithPhoneTools() async throws {
        let calendar = FakeTool("calendar", parameters: [ToolParameter("from", .string, "YYYY-MM-DD or tomorrow", optional: true)],
                                result: "Mon 2 Nov: 09:30–09:45 Standup; 11:00–12:00 Ben (Café Kreuzberg)")
        let weather = FakeTool("weather", result: "Weather tomorrow: light rain, 6–11°C")
        let brain = HermesBrain(transport: client, toolbox: Toolbox([calendar, weather, FakeTool.timer()], callTimeout: .seconds(5)),
                                allowedReads: { ["calendar", "weather"] }, isConfigured: { true })
        var statuses: [String] = []
        let answer = try await brain.answer("How does tomorrow look? Do I need an umbrella?",
                                            context: "Now: Sunday 1 November 2026, 14:00") { statuses.append($0) }
        print("[Live] statuses: \(statuses)")
        print("[Live] answer: \(answer)")
        print("[Live] trace:\n" + brain.trace.joined(separator: "\n"))
        #expect(!answer.sentence.isEmpty)
    }

    @Test func followUpsContinueTheSession() async throws {
        let brain = HermesBrain(transport: client, toolbox: Toolbox([FakeTool.timer()], callTimeout: .seconds(5)),
                                allowedReads: { [] }, isConfigured: { true })
        let first = try await brain.answer("What is the capital of France?", context: "Now: Sunday 1 November 2026, 14:00") { _ in }
        let second = try await brain.answer("And of Germany?", context: "Now: Sunday 1 November 2026, 14:05") { _ in }
        print("[Live] session \(brain.sessionID ?? "-"): \(first.sentence) / \(second.sentence)")
        // The mock counts the earlier questions of the session in its answer.
        if ProcessInfo.processInfo.environment["HERMES_MOCK"] != nil {
            #expect(second.sentence.contains("1 earlier"))
        }
        #expect(!second.sentence.isEmpty)
    }
}

func liveHermesConfig() -> HermesConfig? {
    let environment = ProcessInfo.processInfo.environment
    return HermesConfig(address: environment["HERMES_URL"] ?? "", key: environment["HERMES_KEY"] ?? "")
}
