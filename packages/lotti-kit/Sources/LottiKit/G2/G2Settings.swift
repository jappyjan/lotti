import Foundation

/// Read-only settings query (sid 0x09 `G2SettingPackage`, cmd 2 READ). The Even app sends it on
/// every connect; the reply carries both temples' firmware versions and the battery level.
///
/// Source: even-g2-protocol `device/settings.py` (MIT), `build_read_settings` and
/// `READBACK_FIELDS`, golden frames from the official app's Bluetooth captures (CAPTURED):
/// request `{1: 2, 2: magic, 4: {1: READ_BASIC(1)}}`, reply `{1: 2, 2: magic, 4: {…}}` with
/// 5 left_version, 6 right_version (strings), 12 battery (%), 13 charging. Matches openCFW's
/// `pb_service_setting.c` ("full status: brightness, L/R version, head-up, battery/charging").
public enum G2Settings {
    public static let commandRead: UInt64 = 2
    public static let readBasic: UInt64 = 1

    /// `{1: READ(2), 2: magic, 4: {1: READ_BASIC(1)}}`.
    public static func readBasic(magic: UInt64) -> [UInt8] {
        var w = ProtoWriter()
        w.varint(1, Int(commandRead))
        w.varint(2, magic)
        w.message(4) { $0.varint(1, Int(readBasic)) }
        return w.bytes
    }

    /// What a READ reply (or an unprompted push) says.
    public struct Readback: Equatable, Sendable {
        public var leftVersion: String?
        public var rightVersion: String?
        /// Battery %, nil when the field is absent (proto3 would read that as 0).
        public var battery: Int?
        public var charging: Bool
        /// False for the glasses' own pushes (no request type echoed).
        public var isReply: Bool

        public init(leftVersion: String?, rightVersion: String?, battery: Int?, charging: Bool, isReply: Bool) {
            self.leftVersion = leftVersion
            self.rightVersion = rightVersion
            self.battery = battery
            self.charging = charging
            self.isReply = isReply
        }

        public func version(of side: G2Side) -> String? { side == .left ? leftVersion : rightVersion }
    }

    /// Decodes a sid 0x09 payload; nil unless it is a READ reply/push with a read-back.
    public static func decodeReadback(_ payload: [UInt8]) -> Readback? {
        let top = ProtoReader.varintFields(payload)
        guard top[1] == commandRead, let sub = ProtoReader.message(payload, 4) else { return nil }
        let fields = ProtoReader.varintFields(sub)
        let battery = fields[12].flatMap { $0 <= 100 ? Int($0) : nil }
        return Readback(
            leftVersion: ProtoReader.string(sub, 5), rightVersion: ProtoReader.string(sub, 6),
            battery: battery, charging: fields[13] == 1, isReply: fields[1] != nil)
    }
}
