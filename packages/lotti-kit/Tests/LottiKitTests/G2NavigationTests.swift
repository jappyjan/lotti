import Foundation
import Testing
@testable import LottiKit

/// Golden bytes follow even-g2-protocol `apps/navigation.py`'s builders
/// (`navigation_main_msg_ctx`: `{1 cmd, 2 magic, 3..12 sub}`).
struct G2NavigationTests {
    @Test func simpleCommands() {
        #expect(hex(G2Navigation.heartbeat(magic: 7)) == "080010071a00")
        #expect(hex(G2Navigation.start(magic: 100)) == "080510641a00")
        #expect(hex(G2Navigation.recalculating(magic: 3)) == "080a10031a00")
        #expect(hex(G2Navigation.arrive(magic: 4)) == "080b10041a00")
        #expect(hex(G2Navigation.stop(magic: 5)) == "080c10051a00")
    }

    @Test func basicInfoMatchesTheDecodedSchema() {
        let payload = G2Navigation.basicInfo(
            magic: 42, direction: NavigateDirectionSign.turnRight.rawValue,
            distance: "200 m", road: "Torstraße", remainingTime: "5 min",
            remainingDistance: "1.2 km", eta: "14:35", speed: "6 km/h",
            method: G2Navigation.methodCycling, counter: 1)
        var expected = ProtoWriter()
        expected.varint(1, 7)
        expected.varint(2, 42)
        expected.message(5) {
            $0.varint(1, 3)
            $0.string(2, "200 m")
            $0.string(3, "Torstraße")
            $0.string(4, "5 min")
            $0.string(5, "1.2 km")
            $0.string(6, "ETA: 14:35")
            $0.string(7, "6 km/h")
            $0.varint(8, 2)
            $0.varint(10, 1)
        }
        #expect(payload == expected.bytes)
    }

    @Test func basicInfoLeavesExistingETAPrefixAlone() {
        let payload = G2Navigation.basicInfo(magic: 1, direction: 2, eta: "ETA: 14:35")
        #expect(ProtoReader.string(ProtoReader.message(payload, 5) ?? [], 6) == "ETA: 14:35")
    }

    @Test func emptyTextFieldsBecomeDoubleDash() {
        let payload = G2Navigation.basicInfo(magic: 1, direction: 2, road: "  ")
        #expect(ProtoReader.string(ProtoReader.message(payload, 5) ?? [], 3) == "--")
        #expect(G2Navigation.text(nil) == "--")
    }

    @Test func textCutsAt60BytesOnACharacterBoundary() {
        let cut = G2Navigation.text(String(repeating: "ü", count: 35))  // 70 bytes
        #expect(Array(cut.utf8).count == 60)
        #expect(cut == String(repeating: "ü", count: 30))
        #expect(G2Navigation.text(String(repeating: "a", count: 55)) == String(repeating: "a", count: 55))
    }

    @Test func locationListCarriesNames() {
        let payload = G2Navigation.locationList(magic: 1, names: ["Home", "Work"])
        let f = ProtoReader.varintFields(payload)
        #expect(f[1] == G2Navigation.cmdLocationList)
        let list = ProtoReader.message(payload, 4) ?? []
        let s = ProtoReader.varintFields(list)
        #expect(s[1] == 2)
        #expect(ProtoReader.string(list, 2) == "Home")
    }

    // MARK: Map bitmaps

    @Test func miniMapCarriesTheBitmapAndRotation() {
        let data: [UInt8] = [0xF0, 0x0F, 0xFF]
        let payload = G2Navigation.miniMap(magic: 5, data: data, rotationAngle: 90, border: 1)
        var expected = ProtoWriter()
        expected.varint(1, 8)
        expected.varint(2, 5)
        expected.message(6) {
            $0.varint(1, 3)
            $0.varint(2, 0)
            $0.bytes(3, data)
            $0.varint(5, 90)
            $0.varint(6, 1)
        }
        #expect(payload == expected.bytes)
        #expect(G2Navigation.miniMap(magic: 5, data: data) == G2Navigation.miniMap(magic: 5, data: data, size: 3))
    }

    @Test func maxMapFragmentsShareTheSession() {
        let payload = G2Navigation.maxMapFragment(magic: 7, sessionID: 3, totalSize: 100,
                                                  index: 2, packetSize: 40, data: [0x01, 0x02])
        var expected = ProtoWriter()
        expected.varint(1, 9)
        expected.varint(2, 7)
        expected.message(7) {
            $0.varint(1, 3)
            $0.varint(2, 100)
            $0.varint(3, 0)
            $0.varint(4, 2)
            $0.varint(5, 40)
            $0.bytes(6, [0x01, 0x02])
        }
        #expect(payload == expected.bytes)
    }

    // MARK: Events from the glasses

    @Test func decodesMenuStartupAndExits() {
        #expect(G2NavigationEvent.decode(bytes("08011005")) == .menuStartup(magic: 5))
        #expect(G2NavigationEvent.decode(bytes("080d100a")) == .notifyExit)
        #expect(G2NavigationEvent.decode(bytes("08141003")) == .endSessionReq)
        #expect(G2NavigationEvent.decode(bytes("080d100a")).isExit)
        #expect(G2NavigationEvent.decode(bytes("08141003")).isExit)
        #expect(!G2NavigationEvent.decode(bytes("08011005")).isExit)
    }

    @Test func decodesLocationSelected() {
        #expect(G2NavigationEvent.decode(bytes("08041009420f0a094d617565727061726b18022001"))
            == .locationSelected(location: "Mauerpark", index: 2, method: 1, magic: 9))
    }

    @Test func decodesViewChangesAndCompassEvents() {
        #expect(G2NavigationEvent.decode(bytes("080e10014a020802")) == .viewChanged(view: 2))
        #expect(G2NavigationEvent.decode(bytes("080f100452020802")) == .compassChanged(value: 2))
        #expect(G2NavigationEvent.decode(bytes("08101001")) == .compassCalibrateStart)
        #expect(G2NavigationEvent.decode(bytes("08111001")) == .compassCalibrateDone)
    }

    @Test func decodesSwitchTransportRequest() {
        #expect(G2NavigationEvent.decode(bytes("081210035a020802")) == .switchTransportReq(method: 2, magic: 3))
    }

    @Test func replyEchoesDecodeAsOther() {
        #expect(G2NavigationEvent.decode(bytes("080510641a00")) == .other(cmd: G2Navigation.cmdStart))
    }

    @Test func replyErrorReadsTheExtendInfo() {
        #expect(G2Navigation.replyError(G2Navigation.start(magic: 9)) == 0)
        #expect(G2Navigation.replyError(G2Navigation.errorInfo(magic: 9, message: "nope")) == 7)
        // BASIC_INFO replies carry the error at field 9 inside field 5.
        var w = ProtoWriter()
        w.varint(1, 7)
        w.varint(2, 9)
        w.message(5) { $0.varint(9, 3) }
        #expect(G2Navigation.replyError(w.bytes) == 3)
    }
}
