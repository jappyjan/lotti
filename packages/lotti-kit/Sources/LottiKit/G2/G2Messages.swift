import Foundation

/// G2 service ids (frame byte 6). Full list in g2-kit `ble/docs/sids.md`.
public enum G2Service {
    /// App launch / session prelude.
    public static let appLaunch: UInt8 = 0x01
    /// Navigation: the firmware's turn-by-turn screen (see `G2Navigation`).
    public static let navigation: UInt8 = 0x08
    /// Glasses settings (brightness, head-up, wear detection).
    public static let settings: UInt8 = 0x09
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

    // MARK: Settings (sid 0x09)

    /// Switch the firmware's own head-up dashboard on or off. Lotti's today view replaces it, and
    /// the native one takes over the display and shuts our page down (MentraOS).
    /// `{1: set(1), 2: magic, 3: {4: headUp {1: switch}}}` (even-g2-protocol `build_head_up`).
    public static func headUpSetting(magic: UInt64, enabled: Bool) -> [UInt8] {
        var w = ProtoWriter()
        w.varint(1, 1)
        w.varint(2, magic)
        w.message(3) { $0.message(4) { $0.varint(1, enabled ? 1 : 0) } }
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
        createPage(magic: magic, boxes: [
            G2TextBox(id: containerID, name: containerName, x: 0, y: 0, width: displayWidth,
                      height: displayHeight, capturesEvents: true, text: text),
        ])
    }

    /// Cmd 0, CreateStartUpPage with several text containers. Only valid once per session; use
    /// `rebuildPage` to change the layout afterwards.
    /// `{1: container count, 3: TextObject (repeated), 5: widget id}`
    ///
    /// With `images`, each image container goes in field 4 (`ImageContainerProperty`) and counts in
    /// field 1. **Unverified on hardware** (see `imageObject`).
    public static func createPage(magic: UInt64, boxes: [G2TextBox], list: G2ListBox? = nil,
                                  images: [G2ImageBox] = []) -> [UInt8] {
        evenHub(command: 0, magic: magic, field: 3) {
            $0.varint(1, boxes.count + (list == nil ? 0 : 1) + images.count)
            if let list { $0.message(2) { listObject(list, into: &$0) } }
            for box in boxes { $0.message(3) { textObject(box, into: &$0) } }
            for image in images { $0.message(4) { imageObject(image, into: &$0) } }
            $0.varint(5, 10000)  // widget id, as used by every known client
        }
    }

    /// Cmd 7, RebuildPageContainer: replace the page's containers. Same body as the create, but
    /// in envelope field 7 and without a widget id (field 5 is a MenuObject here). The glasses
    /// ack with Cmd 8 `{8: {1: 6 success / 7 failed}}`. Layout from even-g2-protocol
    /// `build_rebuild_page` and MentraOS `rebuildPageMessage`.
    public static func rebuildPage(magic: UInt64, boxes: [G2TextBox], list: G2ListBox? = nil,
                                   images: [G2ImageBox] = []) -> [UInt8] {
        evenHub(command: 7, magic: magic, field: 7) {
            $0.varint(1, boxes.count + (list == nil ? 0 : 1) + images.count)
            if let list { $0.message(2) { listObject(list, into: &$0) } }
            for box in boxes { $0.message(3) { textObject(box, into: &$0) } }
            for image in images { $0.message(4) { imageObject(image, into: &$0) } }
        }
    }

    /// Result code in a Cmd 8 rebuild ack: 6 = success, 7 = failed; nil if it's not a rebuild ack.
    public static func rebuildResult(_ reply: [UInt8]) -> UInt64? {
        guard ProtoReader.varintFields(reply)[1] == 8, let res = ProtoReader.message(reply, 8) else { return nil }
        return ProtoReader.varintFields(res)[1] ?? 0
    }

    /// TextContainerProperty `{1 x, 2 y, 3 w, 4 h, 9 id, 10 name, 11 capture events, 12 text}`.
    /// Fields 5–8 (border, padding) are left out, as in the hardware-confirmed builders.
    private static func textObject(_ box: G2TextBox, into w: inout ProtoWriter) {
        w.varint(1, box.x)
        w.varint(2, box.y)
        w.varint(3, box.width)
        w.varint(4, box.height)
        w.varint(9, box.id)
        w.string(10, box.name)
        if box.capturesEvents { w.varint(11, 1) }
        w.string(12, box.text)
    }

