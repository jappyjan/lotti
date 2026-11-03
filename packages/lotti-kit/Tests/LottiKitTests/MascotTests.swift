import Foundation
import Testing
@testable import LottiKit

/// A clock the tests move by hand.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1000
    var now: TimeInterval { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

/// Collects log lines.
final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var lines: [String] { lock.withLock { items } }
    func add(_ s: String) { lock.withLock { items.append(s) } }
}

struct MascotWearTests {
    @Test func unknownAndDisconnectedDefaultToOffWithoutAnimation() {
        var m = MascotWearMapper()
        #expect(m.update(wear: .unknown, connected: true, at: 0) == MascotPose(glassesOn: false, animated: false))
        var d = MascotWearMapper()
        #expect(d.update(wear: .worn, connected: false, at: 0) == MascotPose(glassesOn: false, animated: false))
    }

    @Test func firstResolvedStateIsNotAnimatedEvenWhenWorn() {
        var m = MascotWearMapper()
        #expect(m.update(wear: .worn, connected: true, at: 0) == MascotPose(glassesOn: true, animated: false))
    }

    @Test func changeShowsAfterDebounceAndAnimates() {
        var m = MascotWearMapper()
        m.update(wear: .unknown, connected: true, at: 0)
        #expect(m.update(wear: .worn, connected: true, at: 10).glassesOn == false)
        #expect(m.pendingDeadline == 11)
        #expect(m.update(wear: .worn, connected: true, at: 10.5).glassesOn == false)
        #expect(m.update(wear: .worn, connected: true, at: 11) == MascotPose(glassesOn: true, animated: true))
        #expect(m.pendingDeadline == nil)
    }

    @Test func flappingUnderADebounceIsIgnored() {
        var m = MascotWearMapper()
        m.update(wear: .worn, connected: true, at: 0)
        m.update(wear: .removed, connected: true, at: 5)
        // Back on within half a second: nothing ever shows.
        #expect(m.update(wear: .worn, connected: true, at: 5.5).glassesOn)
        #expect(m.pendingDeadline == nil)
        // A new removal starts a fresh timer.
        m.update(wear: .removed, connected: true, at: 6)
        #expect(m.update(wear: .removed, connected: true, at: 6.9).glassesOn)
        #expect(m.update(wear: .removed, connected: true, at: 7).glassesOn == false)
    }
}

struct MascotHeadTests {
    private func gravity(pitch: Double, roll: Double = 0) -> IMUSample {
        // x carries pitch; the rest of the unit vector splits into lateral (y) and vertical (z).
        let p = pitch * .pi / 180, r = roll * .pi / 180
        let flat = cos(p)
        return IMUSample(x: Float(sin(p)), y: Float(flat * sin(r)), z: Float(flat * cos(r)))
    }

    private func settled(_ m: inout HeadAngleMapper, _ s: IMUSample, straight: Double = 15, times: Int = 12) -> HeadAngles {
        var out = HeadAngles.neutral
        for i in 0..<times { out = m.feed(s, straightAhead: straight, at: Double(i)) ?? out }
        return out
    }

    @Test func neutralAtStraightAhead() {
        var m = HeadAngleMapper()
        #expect(settled(&m, gravity(pitch: 15)) == .neutral)
    }

    @Test func nodUpAndDown() {
        var m = HeadAngleMapper()
        let up = settled(&m, gravity(pitch: 30))
        #expect(abs(up.pitch - 13) < 0.5)
        var d = HeadAngleMapper()
        let down = settled(&d, gravity(pitch: 0))
        #expect(abs(down.pitch + 13) < 0.5)
    }

    @Test func tiltBothWays() {
        var m = HeadAngleMapper()
        let right = settled(&m, gravity(pitch: 15, roll: 10))
        #expect(abs(right.roll - 8) < 0.5)  // 10 degrees minus the 2 degree dead zone
        var l = HeadAngleMapper()
        #expect(abs(settled(&l, gravity(pitch: 15, roll: -10)).roll + 8) < 0.5)
    }

    @Test func deadZoneSwallowsSmallAngles() {
        var m = HeadAngleMapper()
        let a = settled(&m, gravity(pitch: 16.5, roll: 1.5))
        #expect(a.pitch == 0 && a.roll == 0)
    }

    @Test func clampsAtTheLimits() {
        var m = HeadAngleMapper()
        let a = settled(&m, gravity(pitch: 70, roll: 40))
        #expect(a.pitch == 20)
        #expect(a.roll == 15)
        var d = HeadAngleMapper()
        let b = settled(&d, gravity(pitch: -70, roll: -40))
        #expect(b.pitch == -20 && b.roll == -15)
    }

    @Test func yawIsAlwaysZero() {
        var m = HeadAngleMapper()
        #expect(settled(&m, gravity(pitch: 40, roll: 20)).yaw == 0)
    }

