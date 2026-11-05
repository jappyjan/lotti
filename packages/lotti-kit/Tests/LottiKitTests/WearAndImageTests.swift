import Foundation
import Testing
@testable import LottiKit

/// Wear detection. The glasses never report wearing on their own (marked on/off capture,
/// 2026-11-05): they only answer the onboarding question on sid 0x10.
struct WearDetectionTests {
    private func decode(_ payload: String, sid: UInt8 = G2Service.onboarding) -> G2Event? {
        G2Events.decode(G2Message(sid: sid, flag: 0x00, seq: 1, payload: bytes(payload)))
    }

    @Test func theQueryMatchesTheEvenAppsCapture() {
        // even-g2-protocol CAP_WEAR: aa 21 41 0a 01 01 10 20 08 03 10 41 2a 02 08 01 d6 fe
        let frames = G2Frame.encode(payload: G2Payload.wearStatusQuery(magic: 0x41), sid: G2Service.onboarding,
                                    flag: G2Flag.request, seq: 0x41)
        #expect(frames.map(hex) == ["aa21410a0101102008031041" + "2a020801" + "d6fe"])
    }

    @Test func theCapturedAnswerIsWorn() {
        // Lotti's log, 2026-11-05 11:35:24: aa12910c010110000803100b2a0408011001006b
        var assembler = G2FrameAssembler()
        let message = assembler.feed(bytes("aa12910c010110000803100b2a0408011001006b"))
        #expect(message?.sid == G2Service.onboarding)
        #expect(message?.magic == 0x0B)
        #expect(message.flatMap(G2Events.decode) == .wear(true))
    }

    @Test func notWornLeavesTheZeroOut() {
        // Lotti's log, 2026-11-05 22:59:07, glasses taken off: {1: 3, 2: 133, 5: {1: 1}}, field 2 = 0
        // left out on the wire.
        #expect(decode("08031085012a020801") == .wear(false))
        #expect(decode("0803100b2a0408011000") == .wear(false))
    }

    @Test func otherOnboardingMessagesAreNotWear() {
        #expect(decode("0801100a1a020804") == nil)  // onboarding FINISH echo
        #expect(decode("0803100b2a00") == nil)  // event without a type
        #expect(decode("0803100b2a0408021001") == nil)  // another event type
    }

    @Test func stateMessagesAreNeverWear() {
        // sid 0x0D: EvenHub active and dashboard toggled (both captured), and the old guess.
        #expect(decode("08011a0308e001", sid: G2Events.stateService) == .info("state change 08011a0308e001"))
        #expect(decode("08011a00", sid: G2Events.stateService) == .info("state change 08011a00"))
        #expect(decode("08021001", sid: G2Events.stateService) == .info("state change 08021001"))
    }

    @Test func otherSidsAreNotWear() {
        #expect(decode("0803100b2a0408011001", sid: G2Service.evenHub) == nil)
    }

    @MainActor
    @Test func theFakeLinkReportsWearStateAndInputs() async {
        let link = FakeGlassesLink()
        #expect(link.wearState == .unknown)
        var inputs = link.inputs().makeAsyncIterator()
        link.sendWear(true)
        #expect(link.wearState == .worn)
        #expect(await inputs.next() == InputEvent(.worn, from: .glasses))
        link.sendWear(false)
        #expect(link.wearState == .removed)
        #expect(await inputs.next() == InputEvent(.removed, from: .glasses))
        await link.checkWear()
        #expect(link.wearChecks == 1)
    }
}

struct ImageContainerTests {
    static func box(id: Int = 3, name: String = "attention", x: Int = 500, y: Int = 4, bytes: [UInt8] = [1, 2, 3, 4, 5]) -> G2ImageBox {
        G2ImageBox(id: id, name: name, x: x, y: y, width: 24, height: 24, data: bytes, compression: .lz4)
    }

    @Test func createPageCarriesImageContainersInField4() {
        let payload = G2Payload.createPage(magic: 110, boxes: [.main("Hi", shape: .fullWidth)], images: [Self.box()])
        // {1: 0, 2: 110, 3: {1: 2 containers, 3: text, 4: {1 x, 2 y, 3 w, 4 h, 5 id, 6 name}, 5: 10000}}
        let page = ProtoReader.message(payload, 3)
        #expect(page.flatMap { ProtoReader.varintFields($0)[1] } == 2)
        let image = page.flatMap { ProtoReader.message($0, 4) }
        let fields = image.map(ProtoReader.varintFields)
        #expect(fields?[1] == 500 && fields?[2] == 4 && fields?[3] == 24 && fields?[4] == 24 && fields?[5] == 3)
        #expect(image.flatMap { ProtoReader.string($0, 6) } == "attention")
    }