    /// ListContainerProperty `{1 x, 2 y, 3 w, 4 h, 9 id, 10 name, 11 items, 12 capture events}` with
    /// List_ItemContainerProperty `{1 count, 2 item width, 3 selection border, 4 names}` (g2-kit
    /// `EvenHub_pb.ts`). Border and padding (5–8) are left out, as for text. Item width 0 lets the
    /// firmware size the items to the container.
    private static func listObject(_ list: G2ListBox, into w: inout ProtoWriter) {
        w.varint(1, list.x)
        w.varint(2, list.y)
        w.varint(3, list.width)
        w.varint(4, list.height)
        w.varint(9, list.id)
        w.string(10, list.name)
        w.message(11) { items in
            items.varint(1, list.items.count)
            items.varint(3, 1)
            for name in list.items { items.string(4, name) }
        }
        w.varint(12, 1)
    }

    /// ImageContainerProperty `{1 x, 2 y, 3 w, 4 h, 5 id, 6 name}`: the image counterpart of
    /// `textObject`. **Unverified on hardware:** field numbers follow the Even Hub schema as
    /// remembered from even-g2-protocol (images are the fourth container list of the page, after
    /// lists and text); no capture of a page with an image container exists yet.
    private static func imageObject(_ image: G2ImageBox, into w: inout ProtoWriter) {
        w.varint(1, image.x)
        w.varint(2, image.y)
        w.varint(3, image.width)
        w.varint(4, image.height)
        w.varint(5, image.id)
        w.string(6, image.name)
    }

    /// Largest chunk of image data per message.
    public static let imageFragmentSize = 4096

    /// Cmd 3, image raw data: upload (part of) an image container's pixels. The glasses ack with
    /// Cmd 4. The body follows the nav-map upload (`G2Navigation.maxMapFragment`) with the
    /// container's id and name in front:
    /// `{1 containerID, 2 containerName, 3 sessionID, 4 totalSize, 5 compressMode,
    /// 6 fragmentIndex, 7 fragmentSize, 8 rawData}` in envelope field 5.
    /// **Unverified on hardware:** the Cmd number (3, acked as 4, like the 0/1, 5/6, 7/8 pairs)
    /// and the field numbers are inferred, not captured.
    public static func imageUpdate(
        magic: UInt64, image: G2ImageBox, sessionID: Int, fragmentIndex: Int, fragment: [UInt8]
    ) -> [UInt8] {
        evenHub(command: 3, magic: magic, field: 5) {
            $0.varint(1, image.id)
            $0.string(2, image.name)
            $0.varint(3, sessionID)
            $0.varint(4, image.data.count)
            $0.varint(5, image.compression.rawValue)
            $0.varint(6, fragmentIndex)
            $0.varint(7, fragment.count)
            $0.bytes(8, fragment)
        }
    }

    /// The `imageUpdate` messages that upload `image`, one per fragment, in order. Each needs its
    /// own magic, so `magics` supplies them.
    public static func imageUpdates(
        image: G2ImageBox, sessionID: Int, magic: () -> UInt64, fragmentSize: Int = imageFragmentSize
    ) -> [[UInt8]] {
        let size = max(fragmentSize, 1)
        return stride(from: 0, to: image.data.count, by: size).enumerated().map { index, start in
            imageUpdate(magic: magic(), image: image, sessionID: sessionID, fragmentIndex: index,
                        fragment: Array(image.data[start..<min(start + size, image.data.count)]))
        }
    }

    /// Cmd 19, IMU control: `{1: enable, 2: report pace}` in envelope field 20 (MentraOS, found by
    /// brute force on hardware) or 22 (even-g2-protocol). The pace is a code from 100 to 1000 in
    /// steps of 100, not Hz, and is only sent when enabling. Reports then arrive as Sys events of
    /// type 8 (see `G2Events`). Needs a live EvenHub page.
    public static func imuControl(magic: UInt64, enable: Bool, pace: Int = 500, field: Int = 20) -> [UInt8] {
        evenHub(command: 19, magic: magic, field: field) {
            $0.varint(1, enable ? 1 : 0)
            if enable { $0.varint(2, pace) }
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
