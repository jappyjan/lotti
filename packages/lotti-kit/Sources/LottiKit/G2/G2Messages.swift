import Foundation

/// G2 service ids (frame byte 6). Full list in g2-kit `ble/docs/sids.md`.
public enum G2Service {
    /// App launch / session prelude.
    public static let appLaunch: UInt8 = 0x01
    /// Device config: auth, arm roles, time sync.
    public static let deviceConfig: UInt8 = 0x80
    /// EvenHub: pages, text/list/image containers, heartbeat.
    public static let evenHub: UInt8 = 0xE0
}

public enum G2Flag {
    public static let request: UInt8 = 0x20
    public static let deviceConfig: UInt8 = 0x00
}

/// Builders for the protobuf payloads Lotti sends. Field numbers come from the Even app's
/// protobuf schemas as decoded by g2-kit, even-g2-protocol and MentraOS.
public enum G2Payload {
    // MARK: Device config (sid 0x80)

    /// Authenticate the phone with one arm. Sent to both arms after connecting.
    /// `{1: AUTHENTICATION(4), 2: magic, 3: {secAuth: true, phoneType: iOS(3)}}`
    public static func auth(magic: UInt64) -> [UInt8] {
        var w = ProtoWriter()
        w.varint(1, 4)
        w.varint(2, magic)
        w.message(3) {
            $0.bool(1, true)
            $0.varint(2, 3)
        }
        return w.bytes
    }

    /// Make the right arm the command arm. `{1: PIPE_ROLE_CHANGE(5), 2: magic, 4: {1: RIGHT}}`
    public static func rightArmIsCommandArm(magic: UInt64) -> [UInt8] {
        var w = ProtoWriter()
        w.varint(1, 5)
        w.varint(2, magic)
        w.message(4) { $0.varint(1, 1) }
        return w.bytes
    }

    /// Set the glasses' clock. The firmware ignores time zones, so local time is sent as if UTC.
    /// `{1: TIME_SYNC(128), 2: magic, 128: {1: local seconds}}`
    public static func timeSync(magic: UInt64, date: Date, timeZone: TimeZone = .current) -> [UInt8] {
        let local = Int(date.timeIntervalSince1970) + timeZone.secondsFromGMT(for: date)
        var w = ProtoWriter()
        w.varint(1, 128)
        w.varint(2, magic)
        w.message(128) { $0.varint(1, local) }
        return w.bytes
    }

    // MARK: App launch (sid 0x01)

    /// Magic of the prelude; the glasses' ack echoes it.
    public static let preludeMagic: UInt64 = 156

    /// Session prelude. Without it the glasses ignore EvenHub commands.
    /// `{1: 2, 2: 156, 4: {3: {2: {2: {1: 0, 2: 0}}}}}`, byte-identical to captures.
    public static func prelude() -> [UInt8] {
        var w = ProtoWriter()
        w.varint(1, 2)
        w.varint(2, preludeMagic)
        w.message(4) {
            $0.message(3) {
                $0.message(2) {
                    $0.message(2) {
                        $0.varint(1, 0)
                        $0.varint(2, 0)
                    }
                }
            }
        }
        return w.bytes
    }

    // MARK: EvenHub (sid 0xE0)

    /// The display is 576 × 288.
    public static let displayWidth = 576
    public static let displayHeight = 288

    /// Cmd 0, CreateStartUpPage: one full-screen text container. Only valid once per session;
    /// use `textUpdate` afterwards.
    public static func createTextPage(
        magic: UInt64, containerID: Int, containerName: String, text: String
    ) -> [UInt8] {
        evenHub(command: 0, magic: magic, field: 3) {
            $0.varint(1, 1)  // container count
            $0.message(3) {  // TextObject
                $0.varint(1, 0)  // x
                $0.varint(2, 0)  // y
                $0.varint(3, displayWidth)
                $0.varint(4, displayHeight)
                $0.varint(9, containerID)
                $0.string(10, containerName)
                $0.varint(11, 1)  // capture events
                $0.string(12, text)
            }
            $0.varint(5, 10000)  // widget id, as used by every known client
        }
    }

    /// Cmd 5, TextContainerUpgrade: replace the text of an existing container.
    public static func textUpdate(
        magic: UInt64, containerID: Int, containerName: String, text: String
    ) -> [UInt8] {
        evenHub(command: 5, magic: magic, field: 9) {
            $0.varint(1, containerID)
            $0.string(2, containerName)
            $0.varint(3, 0)  // offset
            $0.varint(4, text.utf8.count)
            $0.string(5, text)
        }
    }

    /// Cmd 12, heartbeat. Must be sent every few seconds or the glasses end the session.
    public static func heartbeat(magic: UInt64) -> [UInt8] {
        evenHub(command: 12, magic: magic, field: 14) { $0.varint(1, 0) }
    }

    /// Cmd 15, audio control: turn the microphone on or off. Goes to the right arm, which acks
    /// with the magic. Audio then streams on `…6402` (see `G2Microphone`).
    /// `{1: 15, 2: magic, 18: {1: 1 on / 0 off}}` (MentraOS `audioControlMessage`,
    /// even-g2-protocol `build_audio_control`).
    public static func audioControl(magic: UInt64, enabled: Bool) -> [UInt8] {
        evenHub(command: 15, magic: magic, field: 18) { $0.bool(1, enabled) }
    }

    private static func evenHub(
        command: Int, magic: UInt64, field: Int, _ build: (inout ProtoWriter) -> Void
    ) -> [UInt8] {
        var w = ProtoWriter()
        w.varint(1, command)
        w.varint(2, magic)
        w.message(field, build)
        return w.bytes
    }
}

/// Which arm a peripheral is. Each G2 arm is its own BLE peripheral.
public enum G2Side: String, Codable, Sendable {
    case left, right
}

/// Parses G2 advertising names like `Even G2_32_L_ABCDEF`.
public enum G2Name {
    public struct Parsed: Equatable, Sendable {
        /// Shared by both arms of one pair of glasses.
        public var pairID: String
        public var side: G2Side
    }

    public static func parse(_ name: String?) -> Parsed? {
        guard let name, let match = name.firstMatch(of: /G2_([A-Za-z0-9]+)_([LR])(?:_|$)/) else {
            return nil
        }
        return Parsed(pairID: String(match.1), side: match.2 == "L" ? .left : .right)
    }
}
