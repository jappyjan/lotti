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
        #expect(try await session.readStatus().leftVersion == "2.2.6.10")
        session.close()
        // The other temple isn't system-connected: opens without the flag.
        try await access.open(.right).close()
        #expect(access.openAttempts.map(\.acceptSystemConnection) == [false, false, true, false])
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
