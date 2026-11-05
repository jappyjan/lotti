/// Something the glasses report on their own, without a request: a gesture, or a status change.
public enum G2Event: Equatable, Sendable {
    case input(InputEvent)
    /// One IMU sample (only while IMU reporting is on): gravity-normalised, so |v| ≈ 1 at rest
    /// (MentraOS). Axis orientation on the head isn't confirmed yet.
    case imu(x: Float, y: Float, z: Float)
    /// Wear status: the glasses are on a head (true) or not (false). Only ever an answer to a
    /// question (`G2Payload.wearStatusQuery`), ours or the Even app's; see `G2Events.wearReply`.
    case wear(Bool)
    /// Anything else worth logging (app lifecycle, state change, ring status), in words.
    case info(String)
}

/// Decodes the glasses' async messages. Layouts from the Even app's protobuf schemas as decoded
/// by g2-kit (`ble/events.ts`, `ble/docs/events.md`) and even-g2-protocol
/// (`widgets/evenhub.py` `decode_device_event`, `device/device.py`).
///
/// Gestures arrive on EvenHub (sid 0xE0), Cmd 2 OS_NOTIFY_EVENT_TO_APP, field 13 SendDeviceEvent:
///
///     1 List_ItemEvent {1 containerID, 2 name, 3 item name, 4 item index, 5 eventType}
///     2 Text_ItemEvent {1 containerID, 2 name, 3 eventType}
///     3 Sys_ItemEvent  {1 eventType, 2 eventSource, 3 IMU, 4 exit reason, 5 widget, 6 session}
///
/// eventType: 0 click, 1 scroll top, 2 scroll bottom, 3 double click, 4/5 foreground enter/exit,
/// 6 abnormal exit, 7 system exit, 8 IMU, 9 long press, 10 long press release.
/// eventSource: 1 right touchpad, 2 ring, 3 left touchpad. Zero values are left out on the wire,
/// so a missing eventType is a click.
public enum G2Events {
    /// sid 0x0D: device state changes (dashboard open/close, our page active again). Not wear:
    /// the glasses send nothing here when they are put on or taken off (wear capture, 2026-11-05).
    public static let stateService: UInt8 = 0x0D
    /// The sid 0x0D payload saying EvenHub (our page) is the active app again (S1 capture).
    public static let evenHubActive: [UInt8] = [0x08, 0x01, 0x1A, 0x03, 0x08, 0xE0, 0x01]
    /// Sent when the firmware's own dashboard opens or closes, which shuts our page down (MentraOS).
    public static let dashboardToggled: [UInt8] = [0x08, 0x01, 0x1A, 0x00]
    /// Device config Cmd 6, RING_CONNECT_INFO: the ring link between glasses and ring.
    public static let ringConnectInfo: UInt64 = 6

    public static func decode(_ message: G2Message) -> G2Event? {
        let p = message.payload
        switch message.sid {
        case G2Service.evenHub:
            guard message.command == 2, let event = ProtoReader.message(p, 13) else { return nil }
            return deviceEvent(event)
        case stateService:
            return .info("state change \(hex(p))")
        case G2Service.onboarding where message.command == wearQueryCommand:
            return wearReply(p).map(G2Event.wear)
        case G2Service.deviceConfig where message.command == ringConnectInfo:
            return .info(ringInfo(ProtoReader.message(p, 5) ?? []))
        default:
            return nil
        }
    }

    /// Wear status from a sid 0x10 reply, or nil if it isn't one.
    ///
    /// The firmware never pushes wear changes: during a marked on/off capture (2026-11-05,
    /// firmware 2.4.0.24, wear detection on) nothing at all arrived when the glasses went on or
    /// off. It only answers the onboarding question `{1: 3, 2: magic, 5: {1: GLS_WEAR_STATUS(1)}}`
    /// with `{1: 3, 2: magic, 5: {1: 1, 2: 1 worn / 0 not worn}}` (even-g2-protocol
    /// `decode_onboarding`). Zero values are left out on the wire, so a missing field 2 means
    /// "not worn".
    public static func wearReply(_ payload: [UInt8]) -> Bool? {
        guard ProtoReader.varintFields(payload)[1] == wearQueryCommand,
              let event = ProtoReader.message(payload, 5) else { return nil }
        let f = ProtoReader.varintFields(event)
        guard f[1] == wearStatusEvent else { return nil }
        return (f[2] ?? 0) != 0
    }

    /// Onboarding Cmd 3, EVENT: carries the wear-status question and its answer.
    static let wearQueryCommand: UInt64 = 3
    /// eOnboardingEvent GLS_WEAR_STATUS.
    static let wearStatusEvent: UInt64 = 1

    private static func deviceEvent(_ event: [UInt8]) -> G2Event? {
        if let list = ProtoReader.message(event, 1) {
            let f = ProtoReader.varintFields(list)
            return gesture(f[5] ?? 0, source: .unknown, container: ProtoReader.string(list, 2))
        }
        if let text = ProtoReader.message(event, 2) {
            let f = ProtoReader.varintFields(text)
            return gesture(f[3] ?? 0, source: .unknown, container: ProtoReader.string(text, 2))
        }
        if let sys = ProtoReader.message(event, 3) {
            let f = ProtoReader.varintFields(sys)
            // IMU_Report_Data {1 x, 2 y, 3 z}, 32-bit floats (MentraOS `parseImuReportData`).
            if f[1] == 8, let data = ProtoReader.message(sys, 3) {
                let v = ProtoReader.floatFields(data)
                return .imu(x: v[1] ?? 0, y: v[2] ?? 0, z: v[3] ?? 0)
            }
            let source: InputEvent.Source = switch f[2] ?? 0 {
            case 1: .rightTouchpad
            case 2: .ring
            case 3: .leftTouchpad
            default: .unknown
            }
            return gesture(f[1] ?? 0, source: source, container: nil, exitReason: f[4])
        }
        return nil
    }

    private static func gesture(
        _ type: UInt64, source: InputEvent.Source, container: String?, exitReason: UInt64? = nil
    ) -> G2Event {
        let g: InputEvent.Gesture? = switch type {
        case 0: .tap
        case 1: .scrollUp
        case 2: .scrollDown
        case 3: .doubleTap
        case 9: .longPress
        case 10: .longPressEnd
        default: nil
        }
        if let g { return .input(InputEvent(g, from: source)) }
        let name = switch type {
        case 4: "foreground enter"
        case 5: "foreground exit"
        case 6: "abnormal exit"
        case 7: "system exit"
        case 8: "IMU report"
        default: "event \(type)"
        }
        var text = "app event: \(name)"
        if let container { text += " on \(container)" }
        if let exitReason, exitReason != 0 { text += ", reason \(exitReason)" }
        return .info(text)
    }

    /// RingInfo {1 connect, 2 ring MAC, 3 ring name, 4 connection status, 5 result}. The status
    /// codes aren't documented; MentraOS treats 22 as "ring disconnected".
    private static func ringInfo(_ info: [UInt8]) -> String {
        let f = ProtoReader.varintFields(info)
        var parts = ["connect \(f[1] ?? 0)", "status \(f[4] ?? 0)"]
        if let mac = ProtoReader.message(info, 2) {
            parts.append("mac " + mac.reversed().map { String(format: "%02X", $0) }.joined(separator: ":"))
        }
        if let name = ProtoReader.string(info, 3), !name.isEmpty { parts.append("name \(name)") }
        if let result = f[5], result != 0 { parts.append("result \(result)") }
        return "ring info: " + parts.joined(separator: ", ") + (info.isEmpty ? "" : " (\(hex(info)))")
    }
}
