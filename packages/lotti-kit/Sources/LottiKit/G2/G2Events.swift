/// Something the glasses report on their own, without a request: a gesture, or a status change.
public enum G2Event: Equatable, Sendable {
    case input(InputEvent)
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
    /// sid 0x0D: device state changes (wear detect, head-up, dashboard open/close).
    public static let stateService: UInt8 = 0x0D
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
        case G2Service.deviceConfig where message.command == ringConnectInfo:
            return .info(ringInfo(ProtoReader.message(p, 5) ?? []))
        default:
            return nil
        }
    }

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
        return "ring info: " + parts.joined(separator: ", ") + " (\(hex(info)))"
    }
}
