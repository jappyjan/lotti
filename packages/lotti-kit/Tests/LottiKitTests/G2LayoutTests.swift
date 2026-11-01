import Foundation
import Testing
@testable import LottiKit

/// Golden bytes generated with even-g2-protocol's builders (`build_create_dashboard_page`,
/// `build_rebuild_page`, `build_text_upgrade`, `build_imu_control`) for the same inputs.
struct G2LayoutTests {
    private let mainWithRail = G2TextBox.main("Hi", shape: .withRail)
    private let rail = G2TextBox.rail("> Yes\nNo")

    @Test func createPageWithRail() {
        let payload = G2Payload.createPage(magic: 110, boxes: [mainWithRail, rail])
        #expect(hex(payload) == "0800106e1a3e08021a180800100018800320a002480152046d61696e5801620248691a1d089003100018b00120a002480252047261696c62083e205965730a4e6f28904e")
    }

    @Test func createPageFullWidth() {
        let payload = G2Payload.createPage(magic: 111, boxes: [.main("Hi", shape: .fullWidth)])
        #expect(hex(payload) == "0800106f1a1f08011a180800100018c00420a002480152046d61696e58016202486928904e")
    }

    @Test func rebuildPage() {
        #expect(hex(G2Payload.rebuildPage(magic: 112, boxes: [mainWithRail, rail]))
            == "080710703a3b08021a180800100018800320a002480152046d61696e5801620248691a1d089003100018b00120a002480252047261696c62083e205965730a4e6f")
        #expect(hex(G2Payload.rebuildPage(magic: 113, boxes: [.main("Hi", shape: .fullWidth)]))
            == "080710713a1c08011a180800100018c00420a002480152046d61696e580162024869")
    }

    @Test func textUpdateForTheRail() {
        let payload = G2Payload.textUpdate(magic: 114, containerID: 2, containerName: "rail", text: "No\n> Yes")
        #expect(hex(payload) == "080510724a16080212047261696c180020082a084e6f0a3e20596573")
    }

    @Test func rebuildAckResult() {
        // {1: 8, 2: magic, 8: {1: result}}
        #expect(G2Payload.rebuildResult(bytes("0808107042020806")) == 6)
        #expect(G2Payload.rebuildResult(bytes("0808107042020807")) == 7)
        #expect(G2Payload.rebuildResult(bytes("080610701a00")) == nil)
    }

    @Test func imuControl() {
        #expect(hex(G2Payload.imuControl(magic: 115, enable: true, pace: 500, field: 22)) == "08131073b20105080110f403")
        #expect(hex(G2Payload.imuControl(magic: 116, enable: false, field: 22)) == "08131074b201020800")
        // MentraOS's field 20: same body, tag a2 01.
        #expect(hex(G2Payload.imuControl(magic: 115, enable: true, pace: 500)) == "08131073a20105080110f403")
    }

    @Test func columnsFitTheDisplay() {
        #expect(G2Layout.mainWidthWithRail < G2Layout.railX)
        #expect(G2Layout.railX + G2Layout.railWidth == G2Layout.width)
        #expect("main".utf8.count <= 14 && "rail".utf8.count <= 14)
    }

    // MARK: Planner

    @Test func firstFrameCreatesThePage() {
        var planner = G2PagePlanner()
        #expect(!planner.hasPage)
        let commands = planner.plan(GlassesFrame(main: "Hi", rail: "> Yes\nNo"))
        #expect(commands == [.create([mainWithRail, rail])])
        #expect(planner.shape == .withRail)
    }

    @Test func sameShapeOnlyUpdatesWhatChanged() {
        var planner = G2PagePlanner()
        _ = planner.plan(GlassesFrame(main: "Hi", rail: "> Yes\nNo"))
        #expect(planner.plan(GlassesFrame(main: "Hi", rail: "Yes\n> No")) == [.update(id: 2, name: "rail", text: "Yes\n> No")])
        #expect(planner.plan(GlassesFrame(main: "Hi", rail: "Yes\n> No")) == [])
        #expect(planner.plan(GlassesFrame(main: "Bye", rail: "A")) == [
            .update(id: 1, name: "main", text: "Bye"), .update(id: 2, name: "rail", text: "A"),
        ])
    }

    @Test func shapeChangeRebuilds() {
        var planner = G2PagePlanner()
        _ = planner.plan(GlassesFrame(main: "Hi", rail: "> Yes\nNo"))
        #expect(planner.plan(GlassesFrame(main: "Hi")) == [.rebuild([.main("Hi", shape: .fullWidth)])])
        #expect(planner.plan(GlassesFrame(main: "Hi", rail: "> Yes\nNo")) == [.rebuild([mainWithRail, rail])])
    }

    @Test func darkBlanksInPlace() {
        var planner = G2PagePlanner()
        _ = planner.plan(GlassesFrame(main: "Hi"))
        #expect(planner.plan(.dark) == [.update(id: 1, name: "main", text: "\n")])
        #expect(planner.plan(.dark) == [])
    }

    @Test func darkFirstFrameCreatesABlankPage() {
        var planner = G2PagePlanner()
        #expect(planner.plan(.dark) == [.create([.main("\n", shape: .fullWidth)])])
    }

    @Test func afterAFailureTheNextFrameRebuilds() {
        var planner = G2PagePlanner()
        _ = planner.plan(GlassesFrame(main: "Hi"))
        _ = planner.plan(GlassesFrame(main: "Ho"))
        planner.markUnknown()
        #expect(planner.hasPage)
        #expect(planner.plan(GlassesFrame(main: "Ho")) == [.rebuild([.main("Ho", shape: .fullWidth)])])
    }

    @Test func resetStartsOverWithACreate() {
        var planner = G2PagePlanner()
        _ = planner.plan(GlassesFrame(main: "Hi"))
        planner.reset()
        #expect(planner.plan(GlassesFrame(main: "Hi")) == [.create([.main("Hi", shape: .fullWidth)])])
    }

    @Test func markUnknownBeforeAnyPageStillCreates() {
        var planner = G2PagePlanner()
        planner.markUnknown()
        #expect(planner.plan(GlassesFrame(main: "Hi")) == [.create([.main("Hi", shape: .fullWidth)])])
    }
}

