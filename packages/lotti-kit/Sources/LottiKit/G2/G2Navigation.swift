import Foundation

/// The firmware's turn-by-turn navigation screen (service 0x08).
///
/// The phone does the routing and drives the screen: it opens it (START), sends a small
/// "basic info" card on every progress update — an arrow (directionSignIndex 1–35), the distance
/// to the next turn, road name, time/distance remaining, ETA and speed — keeps it alive with a
/// heartbeat, and closes it on arrival or stop. The firmware lays out the screen, rotates it
/// heading-up and reports view changes and exit back to the phone.
///
/// Layout from the Even app's decompile, as decoded in even-g2-protocol `apps/navigation.py`
/// (`navigate_ble_service.dart` / `heartbeat_controller.dart`): every message is a
/// `navigation_main_msg_ctx` protobuf `{1 cmd, 2 magic, 3..12 one sub-message}`, where the simple
/// commands carry an empty `extend_info` sub-message in field 3. Strings are UTF-8, cut to ≤60
/// bytes on a character boundary, missing values sent as "--". Untested live on our side.
public enum G2Navigation {
    public static let cmdHeartbeat: UInt64 = 0
    public static let cmdMenuStartup: UInt64 = 1
    public static let cmdLocationList: UInt64 = 2
    public static let cmdLocationNone: UInt64 = 3
    public static let cmdLocationSelected: UInt64 = 4
    public static let cmdStart: UInt64 = 5
    public static let cmdErrorInfo: UInt64 = 6
    public static let cmdBasicInfo: UInt64 = 7
    public static let cmdMiniMap: UInt64 = 8
    public static let cmdMaxMap: UInt64 = 9
    public static let cmdRecalculating: UInt64 = 10
    public static let cmdArrive: UInt64 = 11
    public static let cmdStop: UInt64 = 12
    public static let cmdNotifyExit: UInt64 = 13
    public static let cmdViewChanged: UInt64 = 14
    public static let cmdCompassChanged: UInt64 = 15
    public static let cmdCompassCalibrateStart: UInt64 = 16
    public static let cmdCompassCalibrateDone: UInt64 = 17
    public static let cmdSwitchTransportReq: UInt64 = 18
    public static let cmdSwitchTransportRsp: UInt64 = 19
    public static let cmdEndSessionReq: UInt64 = 20

    /// navigateWorkMethod: what the Even app sends as transport method.
    public static let methodWalking: UInt64 = 1
    public static let methodCycling: UInt64 = 2

    /// Text fields are at most 60 UTF-8 bytes on the glasses' screen.
    public static let textMaxBytes = 60

    // MARK: App → glasses

    /// START (cmd 5): open the navigation screen. `{1: 5, 2: magic, 3: {}}`.
    public static func start(magic: UInt64) -> [UInt8] {
        package(cmd: cmdStart, magic: magic, field: 3) { _ in }
    }

    /// HEARTBEAT (cmd 0): every 5 s while the screen is up; the session ends if none lands for
    /// 30 s. `{1: 0, 2: magic, 3: {}}`.
    public static func heartbeat(magic: UInt64) -> [UInt8] {
        package(cmd: cmdHeartbeat, magic: magic, field: 3) { _ in }
    }

    /// RECALCULATING (cmd 10): the route is being re-planned. `{1: 10, 2: magic, 3: {}}`.
    public static func recalculating(magic: UInt64) -> [UInt8] {
        package(cmd: cmdRecalculating, magic: magic, field: 3) { _ in }
    }

    /// ARRIVE (cmd 11): destination reached. `{1: 11, 2: magic, 3: {}}`.
    public static func arrive(magic: UInt64) -> [UInt8] {
        package(cmd: cmdArrive, magic: magic, field: 3) { _ in }
    }

    /// STOP (cmd 12): close the navigation screen. `{1: 12, 2: magic, 3: {}}`.
    public static func stop(magic: UInt64) -> [UInt8] {
        package(cmd: cmdStop, magic: magic, field: 3) { _ in }
    }

