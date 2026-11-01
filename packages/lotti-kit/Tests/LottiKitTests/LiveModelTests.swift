#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Testing
@testable import LottiKit

/// Runs the on-device brain (Apple's model) with fake phone tools on a small set of German and
/// English questions. Slow, so only with LOTTI_LIVE_MODEL=1 and Apple Intelligence on:
///
///     LOTTI_LIVE_MODEL=1 swift test --filter LiveModel
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOTTI_LIVE_MODEL"] == "1"), .serialized)
struct LiveModelTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var question: String
        /// Read tools that must be called.
        var reads: Set<String> = []
        /// Action that must be prepared.
        var action: String?
        var handoff = false
        /// One of these must be in the answer (case-insensitive).
        var mentions: [String] = []
        /// None of these may be in the answer.
        var never: [String] = []
        var testDescription: String { question }
    }

    nonisolated static let cases: [Case] = [
        Case(question: "Wo bin ich?", reads: ["location"], mentions: ["Hamburg", "Altona", "Elbstraße"],
             never: ["Berlin", "ich bin"]),
        Case(question: "Where am I right now?", reads: ["location"], mentions: ["Hamburg", "Altona"], never: ["Berlin"]),
        Case(question: "What's on tomorrow?", reads: ["calendar"], mentions: ["Standup", "9:30", "Ben"]),
        Case(question: "Was steht morgen an?", reads: ["calendar"], mentions: ["Standup", "9:30", "Ben"]),
        Case(question: "Brauche ich heute einen Schirm?", reads: ["weather"], mentions: ["Regen", "regnet", "Schirm", "15"]),
        Case(question: "Set a timer for 10 minutes for the pasta", action: "set_timer", never: ["is set", "started"]),
        Case(question: "Erinner mich morgen um 9 an die Wäsche", action: "create_reminder"),
        Case(question: "What's the latest news about the Bundestag?", handoff: true),
        Case(question: "Hermes, find me a cheap flight to Lisbon", handoff: true),
        Case(question: "How are you?", never: ["Hallo", "Berlin"]),
        Case(question: "Wie spät ist es?", mentions: ["14"]),
    ]

    let now = "Now: Sunday 1 November 2026, 14:05"

    func tools() -> (Toolbox, [String: FakeTool]) {
        let fakes: [FakeTool] = [
            FakeTool("location", result: "Große Elbstraße 39, 22767 Hamburg-Altona, Germany"),
            FakeTool("calendar", parameters: [
                ToolParameter("from", .string, "first day: today, tomorrow, a weekday like monday, or YYYY-MM-DD", optional: true),
                ToolParameter("days", .integer, "how many days, 1 to 14; default 1", optional: true),
            ], result: "Mon 2 Nov: 09:30–09:45 Standup; 11:00–12:00 Ben (Café)"),
            FakeTool("weather", result: "Now: 9°C, cloudy\nToday: 6 to 11°C\nRain today: yes, from 15:00\nTomorrow: clear, 3 to 8°C"),
            FakeTool("reminders", result: "Buy milk\nCall Mara (due Mon 2 Nov 18:00)"),
            FakeTool.timer(),
            FakeTool("create_reminder", .action, parameters: [
                ToolParameter("text", .string, "what to remember, short"),
                ToolParameter("due", .string, "when: a day and time like \"tomorrow 09:00\" or \"monday 18:30\"", optional: true),
            ]),
        ]
        return (Toolbox(fakes), Dictionary(uniqueKeysWithValues: fakes.map { ($0.spec.name, $0) }))
    }

    @Test(arguments: cases)
    func answers(_ test: Case) async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let (toolbox, fakes) = tools()
        let brain = AppleBrain(tools: toolbox)
        if let reason = brain.unavailableReason { Issue.record(Comment(rawValue: reason)); return }
        let answer = try await brain.answer(test.question, context: now) { _ in }
        print("[Live] \(test.question)\n" + brain.trace.map { "    " + $0 }.joined(separator: "\n"))

        let called = Set(fakes.filter { !$0.value.runs.isEmpty }.map(\.key))
        #expect(called.isSuperset(of: test.reads), "called \(called)")
        #expect(fakes.values.filter { $0.spec.effect == .action }.allSatisfy { $0.runs.isEmpty }, "an action ran")
        if let action = test.action { #expect(answer.actions.map(\.tool).contains(action), "actions \(answer.actions)") }
        #expect((answer.handoff != nil) == test.handoff, "handoff \(answer.handoff ?? "-")")
        let text = answer.sentence.lowercased()
        if !test.mentions.isEmpty {
            #expect(test.mentions.contains { text.contains($0.lowercased()) }, "\(answer.sentence)")
        }
        for word in test.never { #expect(!text.contains(word.lowercased()), "\(answer.sentence)") }
    }

    @Test func followUpKeepsTheTopic() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let (toolbox, fakes) = tools()
        let brain = AppleBrain(tools: toolbox)
        _ = try await brain.answer("Was steht morgen an?", context: now) { _ in }
        let answer = try await brain.answer("Und wo ist das Treffen mit Ben?", context: now) { _ in }
        print("[Live] follow-up\n" + brain.trace.map { "    " + $0 }.joined(separator: "\n"))
        #expect(answer.sentence.contains("Café"), "\(answer.sentence)")
        #expect(!answer.sentence.contains("Elbstraße"), "\(answer.sentence)")
        _ = fakes
    }
}
#endif
