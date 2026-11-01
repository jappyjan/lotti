import LottiKit
import Observation
import Testing
@testable import Lotti

@MainActor
struct AppModelTests {
    @Test func launchReconnectsToLastGlasses() async {
        let link = FakeGlassesLink(last: DiscoveredGlasses(id: "32", name: "Even G2 · 32", leftArm: .init(), rightArm: .init()))
        await AppModel(link: link).launch()
        #expect(link.connected == ["32"])
        #expect(!link.scanned)
    }

    @Test func launchScansWhenNothingIsRemembered() async {
        let link = FakeGlassesLink(last: nil)
        await AppModel(link: link).launch()
        #expect(link.scanned)
        #expect(link.connected.isEmpty)
    }

    @Test func sendHelloShowsHelloFromLotti() async {
        let link = FakeGlassesLink(last: nil)
        let model = AppModel(link: link)
        await model.sendHello()
        #expect(link.shownTexts == ["Hello from Lotti"])
        #expect(model.lastError == nil)
    }

    @Test func sendHelloReportsErrors() async {
        let link = FakeGlassesLink(last: nil)
        link.showError = GlassesLinkError.notConnected
        let model = AppModel(link: link)
        await model.sendHello()
        #expect(model.lastError == GlassesLinkError.notConnected.localizedDescription)
    }
}
