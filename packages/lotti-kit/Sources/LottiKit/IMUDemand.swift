import Foundation

/// One gravity sample from the glasses' IMU: gravity-normalised, so |v| is about 1 at rest.
public struct IMUSample: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Reference-counted demand for the glasses' IMU. Head-up detection and the phone's mascot can
/// need the feed at the same time; the link only knows "on" or "off", so everyone who needs it
/// acquires a token here. The link is switched on by the first token and off after the last one is
/// released, so one user turning off never cuts the other's feed, and a second user adds no
/// traffic on the link.
@MainActor
public final class IMUDemand {
    public struct Token: Hashable, Sendable {
        fileprivate let id: UInt64
        public let owner: String
    }

    private let link: any GlassesLink
    private var holders: Set<Token> = []
    private var nextID: UInt64 = 0
    /// What the link was last told.
    private var applied = false
    private var pumping = false

    public init(link: any GlassesLink) {
        self.link = link
    }

    /// Whether at least one token is held.
    public var isActive: Bool { !holders.isEmpty }
    public var holderCount: Int { holders.count }
    public func isHeld(by owner: String) -> Bool { holders.contains { $0.owner == owner } }

    /// Ask for the IMU feed. Keep the token and `release` it when done.
    public func acquire(_ owner: String) async -> Token {
        nextID += 1
        let token = Token(id: nextID, owner: owner)
        holders.insert(token)
        await pump()
        return token
    }

    /// Give a token back. Releasing twice is harmless.
    public func release(_ token: Token) async {
        guard holders.remove(token) != nil else { return }
        await pump()
    }

    /// Tell the link again that the feed is wanted, e.g. after a reconnect (the glasses forget it).
    public func reassert() async {
        await pump()
        if isActive, !pumping { await link.setHeadTracking(true) }
    }

    /// Brings the link in line with the tokens; calls made while a link call is in flight are
    /// picked up by the running loop, so the link sees changes in order and only real ones.
    private func pump() async {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        while applied != isActive {
            applied = isActive
            await link.setHeadTracking(applied)
        }
    }
}