    /// BASIC_INFO (cmd 7): the progress card.
    /// `{1: 7, 2: magic, 5: {1 directionSignIndex, 2 distance, 3 roadName, 4 spendTime,
    /// 5 remainDistance, 6 etaTime, 7 speed, 8 navigateWorkMethod, 10 basicInfoIndex}}`.
    /// All text is pre-formatted ("200 m", "5 min", "1.2 km"); `eta` gets the "ETA: " prefix
    /// unless it already has one. `counter` is a running index, reset when the route starts.
    public static func basicInfo(
        magic: UInt64,
        direction: UInt64?,
        distance: String? = nil,
        road: String? = nil,
        remainingTime: String? = nil,
        remainingDistance: String? = nil,
        eta: String? = nil,
        speed: String? = nil,
        method: UInt64 = methodWalking,
        counter: UInt64 = 0
    ) -> [UInt8] {
        package(cmd: cmdBasicInfo, magic: magic, field: 5) { w in
            w.varint(1, direction ?? 0)
            if let distance { w.string(2, text(distance)) }
            if let road { w.string(3, text(road)) }
            if let remainingTime { w.string(4, text(remainingTime)) }
            if let remainingDistance { w.string(5, text(remainingDistance)) }
            if let eta {
                let withPrefix = eta.trimmingCharacters(in: .whitespaces).isEmpty
                    || eta.hasPrefix("ETA") ? eta : "ETA: \(eta)"
                w.string(6, text(withPrefix))
            }
            if let speed { w.string(7, text(speed)) }
            w.varint(8, method)
            if counter > 0 { w.varint(10, counter) }
        }
    }

    /// ERROR_INFO (cmd 6): tell the glasses something went wrong.
    /// `{1: 6, 2: magic, 3: {1 errorCode, 2 errorMessage, 3 errorIndex}}`.
    public static func errorInfo(magic: UInt64, message: String, index: UInt64 = 0, error: UInt64 = 7) -> [UInt8] {
        package(cmd: cmdErrorInfo, magic: magic, field: 3) { w in
            w.varint(1, error)
            w.string(2, text(message))
            if index > 0 { w.varint(3, index) }
        }
    }

    /// LOCATION_NONE (cmd 3): answer to MENU_STARTUP when there are no favorites. Layout
    /// inferred from the other simple commands.
    public static func locationNone(magic: UInt64) -> [UInt8] {
        package(cmd: cmdLocationNone, magic: magic, field: 3) { _ in }
    }

    /// LOCATION_LIST (cmd 2): favorites, the answer to MENU_STARTUP.
    /// `{1: 2, 2: magic, 4: {1 listNum, 2 locationName (repeated), 3 iconIndex (repeated)}}`.
    public static func locationList(magic: UInt64, names: [String], icons: [UInt64] = []) -> [UInt8] {
        package(cmd: cmdLocationList, magic: magic, field: 4) { w in
            w.varint(1, names.count)
            for name in names { w.string(2, text(name)) }
            if !icons.isEmpty {
                var packed = ProtoWriter()
                for icon in icons { packed.varint(1, icon) }
                w.bytes(3, packed.bytes)
            }
        }
    }

    /// MINI_MAP (cmd 8): the small map next to the arrow. The app's schema differs from the
    /// max map: `{1: 8, 2: magic, 6: {1 mapSize, 2 compressMode, 3 mapRawData, 4 errorCode,
    /// 5 rotationAngle, 6 miniMapBorderEn, 7 mapSessionId, 8 mapFragmentIndex,
    /// 9 mapFragmentPacketSize}}`. A mini map ≤ 8192 bytes is sent as ONE message without the
    /// session fields; bigger maps fragment with 7/8/9. `rotationAngle` (heading mod 360) and
    /// `miniMapBorderEn` (0 in a live session) are always written — the app's factory does.
    public static func miniMapFragment(
        magic: UInt64, size: UInt64, compressMode: UInt64, data: [UInt8],
        rotationAngle: UInt64 = 0, border: UInt64 = 0,
        sessionID: UInt64? = nil, index: UInt64? = nil, packetSize: UInt64? = nil
    ) -> [UInt8] {
        package(cmd: cmdMiniMap, magic: magic, field: 6) { w in
            w.varint(1, size)
            w.varint(2, compressMode)
            w.bytes(3, data)
            w.varint(5, rotationAngle)
            w.varint(6, border)
            if let sessionID, let index, let packetSize {
                w.varint(7, sessionID)
                w.varint(8, index)
                w.varint(9, packetSize)
            }
        }
    }

