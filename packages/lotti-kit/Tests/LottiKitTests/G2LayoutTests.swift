import Foundation
import Testing
@testable import LottiKit

/// Golden bytes generated with even-g2-protocol's builders (`build_create_dashboard_page`,
/// `build_rebuild_page`, `build_text_upgrade`, `build_imu_control`) for the same inputs.
struct G2LayoutTests {
    // The old side rail: only the golden bytes still use its geometry (the encoding is the same).
    private let mainWithRail = G2TextBox.main("Hi", shape: .withRail)
    private let rail = G2TextBox.sideRail("> Yes\nNo")
    // What `GlassesFrame(main:rail:)` lays out: the choices under the sentence.
    private let mainAbove = G2TextBox.main("Hi", shape: .choicesBelow)
    private let choices = G2TextBox.choices("> Yes\nNo")

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

    @Test func choicesSitUnderTheSentence() {
        let frame = GlassesFrame(main: "Hi", rail: "> Yes")
        let main = frame.boxes[0], choices = frame.boxes[1]
        #expect(main.x == 0 && main.y == 0 && main.width == G2Layout.width && main.height == G2Layout.choicesY)
        #expect(choices.x == 0 && choices.y == G2Layout.choicesY && choices.width == G2Layout.width)
        #expect(choices.y + choices.height == G2Layout.height)
        #expect(GlassesFrame(main: "Hi").boxes[0].height == G2Layout.height)
    }

    @Test func extraBoxesKeepClearOfTheIndicatorIDs() {
        var planner = G2PagePlanner()
        let frame = GlassesFrame(boxes: [
            FrameBox("main", x: 0, y: 29, width: 576, height: 87, text: "Hi"),
            FrameBox("date", x: 0, y: 0, width: 504, height: 29, text: "Thu 5 Nov"),
            FrameBox("card1", x: 0, y: 120, width: 284, height: 100, text: "Pasta"),
            FrameBox("rail", x: 0, y: 230, width: 576, height: 58, text: "> Agenda"),
        ])
        guard case .create(let boxes, _) = planner.plan(frame).first else { Issue.record("no create"); return }
        #expect(boxes.map(\.id) == [G2TextBox.mainID, 10, 11, G2TextBox.railID, G2TextBox.inputID])
        #expect(!boxes.map(\.id).contains(G2ImageBox.attentionID) && !boxes.map(\.id).contains(G2ImageBox.locationID))
        // Only the blank input box takes the events: the firmware bounces the container that gets a scroll.
        #expect(boxes.map(\.capturesEvents) == [false, false, false, false, true])
        #expect(boxes.last?.text == "\n")
        var later = frame
        later.boxes[1].text = "Fri 6 Nov"
        #expect(planner.plan(later) == [.update(id: 10, name: "date", text: "Fri 6 Nov")])
        later.boxes[2].height = 70
        guard case .rebuild = planner.plan(later).first else { Issue.record("no rebuild"); return }
    }

    @Test func atMostEightTextBoxes() {
        var planner = G2PagePlanner()
        let frame = GlassesFrame(boxes: (1...10).map { FrameBox("b\($0)", x: 0, y: 0, width: 10, height: 10, text: "x") })
        guard case .create(let boxes, _) = planner.plan(frame).first else { Issue.record("no create"); return }
        #expect(boxes.count == G2Layout.maxTextBoxes)
    }

    // MARK: Planner

    @Test func firstFrameCreatesThePage() {
        var planner = G2PagePlanner()
        #expect(!planner.hasPage)
        let commands = planner.plan(GlassesFrame(main: "Hi", rail: "> Yes\nNo"))
        #expect(commands == [.create(G2TextBox.page([mainAbove, choices]))])
        #expect(planner.shape?.map(\.name) == ["main", "rail", "input"])
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
        #expect(planner.plan(GlassesFrame(main: "Hi")) == [.rebuild(G2TextBox.page([.main("Hi", shape: .fullWidth)]))])
        #expect(planner.plan(GlassesFrame(main: "Hi", rail: "> Yes\nNo")) == [.rebuild(G2TextBox.page([mainAbove, choices]))])
    }

    @Test func darkBlanksInPlace() {
        var planner = G2PagePlanner()
        _ = planner.plan(GlassesFrame(main: "Hi"))
        #expect(planner.plan(.dark) == [.update(id: 1, name: "main", text: "\n")])
        #expect(planner.plan(.dark) == [])
    }

    @Test func darkFirstFrameCreatesABlankPage() {
        var planner = G2PagePlanner()
        #expect(planner.plan(.dark) == [.create(G2TextBox.page([.main("\n", shape: .fullWidth)]))])
    }

    @Test func afterAFailureTheNextFrameRebuilds() {
        var planner = G2PagePlanner()
        _ = planner.plan(GlassesFrame(main: "Hi"))
        _ = planner.plan(GlassesFrame(main: "Ho"))
        planner.markUnknown()
        #expect(planner.hasPage)
        #expect(planner.plan(GlassesFrame(main: "Ho")) == [.rebuild(G2TextBox.page([.main("Ho", shape: .fullWidth)]))])
    }

    @Test func resetStartsOverWithACreate() {
        var planner = G2PagePlanner()
        _ = planner.plan(GlassesFrame(main: "Hi"))
        planner.reset()
        #expect(planner.plan(GlassesFrame(main: "Hi")) == [.create(G2TextBox.page([.main("Hi", shape: .fullWidth)]))])
    }

