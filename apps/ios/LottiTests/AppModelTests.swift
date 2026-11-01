import Foundation
import LottiKit
import Testing
@testable import Lotti

@MainActor
struct AppModelTests {
    func model(_ link: FakeGlassesLink) -> AppModel {
        AppModel(link: link, conductor: Conductor(link: link, brain: SilentBrain(), speech: SilentSpeech(), today: NoToday()))
    }

    let glasses = DiscoveredGlasses(id: "32", name: "Even G2 · 32", leftArm: .init(), rightArm: .init())

    @Test func launchReconnectsToLastGlasses() async {
        let link = FakeGlassesLink(last: glasses)
        await model(link).launch()
        #expect(link.connected == ["32"])
        #expect(!link.scanned)
    }

    @Test func launchScansWhenNothingIsRemembered() async {
        let link = FakeGlassesLink()
        await model(link).launch()
        #expect(link.scanned)
        #expect(link.connected.isEmpty)
    }

    @Test func reconnectsAfterADrop() async throws {
        let link = FakeGlassesLink(last: glasses)
        let model = model(link)
        let keeper = Task { await model.keepConnected(pollEvery: .milliseconds(10)) }
        defer { keeper.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(link.status.isConnected)
        #expect(link.headTracking)
        link.disconnect()
        try await Task.sleep(for: .milliseconds(100))
        #expect(link.status.isConnected)
        #expect(model.reconnects == 2)
    }

    @Test func staysDisconnectedWhenAsked() async throws {
        let link = FakeGlassesLink(last: glasses)
        let model = model(link)
        await model.connect(glasses)
        model.disconnect()
        let keeper = Task { await model.keepConnected(pollEvery: .milliseconds(10)) }
        defer { keeper.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!link.status.isConnected)
    }
}

@MainActor private final class SilentBrain: Brain {
    func prewarm() {}
    func answer(_ message: String, context: String, status: @escaping @MainActor (String) -> Void) async throws -> Answer {
        Answer(sentence: "")
    }
    func endConversation() {}
}

@MainActor private final class SilentSpeech: SpeechRecognizer {
    func prepare() async {}
    func transcribe(_ audio: AsyncStream<[Int16]>) -> AsyncThrowingStream<Transcript, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct NoToday: TodayProvider {
    func today(at now: Date) async -> TodayInfo { TodayInfo(now: now) }
}