    /// MAX_MAP (cmd 9): the full-screen map, one fragment per message.
    /// `{1: 9, 2: magic, 7: {1 mapSessionId, 2 mapTotalSize, 3 compressMode,
    /// 4 mapFragmentIndex, 5 mapFragmentPacketSize, 6 mapRawData, 7 errorCode}}`.
    /// All fragments of one frame share the session id and the total size; `index` runs from 0.
    /// `compressMode`: 4 = LZ4 block, 0 = raw BMP (the app never sends anything else).
    public static func maxMapFragment(
        magic: UInt64, sessionID: UInt64, totalSize: UInt64,
        compressMode: UInt64 = 0, index: UInt64, packetSize: UInt64, data: [UInt8]
    ) -> [UInt8] {
        package(cmd: cmdMaxMap, magic: magic, field: 7) { w in
            w.varint(1, sessionID)
            w.varint(2, totalSize)
            w.varint(3, compressMode)
            w.varint(4, index)
            w.varint(5, packetSize)
            w.bytes(6, data)
        }
    }

    /// SWITCH_TRANSPORT_RSP (cmd 19): answer to SWITCH_TRANSPORT_REQ (18).
    /// `{1: 19, 2: magic, 12: {1 status}}`.
    public static func switchTransportResponse(magic: UInt64, status: UInt64 = 0) -> [UInt8] {
        package(cmd: cmdSwitchTransportRsp, magic: magic, field: 12) { w in
            if status > 0 { w.varint(1, status) }
        }
    }

    // MARK: Glasses → app

    /// Reads the error code out of a reply: 0 = success. Replies echo the request's cmd and
    /// magic, with the error in field 3 (or field 9 inside field 5 for BASIC_INFO).
    public static func replyError(_ payload: [UInt8]) -> UInt64 {
        let f = ProtoReader.varintFields(payload)
        if f[1] == cmdBasicInfo {
            let sub = ProtoReader.message(payload, 5) ?? []
            return ProtoReader.varintFields(sub)[9] ?? 0
        }
        if f[1] == cmdErrorInfo {
            let sub = ProtoReader.message(payload, 3) ?? []
            return ProtoReader.varintFields(sub)[1] ?? 0
        }
        return f[3] ?? 0
    }

    /// The error code in a map reply: field 4 inside field 6 for mini maps, field 7 inside
    /// field 7 for max maps. Absent counts as success (0). The firmware answers every fragment;
    /// a dropped fragment gets no answer at all (see `eErrorCode` in lotti-recon).
    public static func mapReplyError(_ payload: [UInt8], mini: Bool) -> UInt64 {
        let sub = ProtoReader.message(payload, mini ? 6 : 7) ?? []
        return ProtoReader.varintFields(sub)[mini ? 4 : 7] ?? 0
    }

    // MARK: Helpers

    /// `{1: cmd, 2: magic, field: sub}`. The cmd is always written, even 0 (heartbeat).
    private static func package(
        cmd: UInt64, magic: UInt64, field: Int, _ build: (inout ProtoWriter) -> Void
    ) -> [UInt8] {
        var w = ProtoWriter()
        w.varint(1, cmd)
        w.varint(2, magic)
        w.message(field, build)
        return w.bytes
    }

    /// A text field on the glasses: cut to ≤60 UTF-8 bytes on a character boundary; nil or
    /// blank becomes "--".
    static func text(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return "--" }
        var bytes = Array(value.utf8)
        if bytes.count <= textMaxBytes { return value }
        bytes.removeSubrange(textMaxBytes...)
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(bytes: bytes, encoding: .utf8)!
    }
}

