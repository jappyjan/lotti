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

    @Test func disabledHostNeverRuns() async {
        let link = FakeGlassesLink()
        let host = MascotHost(link: link, demand: IMUDemand(link: link))
        host.setEnabled(false)
        host.acquire()
        // Glasses connected and on your face: a running mascot would put its glasses on and ask for the IMU.
        await link.connect(DiscoveredGlasses(id: "1", name: "G2"))
        link.sendWear(true)
        host.controller.tick()
        await host.controller.settled()
        #expect(link.headTrackingCalls.isEmpty)
        #expect(!host.controller.glassesOn)
        #expect(host.controller.pitch == 0)
        // The same with the switch on does both, so the checks above can fail.
        host.setEnabled(true)
        await host.controller.settled()
        #expect(host.controller.glassesOn)
        #expect(link.headTrackingCalls == [true])
    }

    @Test func reduceMotionKeepsTheImuOff() async {
        let link = FakeGlassesLink()
        let host = MascotHost(link: link, demand: IMUDemand(link: link))
        host.setHeadSyncAllowed(false)
        await link.connect(DiscoveredGlasses(id: "1", name: "G2"))
        link.sendWear(true)
        host.acquire()
        await host.controller.settled()
        #expect(host.controller.glassesOn)
        #expect(link.headTrackingCalls.isEmpty)
    }
}
