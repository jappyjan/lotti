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
        #expect(decode("080210016a070a05080412016d") == .input(InputEvent(.tap, from: .unknown)))
    }

    @Test func sysEventCarriesTheSource() {
        // Sys_ItemEvent {1 eventType, 2 eventSource}; an absent eventType is a click.
        #expect(decode("08026a041a021002") == .input(InputEvent(.tap, from: .ring)))
        #expect(decode("08026a061a0408031001") == .input(InputEvent(.doubleTap, from: .rightTouchpad)))
        #expect(decode("08026a061a0408011003") == .input(InputEvent(.scrollUp, from: .leftTouchpad)))
        #expect(decode("08026a061a0408021002") == .input(InputEvent(.scrollDown, from: .ring)))
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

struct R1GestureTests {
    // `FF <type> <param>` from MentraOS controllers/R1.swift.
    @Test func parsesGestures() {
        #expect(R1Gesture.parse([0xFF, 0x04, 0x01]) == .tap)
        #expect(R1Gesture.parse([0xFF, 0x04, 0x02]) == .doubleTap)
        #expect(R1Gesture.parse([0xFF, 0x03, 0x00]) == .longPress)
        #expect(R1Gesture.parse([0xFF, 0x05, 0x01]) == .scrollUp)
        #expect(R1Gesture.parse([0xFF, 0x05, 0xFF]) == .scrollDown)
        #expect(R1Gesture.parse([0x01]) == nil)
        #expect(R1Gesture.parse([0xFF, 0x09, 0x00]) == nil)
    }
}