    @Test func noiseAtRestStaysExactlyNeutral() {
        var m = HeadAngleMapper()
        var rng = SystemRandomNumberGenerator()
        var worst = 0.0
        for i in 0..<500 {
            let jitter = { Double.random(in: -2...2, using: &rng) }  // +-2 degrees of noise
            let a = m.feed(gravity(pitch: 15 + jitter(), roll: jitter()), straightAhead: 15, at: Double(i))
            worst = max(worst, abs(a?.pitch ?? 0), abs(a?.roll ?? 0))
        }
        #expect(worst < 1.5)
    }

    @Test func rejectsBadSamplesAndKeepsTheTarget() {
        var m = HeadAngleMapper()
        let good = settled(&m, gravity(pitch: 30))
        for bad in [IMUSample(x: .nan, y: 0, z: 1), IMUSample(x: .infinity, y: 0, z: 0), IMUSample(x: 0, y: 0, z: 0),
                    IMUSample(x: 5, y: 5, z: 5), IMUSample(x: 0.01, y: 0, z: 0.01)] {
            #expect(m.feed(bad, straightAhead: 15, at: 99) == nil)
        }
        #expect(m.angles == good)
        #expect(m.feed(gravity(pitch: 30), straightAhead: .nan, at: 100) == nil)
    }

    @Test func rollHoldsWhenLookingStraightUp() {
        var m = HeadAngleMapper()
        _ = settled(&m, gravity(pitch: 15, roll: 10))
        let before = m.angles.roll
        m.feed(IMUSample(x: 1, y: 0.01, z: 0.01), straightAhead: 15, at: 50)
        #expect(m.angles.roll == before)
    }

    @Test func suggestedDurationFollowsTheSampleInterval() {
        var m = HeadAngleMapper()
        for i in 0..<20 { m.feed(gravity(pitch: 15), straightAhead: 15, at: Double(i)) }
        #expect(abs(m.suggestedDuration - 1) < 0.05)
        var fast = HeadAngleMapper()
        for i in 0..<40 { fast.feed(gravity(pitch: 15), straightAhead: 15, at: Double(i) * 0.25) }
        #expect(abs(fast.suggestedDuration - 0.25) < 0.05)
    }

    @Test func neutralFollowsTheCalibration() {
        var m = HeadAngleMapper()
        #expect(settled(&m, gravity(pitch: 25), straight: 25) == .neutral)
    }
}

@MainActor
private func makeConductor(_ link: FakeGlassesLink) -> Conductor {
    Conductor(link: link, brain: FakeBrain(), speech: FakeSpeech(),
              today: FixedToday(info: TodayInfo(now: Date(), events: [], weather: Weather(temperature: 12, condition: "cloudy"))))
}

@MainActor
struct IMUDemandTests {
    @Test func firstAcquireArmsLastReleaseDisarms() async {
        let link = FakeGlassesLink()
        let demand = IMUDemand(link: link)
        let a = await demand.acquire("headUp")
        let b = await demand.acquire("mascot")
        #expect(link.headTrackingCalls == [true])  // the second user adds no traffic
        await demand.release(a)
        #expect(link.headTracking)
        #expect(link.headTrackingCalls == [true])
        await demand.release(b)
        #expect(!link.headTracking)
        #expect(link.headTrackingCalls == [true, false])
        await demand.release(b)  // harmless
        #expect(link.headTrackingCalls == [true, false])
    }

    @Test func mascotFirstThenHeadUpKeepsTheFeedEitherWay() async {
        let link = FakeGlassesLink()
        let demand = IMUDemand(link: link)
        let mascot = await demand.acquire("mascot")
        let headUp = await demand.acquire("headUp")
        await demand.release(mascot)
        #expect(link.headTracking)
        await demand.release(headUp)
        #expect(link.headTrackingCalls == [true, false])
    }

    @Test func conductorHeadUpOffDoesNotCutTheMascot() async {
        let link = FakeGlassesLink()
        await link.connect(DiscoveredGlasses(id: "1", name: "G2"))
        let conductor = makeConductor(link)
        await conductor.glassesConnected()
        #expect(link.headTracking)  // head-up is on by default
        let mascot = await conductor.imuDemand.acquire("mascot")
        await conductor.setHeadTracking(false)
        #expect(link.headTracking)
        await conductor.setHeadTracking(true)
        await conductor.imuDemand.release(mascot)
        #expect(link.headTracking)
        await conductor.setHeadTracking(false)
        #expect(!link.headTracking)
    }

    @Test func headUpGesturesAreIgnoredWhenOnlyTheMascotNeedsTheFeed() async {
        let link = FakeGlassesLink()
        let conductor = makeConductor(link)
        await conductor.setHeadTracking(false)
        conductor.handle(InputEvent(.headUp, from: .imu))
        #expect(conductor.mode == .off)
        await conductor.setHeadTracking(true)
        conductor.handle(InputEvent(.headUp, from: .imu))
        #expect(conductor.mode != .off)
    }
}