    @Test func markUnknownBeforeAnyPageStillCreates() {
        var planner = G2PagePlanner()
        planner.markUnknown()
        #expect(planner.plan(GlassesFrame(main: "Hi")) == [.create(G2TextBox.page([.main("Hi", shape: .fullWidth)]))])
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
    /// Thresholds for the synthetic samples below (forward axis = y).
    static let synthetic = HeadUpDetector.Config(axis: .y, upAngle: 20, downAngle: 10, upHold: 0.3, downHold: 0.5)

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
        let detector = HeadUpDetector(config: Self.synthetic)
        let (x, y, z) = sample(30)
        #expect(abs(detector.pitch(x: x, y: y, z: z)! - 30) < 0.01)
        var flipped = HeadUpDetector(config: .init(axis: .y, sign: -1))
        flipped.config.offset = 5
        #expect(abs(flipped.pitch(x: x, y: y, z: z)! - -25) < 0.01)
        #expect(HeadUpDetector(config: .init(axis: .z)).pitch(x: 0, y: 0, z: 1)! > 89)
    }

    @Test func ignoresWeakSamples() {
        var detector = HeadUpDetector(config: Self.synthetic)
        #expect(detector.pitch(x: 0, y: 0.1, z: 0) == nil)
        #expect(detector.feed(x: 0, y: 0.1, z: 0, at: 0) == nil)
    }

    @Test func headUpNeedsTheHold() {
        var detector = HeadUpDetector(config: Self.synthetic)
        #expect(run(&detector, [(30, 0), (30, 0.2)]) == [])
        #expect(run(&detector, [(30, 0.31)]) == [.headUp])
        #expect(detector.isUp)
    }

    @Test func aShortNodDoesNothing() {
        var detector = HeadUpDetector(config: Self.synthetic)
        #expect(run(&detector, [(30, 0), (30, 0.2), (0, 0.25), (30, 0.3), (30, 0.5)]) == [])
    }

    @Test func hysteresisKeepsItUpBetweenThresholds() {
        var detector = HeadUpDetector(config: Self.synthetic)
        _ = run(&detector, [(30, 0), (30, 0.4)])
        // 15° is below "up" but above "down": stays up.
        #expect(run(&detector, [(15, 1), (15, 3)]) == [])
        #expect(run(&detector, [(0, 4), (0, 4.4)]) == [])
        #expect(run(&detector, [(0, 4.5)]) == [.headDown])
        #expect(!detector.isUp)
    }

    @Test func resetForgetsTheState() {
        var detector = HeadUpDetector(config: Self.synthetic)
        _ = run(&detector, [(30, 0), (30, 0.4)])
        detector.reset()
        #expect(!detector.isUp)
        #expect(run(&detector, [(30, 10), (30, 10.4)]) == [.headUp])
    }

    /// Samples from a worn G2 (2026-11-01, about 1 per second): ahead, ceiling, ahead, floor.
    @Test func calibratedDefaultsOnRealSamples() {
        var detector = HeadUpDetector()
        let samples: [(Float, Float, Float)] = [
            (0.02, -0.08, 1.05), (-0.09, -0.04, 1.01), (0.88, -0.21, 0.54), (0.82, -0.18, 0.54),
            (0.41, -0.15, 0.87), (-0.98, 0.07, 0.22), (-0.96, 0.12, 0.27), (0.24, -0.10, 1.00),
        ]
        let events = samples.enumerated().compactMap { i, v in detector.feed(x: v.0, y: v.1, z: v.2, at: Double(i)) }
        #expect(events == [.headUp, .headDown])
        // Straight ahead with the glasses sitting a bit higher (x 0.45) stays down.
        #expect(detector.feed(x: 0.45, y: -0.2, z: 0.88, at: 20) == nil)
    }
}

struct HeadUpSettingTests {
    @Test func switchesTheNativeHeadUpScreenOff() {
        // even-g2-protocol tests/test_g2_device_settings.py: build_head_up(1, False)
        #expect(G2Payload.headUpSetting(magic: 1, enabled: false) == [0x08, 0x01, 0x10, 0x01, 0x1A, 0x04, 0x22, 0x02, 0x08, 0x00])
    }
}

struct HeadUpSettingsTests {
    @Test func anglesAreRelativeToStraightAhead() {
        let config = HeadUpSettings(straightAhead: 12, lookUp: 16).config
        #expect(config.upAngle == 28)
        #expect(config.downAngle == 20)
        #expect(config.axis == .x)
    }
}

/// Containers written out by hand, to check the planner and the bytes against (shared by the tests).
enum BoxShape { case fullWidth, withRail, choicesBelow }

extension G2TextBox {
    /// What the planner sends for these boxes: none takes the events, the blank input box does.
    static func page(_ boxes: [G2TextBox]) -> [G2TextBox] {
        boxes.map { var box = $0; box.capturesEvents = false; return box } + [input]
    }

    static func main(_ text: String, shape: BoxShape) -> G2TextBox {
        G2TextBox(id: mainID, name: "main", x: 0, y: 0, width: shape == .withRail ? 384 : G2Layout.width,
                  height: shape == .choicesBelow ? G2Layout.choicesY : G2Layout.height, capturesEvents: true, text: text)
    }

    /// The retired 176 px rail on the right.
    static func sideRail(_ text: String) -> G2TextBox {
        G2TextBox(id: railID, name: "rail", x: 400, y: 0, width: 176, height: G2Layout.height, capturesEvents: false, text: text)
    }

    static func choices(_ text: String) -> G2TextBox {
        G2TextBox(id: railID, name: "rail", x: 0, y: G2Layout.choicesY, width: G2Layout.width,
                  height: G2Layout.height - G2Layout.choicesY, capturesEvents: false, text: text)
    }
}
