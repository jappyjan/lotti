import Foundation
import Testing
@testable import LottiKit

/// An arm already connected to the phone at system level (iOS keeps a bonded arm connected,
/// e.g. for notifications): refused by default, passable only with the per-attempt acceptance.
/// The fake temple uses the same check as `G2Link.openExclusiveArm`. No glasses, no Bluetooth.
@MainActor
@Suite(.serialized)
struct WispSystemConnectionTests {
    @Test func checkRefusesASystemConnectionByDefault() {
        #expect(throws: G2ExclusiveArmError.connectedElsewhere(.left)) {
            try G2ExclusiveArmError.checkSystemConnection(.left, systemConnected: true, acceptSystemConnection: false)
        }
    }

    @Test func checkPassesAnAcceptedSystemConnection() throws {
        #expect(try G2ExclusiveArmError.checkSystemConnection(.left, systemConnected: true, acceptSystemConnection: true))
    }

    @Test func checkIgnoresTheFlagWithoutASystemConnection() throws {
        #expect(try !G2ExclusiveArmError.checkSystemConnection(.right, systemConnected: false, acceptSystemConnection: false))
        #expect(try !G2ExclusiveArmError.checkSystemConnection(.right, systemConnected: false, acceptSystemConnection: true))
    }

    @Test func errorMentionsIOS() {
        #expect(G2ExclusiveArmError.connectedElsewhere(.left).errorDescription?.contains("iOS") == true)
    }

    private func fake() throws -> WispFakeTempleAccess {
        try WispFakeTempleAccess(source: WispOtaEngineTests.source("wisp-ota-fake-temple.js"), stockVersion: "2.2.6.10")
    }

    @Test func fakeTempleRefusesBydefaultAndAcceptsWithTheFlag() async throws {
        let access = try fake()
        access.systemConnected = [.left]
        await #expect(throws: G2ExclusiveArmError.connectedElsewhere(.left)) { _ = try await access.open(.left) }
        await #expect(throws: G2ExclusiveArmError.connectedElsewhere(.left)) {
            _ = try await access.open(.left, acceptSystemConnection: false)
        }
        let session = try await access.open(.left, acceptSystemConnection: true)
        #expect(access.openArms == [.left])
        session.close()
        // The other temple isn't system-connected: opens without the flag.
        try await access.open(.right).close()
        #expect(access.openAttempts.map(\.acceptSystemConnection) == [false, false, true, false])
    }

    // MARK: The fake behaves like the real glasses (hardware.md, 2026-11-06)

    @Test func fakeLeftArmIgnoresTheStatusRead() async throws {
        let access = try fake()
        let left = try await access.open(.left)
        await #expect(throws: GlassesLinkError.self) { _ = try await left.readStatus() }
        left.close()
    }

    @Test func fakeRightArmReportsBothTemples() async throws {
        let access = try fake()
        access.battery = 94
        let right = try await access.open(.right)
        let rb = try await right.readStatus()
        right.close()
        #expect(rb.leftVersion == "2.2.6.10" && rb.rightVersion == "2.2.6.10" && rb.battery == 94)
        #expect(access.events == ["open right", "read right", "close right"])
    }

    @Test func fakeOpensOneArmAtATimeLikeG2Link() async throws {
        let access = try fake()
        let right = try await access.open(.right)
        await #expect(throws: G2ExclusiveArmError.alreadyOpen) { _ = try await access.open(.left) }
        #expect(access.openArms == [.right])
        right.close()
        let left = try await access.open(.left)
        #expect(access.openArms == [.left])
        left.close()
        #expect(access.openArms.isEmpty)
    }

    @Test func acceptanceDoesNotPassTheSessionBlocker() async throws {
        let access = try fake()
        access.systemConnected = [.left]
        access.blocker = "A Lotti glasses session is active."
        await #expect(throws: WispSessionError.blocked("A Lotti glasses session is active.")) {
            _ = try await access.open(.left, acceptSystemConnection: true)
        }
    }
}