    @Test func withoutImagesTheBytesAreUnchanged() {
        // Same golden bytes as G2LayoutTests.createPageFullWidth.
        #expect(hex(G2Payload.createPage(magic: 111, boxes: [.main("Hi", shape: .fullWidth)]))
            == "0800106f1a1f08011a180800100018c00420a002480152046d61696e58016202486928904e")
        #expect(G2Payload.rebuildPage(magic: 5, boxes: [], images: []) == G2Payload.rebuildPage(magic: 5, boxes: []))
    }

    @Test func rebuildAlsoCarriesImages() {
        let payload = G2Payload.rebuildPage(magic: 112, boxes: [.main("Hi", shape: .fullWidth)], images: [Self.box(id: 4, name: "location")])
        let page = ProtoReader.message(payload, 7)
        #expect(page.flatMap { ProtoReader.varintFields($0)[1] } == 2)
        #expect(page.flatMap { ProtoReader.message($0, 4) }.flatMap { ProtoReader.string($0, 6) } == "location")
    }

    @Test func uploadIsOneFragmentForSmallImages() throws {
        let image = Self.box(bytes: (0..<100).map { UInt8($0) })
        var counter: UInt64 = 200
        let messages = G2Payload.imageUpdates(image: image, sessionID: 7, magic: { counter += 1; return counter })
        #expect(messages.count == 1)
        let message = messages[0]
        #expect(ProtoReader.varintFields(message)[1] == 3)  // Cmd 3
        #expect(ProtoReader.varintFields(message)[2] == 201)
        let body = try #require(ProtoReader.message(message, 5))
        let f = ProtoReader.varintFields(body)
        #expect(f[1] == 3 && f[3] == 7 && f[4] == 100 && f[5] == 2 && f[7] == 100)  // id, session, total, LZ4, fragment size
        #expect(f[6] == 0)  // fragment index 0
        #expect(ProtoReader.string(body, 2) == "attention")
        #expect(ProtoReader.message(body, 8) == (0..<100).map { UInt8($0) })
    }

    @Test func bigImagesFragmentInOrder() throws {
        let data = (0..<10_000).map { UInt8($0 % 251) }
        let image = Self.box(bytes: data)
        var counter: UInt64 = 0
        let messages = G2Payload.imageUpdates(image: image, sessionID: 1, magic: { counter += 1; return counter }, fragmentSize: 4096)
        #expect(messages.count == 3)
        var joined: [UInt8] = []
        for (index, message) in messages.enumerated() {
            let body = try #require(ProtoReader.message(message, 5))
            #expect((ProtoReader.varintFields(body)[6] ?? 0) == UInt64(index))
            #expect(ProtoReader.varintFields(body)[4] == 10_000)
            joined += ProtoReader.message(body, 8) ?? []
        }
        #expect(joined == data)
        #expect(Set(messages.map { ProtoReader.varintFields($0)[2] }).count == 3)  // one magic each
    }

    @Test func aBitmapEncodesAsFullBrightGray() throws {
        let bitmap = BuiltInIndicatorIcons().icon(.mail)!
        let box = try #require(G2ImageBox(id: 3, name: "attention", x: 1, y: 2, bitmap: bitmap))
        let expected = try #require(NavMapBmp.encode(bitmap))
        #expect(box.data == expected.data && box.compression == expected.mode)
        #expect(box.width == 24 && box.height == 24)
        // Lit pixels use index 15 (the firmware reads the index as brightness), white in the palette.
        let bmp = NavMapBmp.grayFile(MonoBitmap(width: 2, height: 2, pixels: [true, true, true, true]))
        #expect(bmp[46] == 16)
        #expect(Array(bmp[(54 + 15 * 4)..<(54 + 15 * 4 + 3)]) == [255, 255, 255])
        #expect(bmp[118] == 0xFF)
    }

    // MARK: Planner

    @Test func firstFrameCreatesTheImagesAndUploadsThem() {
        var planner = G2PagePlanner()
        let image = Self.box()
        let frame = GlassesFrame(main: "", images: [image])
        #expect(planner.plan(frame) == [.create(G2TextBox.page([.main("\n", shape: .fullWidth)]), images: [image]), .uploadImage(image)])
        #expect(planner.plan(frame) == [])
    }

    @Test func aChangedPictureOnlyUploads() {
        var planner = G2PagePlanner()
        _ = planner.plan(GlassesFrame(main: "", images: [Self.box(bytes: [1])]))
        let next = Self.box(bytes: [2])
        #expect(planner.plan(GlassesFrame(main: "", images: [next])) == [.uploadImage(next)])
    }

    @Test func anIndicatorAppearingOrMovingRebuildsThePage() {
        var planner = G2PagePlanner()
        _ = planner.plan(.dark)
        let image = Self.box()
        #expect(planner.plan(GlassesFrame(main: "", images: [image]))
            == [.rebuild(G2TextBox.page([.main("\n", shape: .fullWidth)]), images: [image]), .uploadImage(image)])
        let moved = Self.box(x: 400)
        #expect(planner.plan(GlassesFrame(main: "", images: [moved]))
            == [.rebuild(G2TextBox.page([.main("\n", shape: .fullWidth)]), images: [moved]), .uploadImage(moved)])
        // It goes away again.
        #expect(planner.plan(.dark) == [.rebuild(G2TextBox.page([.main("\n", shape: .fullWidth)]))])
    }

    @Test func textChangesDoNotTouchTheImages() {
        var planner = G2PagePlanner()
        let image = Self.box()
        _ = planner.plan(GlassesFrame(main: "Hi", images: [image]))
        #expect(planner.plan(GlassesFrame(main: "Ho", images: [image])) == [.update(id: 1, name: "main", text: "Ho")])
    }

    @Test func aFailureRebuildsAndUploadsAgain() {
        var planner = G2PagePlanner()
        let image = Self.box()
        _ = planner.plan(GlassesFrame(main: "Hi", images: [image]))
        planner.markUnknown()
        #expect(planner.plan(GlassesFrame(main: "Hi", images: [image]))
            == [.rebuild(G2TextBox.page([.main("Hi", shape: .fullWidth)]), images: [image]), .uploadImage(image)])
    }

    @Test func imageContainersFitTheDisplay() {
        let renderer = IndicatorRenderer()
        let state = IndicatorState(attention: InboxKind.allCases.map { IndicatorCount(kind: $0, count: 99) }, locationActive: true)
        for box in renderer.images(for: state, showAttention: true, showLocation: true) {
            #expect(box.x >= 0 && box.y >= 0 && box.x + box.width <= G2Layout.width && box.y + box.height <= G2Layout.height)
            #expect(box.width >= 20 && box.height >= 20)
            #expect(box.name.utf8.count <= 14)
        }
    }
}
