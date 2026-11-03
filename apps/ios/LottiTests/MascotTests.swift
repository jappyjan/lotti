import Foundation
import LottiKit
import Testing
@testable import Lotti

@MainActor
struct MascotTests {
    @Test func switchDefaultsToOn() {
        let defaults = UserDefaults.testing()
        #expect(MascotSetting.isEnabled(defaults))
        defaults.set(false, forKey: MascotSetting.key)
        #expect(!MascotSetting.isEnabled(defaults))
    }

    @Test func hostStartsOnFirstHolderAndStopsOnLast() {
        let link = FakeGlassesLink()
        let host = MascotHost(link: link, demand: IMUDemand(link: link))
        host.acquire()
        host.acquire()
        #expect(host.controller.isStarted)
        host.release()
        #expect(host.controller.isStarted)
        host.release()
        #expect(!host.controller.isStarted)
        host.release()  // unbalanced release is harmless
        #expect(host.holderCount == 0)
    }

    @Test func disabledHostNeverRuns() {
        let link = FakeGlassesLink()
        let host = MascotHost(link: link, demand: IMUDemand(link: link))
        host.setEnabled(false)
        host.acquire()
        #expect(!host.controller.glassesOn)
        #expect(host.controller.pitch == 0)
    }
}
