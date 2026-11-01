#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Testing
@testable import LottiKit

/// Runs Apple's on-device model with fake phone tools. Slow, so only with LOTTI_LIVE_MODEL=1
/// (and Apple Intelligence on):  LOTTI_LIVE_MODEL=1 swift test --filter LiveModel
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOTTI_LIVE_MODEL"] == "1"), .serialized)
struct LiveModelTests {
    let calendar = FakeTool("calendar", parameters: [
        ToolParameter("from", .string, "first day, YYYY-MM-DD or \"tomorrow\"; default today", optional: true),
        ToolParameter("days", .integer, "how many days, 1 to 14; default 1", optional: true),
    ], result: "Mon 2 Nov: 09:30–09:45 Standup; 11:00–12:00 Ben (Café)")
    let timer = FakeTool.timer()
    let context = "Now: Sunday 1 November 2026, 14:00\nCalendar today: nothing left\nWeather now: 9°C, cloudy"

    /// Asks a fresh on-device brain that has the fake tools.
    func ask(_ question: String) async throws -> Answer {
        guard #available(macOS 26.0, iOS 26.0, *) else { throw ToolError("needs macOS 26") }
        let brain = AppleBrain(tools: Toolbox([calendar, timer]))
        if let reason = brain.unavailableReason { throw ToolError(reason) }
        return try await brain.answer(question, context: context)
    }

    @Test func preparesATimerWithoutRunningIt() async throws {
        let answer = try await ask("Set a timer for 10 minutes for the pasta")
        print("[Live] \(answer)")
        #expect(answer.actions.first?.tool == "set_timer")
        #expect(answer.actions.first?.arguments.int("minutes") == 10)
        #expect(timer.runs.isEmpty)
    }

    @Test func readsTomorrowsCalendar() async throws {
        let answer = try await ask("What's on tomorrow?")
        print("[Live] \(answer)")
        #expect(!calendar.runs.isEmpty)
        #expect(answer.sentence.contains("9:30") || answer.sentence.contains("Standup") || answer.sentence.contains("Ben"))
    }

    @Test func handsTheWebToHermes() async throws {
        let answer = try await ask("What's the latest news about the Bundestag?")
        print("[Live] \(answer)")
        #expect(answer.handoff != nil)
    }

    @Test func smallTalkStaysLocal() async throws {
        let answer = try await ask("How are you?")
        print("[Live] \(answer)")
        #expect(answer.handoff == nil)
        #expect(answer.actions.isEmpty)
    }
}
#endif