@MainActor
struct MascotControllerTests {
    @MainActor private struct Rig {
        let link = FakeGlassesLink()
        let clock = FakeClock()
        let log = LogBox()
        let demand: IMUDemand
        let controller: MascotController
        init(timeout: TimeInterval = 5) {
            demand = IMUDemand(link: link)
            let clock = self.clock, log = self.log
            controller = MascotController(
                link: link, demand: demand, noSampleTimeout: timeout, clock: { clock.now },
                sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }, log: { log.add($0) })
        }
        func connectWorn() async {
            await link.connect(DiscoveredGlasses(id: "1", name: "G2"))
            link.sendWear(true)
        }
    }

    /// Lets observation callbacks and stream tasks run.
    private func settle(_ rig: Rig, until condition: () -> Bool) async {
        for _ in 0..<200 {
            await rig.controller.settled()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func unknownLinkMeansNeutralOffAndNoImuTraffic() async {
        let rig = Rig()
        rig.controller.start()
        #expect(!rig.controller.glassesOn && !rig.controller.animated)
        await rig.controller.settled()
        #expect(rig.link.headTrackingCalls.isEmpty)
    }

    @Test func wearingTurnsGlassesOnAfterTheDebounceAndStartsHeadSync() async {
        let rig = Rig()
        rig.controller.start()
        await rig.connectWorn()
        await settle(rig) { rig.controller.glassesOn == false && rig.controller.isStarted && rig.link.wearState == .worn }
        // Debounced: still off until the clock passes a second.
        rig.controller.tick()
        #expect(!rig.controller.glassesOn)
        rig.clock.advance(1.1)
        rig.controller.tick()
        #expect(rig.controller.glassesOn && rig.controller.animated)
        await settle(rig) { rig.link.headTracking }
        #expect(rig.link.headTrackingCalls == [true])
        rig.link.sendIMU(x: Float(sin(30.0 * .pi / 180)), y: 0, z: Float(cos(30.0 * .pi / 180)))
        await settle(rig) { rig.controller.headSyncActive }
        #expect(rig.controller.headSyncActive)
        #expect(abs(rig.controller.pitch - 13) < 0.5)
        #expect(rig.controller.yaw == 0)
    }

    private func wornController(_ rig: Rig) async {
        rig.controller.start()
        await rig.connectWorn()
        rig.controller.tick()  // sees "worn": the debounce starts
        rig.clock.advance(1.1)
        rig.controller.tick()
        await settle(rig) { rig.link.headTracking }
    }

    @Test func stopReleasesTheDemandAndResetsTheHead() async {
        let rig = Rig()
        await wornController(rig)
        rig.link.sendIMU(x: 0.8, y: 0, z: 0.6)
        await settle(rig) { rig.controller.headSyncActive }
        rig.controller.stop()
        await rig.controller.settled()
        #expect(!rig.link.headTracking)
        #expect(rig.link.headTrackingCalls == [true, false])
        #expect(rig.controller.pitch == 0 && rig.controller.roll == 0 && !rig.controller.headSyncActive)
    }

    @Test func disablingTheSwitchStopsLikeStop() async {
        let rig = Rig()
        await wornController(rig)
        rig.controller.enabled = false
        await rig.controller.settled()
        #expect(!rig.link.headTracking)
        rig.controller.enabled = true
        await settle(rig) { rig.controller.glassesOn }
        // Starting again is a fresh first appearance: no animation.
        #expect(!rig.controller.animated || rig.controller.glassesOn)
    }

    @Test func removingTheGlassesStopsHeadSyncButKeepsTheMascot() async {
        let rig = Rig()
        await wornController(rig)
        rig.link.sendWear(false)
        rig.controller.tick()
        rig.clock.advance(1.1)
        rig.controller.tick()
        await rig.controller.settled()
        #expect(!rig.controller.glassesOn)
        #expect(!rig.link.headTracking)
    }

    @Test func sharesTheFeedWithHeadUp() async {
        let rig = Rig()
        let headUp = await rig.demand.acquire("headUp")
        await wornController(rig)
        #expect(rig.link.headTrackingCalls == [true])  // mascot added nothing
        rig.controller.stop()
        await rig.controller.settled()
        #expect(rig.link.headTracking)  // head-up still has it
        await rig.demand.release(headUp)
        #expect(rig.link.headTrackingCalls == [true, false])
    }

    @Test func noImuDegradesToNeutralWithOneLogLine() async {
        let rig = Rig()
        await wornController(rig)
        rig.clock.advance(6)
        rig.controller.checkHealth()
        rig.controller.checkHealth()
        #expect(!rig.controller.headSyncActive)
        #expect(rig.controller.pitch == 0 && rig.controller.roll == 0)
        #expect(rig.log.lines.count == 1)
        // The wear pose still works.
        #expect(rig.controller.glassesOn)
        rig.link.sendWear(false)
        rig.controller.tick()
        rig.clock.advance(1.1)
        rig.controller.tick()
        #expect(!rig.controller.glassesOn)
    }

    @Test func samplesAfterADegradeRecoverTheHead() async {
        let rig = Rig()
        await wornController(rig)
        rig.clock.advance(6)
        rig.controller.checkHealth()
        rig.link.sendIMU(x: 0.5, y: 0, z: 0.87)
        await settle(rig) { rig.controller.headSyncActive }
        #expect(rig.controller.headSyncActive)
    }
}
