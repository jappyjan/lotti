import LottiKit
import Observation
import Testing
@testable import Lotti

@MainActor
struct AppModelTests {
    @Test func launchReconnectsToLastGlasses() async {
        let link = FakeLink(last: DiscoveredGlasses(id: "32", name: "Even G2 · 32", leftArm: .init(), rightArm: .init()))
        await AppModel(link: link).launch()
        #expect(link.connected == ["32"])
        #expect(!link.scanned)
    }

    @Test func launchScansWhenNothingIsRemembered() async {
        let link = FakeLink(last: nil)
        await AppModel(link: link).launch()
        #expect(link.scanned)
        #expect(link.connected.isEmpty)
    }

    @Test func sendHelloShowsHelloFromLotti() async {
        let link = FakeLink(last: nil)
        let model = AppModel(link: link)
        await model.sendHello()
        #expect(link.shown == ["Hello from Lotti"])
        #expect(model.lastError == nil)
    }

    @Test func sendHelloReportsErrors() async {
        let link = FakeLink(last: nil)
        link.showError = GlassesLinkError.notConnected
        let model = AppModel(link: link)
        await model.sendHello()
        #expect(model.lastError == GlassesLinkError.notConnected.localizedDescription)
    }
}

@MainActor
@Observable
private final class FakeLink: GlassesLink {
    var status: GlassesStatus = .disconnected
    var discovered: [DiscoveredGlasses] = []
    var lastGlasses: DiscoveredGlasses?
    var scanned = false
    var connected: [String] = []
    var shown: [String] = []
    var showError: Error?

    init(last: DiscoveredGlasses?) { lastGlasses = last }

    func startScan() { scanned = true }
    func stopScan() {}
    func connect(_ glasses: DiscoveredGlasses) async { connected.append(glasses.id) }
    func disconnect() {}
    func showText(_ text: String) async throws {
        if let showError { throw showError }
        shown.append(text)
    }
}
