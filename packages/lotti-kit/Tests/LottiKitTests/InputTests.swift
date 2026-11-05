import Testing
@testable import LottiKit

struct G2EventTests {
    private func decode(_ payload: String, sid: UInt8 = G2Service.evenHub, flag: UInt8 = 0x01) -> G2Event? {
        G2Events.decode(G2Message(sid: sid, flag: flag, seq: 1, payload: bytes(payload)))
    }

    // From even-g2-protocol's tests (tests/test_g2_widgets.py).
    @Test func longPressOnTextContainer() {
        #expect(decode("080210016a09120708011201741809") == .input(InputEvent(.longPress, from: .unknown)))
    }

    @Test func listEventWithZeroFieldsLeftOutIsATap() {
        #expect(decode("080210016a070a05080412016d") == .input(InputEvent(.tap, from: .unknown, item: 0)))
    }

    @Test func aPickOnTheListSaysWhichItem() {
        // List_ItemEvent {1 id 2, 2 "rail", 3 "No", 4 index 1}, a click (type 0 left out).
        #expect(decode("08026a100a0e080212047261696c1a024e6f2001") == .input(InputEvent(.tap, from: .unknown, item: 1)))
    }

    // Captured from a G2 (firmware 2.2.9) with an R1 linked, 2026-11-01. Payloads of
    // sid 0xE0 flag 0x01 messages from the right arm.
    @Test(arguments: [
        ("08026a041a021001", InputEvent(.tap, from: .rightTouchpad)),
        ("08026a061a0408031001", InputEvent(.doubleTap, from: .rightTouchpad)),
        ("08026a041a021003", InputEvent(.tap, from: .leftTouchpad)),
        ("08026a061a0408031003", InputEvent(.doubleTap, from: .leftTouchpad)),
        ("08026a041a021002", InputEvent(.tap, from: .ring)),
        ("08026a061a0408031002", InputEvent(.doubleTap, from: .ring)),
        // Scrolls come as text-container events and long presses as sys events without a
        // source, whether from a touchpad or the ring.
        ("08026a0d120b080112056c6f7474691802", InputEvent(.scrollDown, from: .unknown)),
        ("08026a0d120b080112056c6f7474691801", InputEvent(.scrollUp, from: .unknown)),
        ("08026a041a020809", InputEvent(.longPress, from: .unknown)),
        ("08026a041a02080a", InputEvent(.longPressEnd, from: .unknown)),
    ])
    func capturedGestures(payload: String, expected: InputEvent) {
        #expect(decode(payload) == .input(expected))
    }

    @Test func capturedStatusMessages() {
        #expect(decode("08011a0308e001", sid: G2Events.stateService) == .info("state change 08011a0308e001"))
        // The left arm pushes this every 10 s (flag 0x01). It needs no answer.
        #expect(decode("080610572a00", sid: G2Service.deviceConfig) == .info("ring info: connect 0, status 0"))
    }

    @Test func lifecycleEventsAreInfo() {
        // FOREGROUND_EXIT with widget 10000 and session 3, as built by even-g2-protocol.
        #expect(decode("080210016a091a07080528904e3003") == .info("app event: foreground exit"))
    }

    @Test func repliesAreNotEvents() {
        #expect(decode("080c10657a00", flag: 0x00) == nil)  // heartbeat ack
        #expect(decode("08061066", flag: 0x00) == nil)  // text update ack
    }

    @Test func ringConnectInfo() {
        let event = decode("080610652a0c080112060102030405062016", sid: G2Service.deviceConfig)
        #expect(event == .info("ring info: connect 1, status 22, mac 06:05:04:03:02:01 (080112060102030405062016)"))
    }

    @Test func truncatedPayloadsDontCrash() {
        #expect(decode("08026a0a1a02") == nil)
        #expect(decode("08026aff") == nil)
    }
}

struct InputDeduplicatorTests {
    /// Feeds `events` in order and returns which ones got through.
    private func accepted(_ events: [(InputEvent, Double)]) -> [Bool] {
        var d = InputDeduplicator(window: 0.25)
        return events.map { d.accept($0.0, at: $0.1) }
    }

    @Test func dropsRepeatsWithinTheWindow() {
        let result = accepted([
            (InputEvent(.tap, from: .rightTouchpad), 10.00),
            (InputEvent(.tap, from: .unknown), 10.05),
            (InputEvent(.tap, from: .rightTouchpad), 10.20),
            (InputEvent(.tap, from: .rightTouchpad), 10.60),
        ])
        #expect(result == [true, false, false, true])
    }

    @Test func differentGesturesPass() {
        let result = accepted([
            (InputEvent(.scrollUp, from: .ring), 1.0),
            (InputEvent(.scrollDown, from: .ring), 1.1),
            (InputEvent(.scrollUp, from: .ring), 1.2),
        ])
        #expect(result == [true, true, true])
    }
}
