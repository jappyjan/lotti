import Foundation
import Testing
@testable import LottiKit

/// Golden bytes come from captures of the real glasses (prelude, auth) or from
/// even-g2-protocol's hardware-confirmed Python builders (generated, not hand-written).
struct G2ProtocolTests {
    @Test func crcMatchesCCITTFalseCheckValue() {
        #expect(CRC16.ccittFalse(Array("123456789".utf8)) == 0x29B1)
    }

    @Test func preludeFrameMatchesCapture() {
        let frames = G2Frame.encode(payload: G2Payload.prelude(), sid: G2Service.appLaunch,
                                    flag: G2Flag.request, seq: 0x92)
        #expect(frames.map(hex) == ["aa219213010101200802109c01220a1a081206120408001000a142"])
    }

    @Test func singlePacketFrames() {
        // Even AI "enter" from even-g2-protocol's docs; file-service prefix from its golden tests.
        let enter = G2Frame.encode(payload: bytes("080110421a020802"), sid: 0x07, flag: 0x20, seq: 5)
        #expect(enter.map(hex) == ["aa21050a0101072008011042" + "1a0208026d6c"])
        let prefix = G2Frame.encode(payload: [0x01], sid: 0xC4, flag: 0x00, seq: 0x11)
        #expect(prefix.map(hex) == ["aa2111030101c40001d1f1"])
    }

    @Test func createTextPage() {
        let payload = G2Payload.createTextPage(magic: 101, containerID: 1, containerName: "lotti",
                                               text: "Hello from Lotti")
        #expect(hex(payload) == "080010651a2e08011a270800100018c00420a002480152056c6f7474695801621048656c6c6f2066726f6d204c6f74746928904e")
        let frames = G2Frame.encode(payload: payload, sid: G2Service.evenHub, flag: G2Flag.request, seq: 7)
        #expect(frames.map(hex) == ["aa2107360101e020" + hex(payload) + "885d"])
    }

    @Test func textUpdate() {
        let payload = G2Payload.textUpdate(magic: 102, containerID: 1, containerName: "lotti", text: "Hello from Lotti")
        #expect(hex(payload) == "080510664a1f080112056c6f747469180020102a1048656c6c6f2066726f6d204c6f747469")
    }

    @Test func textUpdateCountsUTF8Bytes() {
        let payload = G2Payload.textUpdate(magic: 1, containerID: 1, containerName: "x", text: "Grüße")
        // field 4 = byte length 7, not character count 5
        #expect(hex(payload).contains("2007"))
    }

    @Test func heartbeat() {
        #expect(hex(G2Payload.heartbeat(magic: 103)) == "080c106772020800")
    }

    @Test func authTellsTheGlassesWeAreAnIPhone() {
        // {1: 4, 2: magic, 3: {1: true, 2: 3}}. Python uses phoneType 4 (Android); MentraOS on iOS uses 3.
        #expect(hex(G2Payload.auth(magic: 0x2A)) == "0804102a1a0408011003")
    }

    @Test func rightArmIsCommandArm() {
        #expect(hex(G2Payload.rightArmIsCommandArm(magic: 9)) == "080510092202" + "0801")
    }

    @Test func timeSyncSendsLocalTimeAsUTC() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let tz = TimeZone(secondsFromGMT: 3600)!
        let payload = G2Payload.timeSync(magic: 1, date: date, timeZone: tz)
        var expected = ProtoWriter()
        expected.varint(1, 128)
        expected.varint(2, 1)
        expected.message(128) { $0.varint(1, 1_003_600) }
        #expect(payload == expected.bytes)
        #expect(hex(payload).hasPrefix("088001100182")) // field 128 key is the two-byte varint 82 08
    }

    @Test func longPayloadSplitsIntoPacketsSharingOneSeq() {
        let payload = (0..<500).map { UInt8($0 & 0xFF) }
        let frames = G2Frame.encode(payload: payload, sid: 0xE0, flag: 0x20, seq: 0x33, maxPacketSize: 244)
        #expect(frames.count == 3)
        for (i, frame) in frames.enumerated() {
            #expect(frame[2] == 0x33)  // same seq on every packet
            #expect(frame[4] == 3)
            #expect(frame[5] == UInt8(i + 1))
            #expect(frame.count <= 244)
            #expect(Int(frame[3]) == frame.count - 8)
        }
        #expect(frames[0].count == 8 + 232)
        #expect(frames[2].count == 8 + (500 - 464) + 2)
    }

    @Test func respectsSmallWriteSizes() {
        let frames = G2Frame.encode(payload: Array(repeating: 1, count: 300), sid: 0xE0, flag: 0x20,
                                    seq: 1, maxPacketSize: 182)
        #expect(frames.allSatisfy { $0.count <= 182 })
    }

    @Test func assemblerJoinsPacketsAndChecksCRC() {
        let payload = (0..<500).map { UInt8($0 % 251) }
        var assembler = G2FrameAssembler()
        let incoming = G2Frame.encode(payload: payload, sid: 0xE0, flag: 0x00, seq: 9).map(fromGlasses)
        #expect(assembler.feed(incoming[0]) == nil)
        #expect(assembler.feed(incoming[1]) == nil)
        let message = assembler.feed(incoming[2])
        #expect(message?.payload == payload)
        #expect(message?.sid == 0xE0)
        #expect(assembler.crcErrors == 0)
    }

    @Test func assemblerDropsMessagesWithMissingPackets() {
        var assembler = G2FrameAssembler()
        let incoming = G2Frame.encode(payload: Array(repeating: 7, count: 500), sid: 0xE0, flag: 0, seq: 1)
            .map(fromGlasses)
        #expect(assembler.feed(incoming[0]) == nil)
        #expect(assembler.feed(incoming[2]) == nil)
    }

    @Test func replyMagicIsReadEvenWithoutCommandField() {
        // Auth ack as described by even-g2-protocol: 08 04 10 <magic> … 1a 00
        let ack = G2Frame.encode(payload: bytes("0804102a1a00"), sid: 0x80, flag: 0, seq: 1).map(fromGlasses)[0]
        var assembler = G2FrameAssembler()
        let message = assembler.feed(ack)
        #expect(message?.magic == 0x2A)
        #expect(message?.command == 4)
        // proto3 omits a zero command, so a reply may start with field 2
        #expect(G2Message(sid: 0xE0, flag: 0, seq: 0, payload: bytes("1065")).magic == 101)
    }

    @Test(arguments: [
        ("Even G2_32_L_ABCDEF", G2Name.Parsed(pairID: "32", side: .left)),
        ("Even G2_32_R_ABCDEF", G2Name.Parsed(pairID: "32", side: .right)),
        ("G2_7_R_", G2Name.Parsed(pairID: "7", side: .right)),
    ])
    func parsesArmNames(name: String, expected: G2Name.Parsed) {
        #expect(G2Name.parse(name) == expected)
    }

    @Test func ignoresOtherDevices() {
        #expect(G2Name.parse("Even G1_32_L_ABC") == nil)  // G1 uses a different protocol
        #expect(G2Name.parse("AirPods Pro") == nil)
        #expect(G2Name.parse(nil) == nil)
    }
}

func bytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map {
        let start = hex.index(hex.startIndex, offsetBy: $0)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    }
}

/// Turns a phone → glasses packet into what the glasses would send (direction byte 0x12).
private func fromGlasses(_ packet: [UInt8]) -> [UInt8] {
    var p = packet
    p[1] = G2Frame.fromGlasses
    return p
}
