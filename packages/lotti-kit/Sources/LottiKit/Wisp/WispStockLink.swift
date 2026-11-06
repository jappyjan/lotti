import Foundation

/// Which characteristic a stock OTA packet goes to / came from (wisp-ota `StockChannel`):
/// `ota` = OTA write `…0001` / notify `…0002` (service `…1001`), `control` = `…5401` / `…5402`.
public enum WispChannel: String, Sendable {
    case ota, control
}

/// The Swift side of wisp-ota's `StockLink` seam: a connected link to exactly one temple. The
/// stock OTA sender itself runs in JavaScriptCore (`WispOtaEngine`); this only moves packets.
///
/// Guarantees before a transfer starts (wisp-ota README "Preconditions"): connected to `temple`,
/// services discovered, notifications on `…0002` and `…5402`, no other traffic on this arm.
@MainActor
public protocol WispStockLink: AnyObject {
    var temple: G2Side { get }
    /// Write without response; returns when the packet is handed to the radio, throws on a dead link.
    func write(_ channel: WispChannel, _ packet: [UInt8]) async throws
    /// Set by the engine for the length of one transfer.
    var onPacket: ((WispChannel, [UInt8]) -> Void)? { get set }
    /// Called at most once when the link drops.
    var onDisconnect: ((String) -> Void)? { get set }
}

/// One temple opened exclusively for the Wisp update screen: the stock link plus the read-only
/// status query (sid 0x09 READ) and closing it again.
@MainActor
public protocol WispTempleSession: WispStockLink {
    /// sid 0x80 auth + sid 0x09 READ_BASIC on this arm. Throws when the arm does not answer.
    func readStatus() async throws -> G2Settings.Readback
    func close()
}

/// Where the screen gets a temple session from: the real `G2Link`, or a fake.
@MainActor
public protocol WispTempleAccess: AnyObject {
    /// Why a session can't be opened right now (e.g. a Lotti glasses session is running), or nil.
    var blocker: String? { get }
    /// `acceptSystemConnection`: the user confirmed, for this one attempt, that the arm's existing
    /// connection to the phone is iOS's own (see `G2ExclusiveArmError.connectedElsewhere`).
    func open(_ side: G2Side, acceptSystemConnection: Bool) async throws -> any WispTempleSession
}

extension WispTempleAccess {
    /// Opens without accepting a system connection.
    public func open(_ side: G2Side) async throws -> any WispTempleSession {
        try await open(side, acceptSystemConnection: false)
    }
}