struct G2ImuTests {
    @Test func decodesIMUReports() {
        // even-g2-protocol test_g2_widgets.py: Sys event type 8 with three float32 fields.
        let message = G2Message(sid: 0xE0, flag: 0x01, seq: 0,
                                payload: bytes("080210016a151a1308081a0f0d0000803f15000000bf1d0000803e"))
        #expect(G2Events.decode(message) == .imu(x: 1, y: -0.5, z: 0.25))
    }
}

struct HeadUpDetectorTests {
    /// A gravity sample for a head pitched `degrees` up, with the forward axis = y.
    private func sample(_ degrees: Double) -> (Float, Float, Float) {
        let r = degrees * .pi / 180
        return (0, Float(sin(r)), Float(-cos(r)))
    }

    private func run(_ detector: inout HeadUpDetector, _ steps: [(Double, TimeInterval)]) -> [InputEvent.Gesture] {
        steps.compactMap { degrees, time in
            let (x, y, z) = sample(degrees)
            return detector.feed(x: x, y: y, z: z, at: time)
        }
    }

    @Test func pitchFollowsTheConfiguredAxis() {
        let detector = HeadUpDetector()
        let (x, y, z) = sample(30)
        #expect(abs(detector.pitch(x: x, y: y, z: z)! - 30) < 0.01)
        var flipped = HeadUpDetector(config: .init(sign: -1))
        flipped.config.offset = 5
        #expect(abs(flipped.pitch(x: x, y: y, z: z)! - -25) < 0.01)
        #expect(HeadUpDetector(config: .init(axis: .z)).pitch(x: 0, y: 0, z: 1)! > 89)
    }

    @Test func ignoresWeakSamples() {
        var detector = HeadUpDetector()
        #expect(detector.pitch(x: 0, y: 0.1, z: 0) == nil)
        #expect(detector.feed(x: 0, y: 0.1, z: 0, at: 0) == nil)
    }

    @Test func headUpNeedsTheHold() {
        var detector = HeadUpDetector()
        #expect(run(&detector, [(30, 0), (30, 0.2)]) == [])
        #expect(run(&detector, [(30, 0.31)]) == [.headUp])
        #expect(detector.isUp)
    }

    @Test func aShortNodDoesNothing() {
        var detector = HeadUpDetector()
        #expect(run(&detector, [(30, 0), (30, 0.2), (0, 0.25), (30, 0.3), (30, 0.5)]) == [])
    }

    @Test func hysteresisKeepsItUpBetweenThresholds() {
        var detector = HeadUpDetector()
        _ = run(&detector, [(30, 0), (30, 0.4)])
        // 15° is below "up" but above "down": stays up.
        #expect(run(&detector, [(15, 1), (15, 3)]) == [])
        #expect(run(&detector, [(0, 4), (0, 4.4)]) == [])
        #expect(run(&detector, [(0, 4.5)]) == [.headDown])
        #expect(!detector.isUp)
    }

    @Test func resetForgetsTheState() {
        var detector = HeadUpDetector()
        _ = run(&detector, [(30, 0), (30, 0.4)])
        detector.reset()
        #expect(!detector.isUp)
        #expect(run(&detector, [(30, 10), (30, 10.4)]) == [.headUp])
    }
}