/// The arrow the firmware's navigation screen draws, from the Even app's
/// `NavigateRoadSignType` → `directionSignIndex` jump table.
public enum NavigateDirectionSign: UInt64, Equatable, Sendable {
    case departure = 1
    case straight = 2
    case turnRight = 3
    case turnLeft = 4
    case slightRight = 5
    case slightLeft = 6
    case sharpRight = 7
    case sharpLeft = 8
    case uTurnClockwise = 9
    case uTurnCounterclockwise = 10
    case roundaboutSharpRightCW = 11
    case roundaboutRightCCW = 12
    case roundaboutRightCW = 13
    case roundaboutSlightRightCCW = 14
    case roundaboutSlightRightCW = 15
    case roundaboutStraightCCW = 16
    case roundaboutStraightCW = 17
    case roundaboutSlightLeftCCW = 18
    case roundaboutSlightLeftCW = 19
    case roundaboutLeftCCW = 20
    case roundaboutLeftCW = 21
    case roundaboutSharpLeftCCW = 22
    case roundaboutSharpLeftCW = 23
    case roundaboutUTurnCCW = 24
    case roundaboutUTurnCW = 25
    case roundaboutCCW = 26
    case roundaboutCW = 27
    case roundaboutExitCCW = 28
    case roundaboutExitCW = 29
    case mergeRight = 30
    case mergeLeft = 31
    case forkRight = 32
    case forkLeft = 33
    case mergeUnspecified = 34
    case roundaboutSharpRightCCW = 35
}

/// Something the glasses report on the navigation service (sid 0x08) on their own.
public enum G2NavigationEvent: Equatable, Sendable {
    /// The user opened Navigate from the glasses' menu; the app answers with a location list
    /// or `LOCATION_NONE`, echoing `magic`.
    case menuStartup(magic: UInt64)
    /// The user picked a favorite: its name, index, the requested transport method, and the
    /// request's magic (for the reply).
    case locationSelected(location: String, index: UInt64, method: UInt64, magic: UInt64)
    /// The user left the navigation screen.
    case notifyExit
    /// The user switched between the mini map and the other views (1..3).
    case viewChanged(view: UInt64)
    /// The glasses' compass turned (value not documented).
    case compassChanged(value: UInt64)
    case compassCalibrateStart
    case compassCalibrateDone
    /// The user asked to switch transport (walking/cycling); reply with
    /// `SWITCH_TRANSPORT_RSP` echoing `magic`.
    case switchTransportReq(method: UInt64, magic: UInt64)
    /// The glasses asked to end the session.
    case endSessionReq
    /// Anything else on this service (a reply echo): log it, ignore it.
    case other(cmd: UInt64)

    public static func decode(_ payload: [UInt8]) -> G2NavigationEvent {
        let f = ProtoReader.varintFields(payload)
        let magic = f[2] ?? 0
        let cmd = f[1] ?? 0
        switch cmd {
        case G2Navigation.cmdMenuStartup:
            return .menuStartup(magic: magic)
        case G2Navigation.cmdLocationSelected:
            let sub = ProtoReader.message(payload, 8) ?? []
            let s = ProtoReader.varintFields(sub)
            return .locationSelected(
                location: ProtoReader.string(sub, 1) ?? "", index: s[3] ?? 0, method: s[4] ?? 0, magic: magic)
        case G2Navigation.cmdNotifyExit:
            return .notifyExit
        case G2Navigation.cmdViewChanged:
            let sub = ProtoReader.message(payload, 9) ?? []
            return .viewChanged(view: ProtoReader.varintFields(sub)[1] ?? 0)
        case G2Navigation.cmdCompassChanged:
            let sub = ProtoReader.message(payload, 10) ?? []
            return .compassChanged(value: ProtoReader.varintFields(sub)[1] ?? 0)
        case G2Navigation.cmdCompassCalibrateStart:
            return .compassCalibrateStart
        case G2Navigation.cmdCompassCalibrateDone:
            return .compassCalibrateDone
        case G2Navigation.cmdSwitchTransportReq:
            let sub = ProtoReader.message(payload, 11) ?? []
            return .switchTransportReq(method: ProtoReader.varintFields(sub)[1] ?? 0, magic: magic)
        case G2Navigation.cmdEndSessionReq:
            return .endSessionReq
        default:
            return .other(cmd: cmd)
        }
    }

    /// True when the user left navigation on the glasses (cmd 13 or 20).
    public var isExit: Bool {
        switch self {
        case .notifyExit, .endSessionReq: true
        default: false
        }
    }
}
