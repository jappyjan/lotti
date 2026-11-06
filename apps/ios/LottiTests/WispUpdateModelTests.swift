import Foundation
import LottiKit
import Testing
@testable import Lotti

/// The Wisp update screen's model with wisp-ota's fake stock temple (Simulator build resource)
/// and synthetic stock bundles: no glasses, no Bluetooth, no Even firmware, no network.
@MainActor
@Suite(.serialized)
struct WispUpdateModelTests {
    static let timing = WispOtaEngine.Timing(controlAckTimeoutMs: 150, blockAckTimeoutMs: 150, notifyTimeoutMs: 150,
                                             heartbeatIntervalMs: 1000, restartSettleMs: 5)

    let model: WispUpdateModel
    let fake: WispFakeTempleAccess
    let stock: [UInt8]
    let defaults: UserDefaults
    let directory: URL

    init() throws {
        let engine = try WispOtaEngine(bundle: .main)
        fake = try WispFakeTempleAccess(bundle: .main, stockVersion: "2.2.6.10", battery: 95)
        fake.restartDelayMs = 20
        stock = fake.syntheticStock(version: "2.2.6.10")
        let release = WispOtaEngine.StockRelease(
            version: "2.2.6.10", md5: "synthetic", size: stock.count, sha256: WispStockStore.sha256(stock),
            mainAppEnd: 0, url: "https://example.invalid/g2-2.2.6.10.bin")
        // The real main-app end of the synthetic bundle, as the JS check computes it.
        let appEnd = Self.mainAppEnd(engine: engine, stock: stock, release: release)
        var pinned = release
        pinned.mainAppEnd = appEnd
        directory = FileManager.default.temporaryDirectory.appending(path: "wisp-tests-\(UUID().uuidString)")
        let bytes = stock
        let store = try WispStockStore(engine: engine, directory: directory.appending(path: "stock"), releases: [pinned],
                                       requirePinned: false, fetch: { _ in Data(bytes) })
        defaults = UserDefaults(suiteName: "wisp-tests-\(UUID().uuidString)")!
        model = WispUpdateModel(engine: engine, store: store, log: WispLog(url: directory.appending(path: "log.txt")),
                                access: fake, defaults: defaults, timing: Self.timing)
    }

    private static func mainAppEnd(engine: WispOtaEngine, stock: [UInt8], release: WispOtaEngine.StockRelease) -> Int {
        // checkStock reports the mismatch with the computed end; parse it from the message.
        do {
            _ = try engine.checkStock(release, bytes: stock, sha256: release.sha256)
            return release.mainAppEnd
        } catch {
            let text = error.localizedDescription
            guard let range = text.range(of: "main app end 0x") else { return 0 }
            let hex = text[range.upperBound...].prefix { $0.isHexDigit }
            return Int(hex, radix: 16) ?? 0
        }
    }

    /// Steps 1–3 for rung 1, then the per-send confirmations.
    private func readyRung1() async {
        await model.readVersion()
        await model.fetchStock()
        await model.prepareRung1()
        model.evenAppAcknowledged = true
        model.typedTemple = "left"
    }

    private func waitForResult() async {
        for _ in 0..<300 where model.final == nil { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func gate(_ id: String) -> WispUpdateModel.Gate? { model.gates.first { $0.id == id } }

    /// OTA packets the left temple has received (0 when it was never opened).
    private var leftPackets: Int { fake.state(.left)?.packetsWritten ?? 0 }

    /// The fake's arm events since `start`.
    private func events(since start: Int) -> [String] { Array(fake.events.dropFirst(start)) }

    @Test func developerSettingIsOffByDefaultAndLeftIsTheDefaultTemple() {
        UserDefaults.standard.removeObject(forKey: Settings.wispUpdateKey)
        #expect(Settings.wispUpdateEnabled == false)
        #expect(model.temple == .left)
    }

    @Test func readsVersionAndBatteryReadOnly() async {
        await model.readVersion()
        #expect(model.readback?.leftVersion == "2.2.6.10")
        #expect(model.readback?.battery == 95)
        #expect(model.stockVersion == "2.2.6.10")
        #expect(model.rung1Version == "2.2.6.19")
        #expect(leftPackets == 0)  // reading sends no OTA packet
        #expect(fake.state(.right)?.packetsWritten == 0)
    }

    // MARK: Status via the right arm (the left arm ignores sid 0x09)

    @Test func readGoesThroughTheRightArmOnly() async {
        await model.readVersion()
        #expect(fake.events == ["open right", "read right", "close right"])
        #expect(fake.openAttempts.map(\.side) == [.right])
        #expect(fake.openArms.isEmpty)
        #expect(logText.contains("read (status): sending sid 0x09 READ_BASIC to the right temple"))
        #expect(logText.contains("read (status): the right temple closed"))
        #expect(gate("battery")?.title == "Battery (as reported by the right temple) above 80 %")
    }

    @Test func readFailsWhenTheRightArmDoesNotAnswer() async {
        fake.statusArms = [.left]  // only the left would answer: the screen never asks it
        await model.readVersion()
        #expect(model.readback == nil && model.error != nil)
        #expect(fake.events == ["open right", "read right", "close right"])
        #expect(fake.openArms.isEmpty)
    }

    @Test func versionIsPickedPerTarget() async throws {
        // Put a different image on the left temple only.
        let other = try model.engine.prepareRung1(stock: stock, version: "2.2.6.18")
        fake.register(crc32c: other.info.mainCrc32c, version: "2.2.6.18")
        let link = try await fake.open(.left)
        let outcome: WispOtaEngine.Outcome = await withCheckedContinuation { c in
            _ = try? model.engine.startTransfer(temple: .left, bundle: other.bytes, link: link, timing: Self.timing,
                                                onProgress: { _ in }, onFinished: { c.resume(returning: $0) })
        }
        link.close()
        guard case .success = outcome else { Issue.record("setup: \(outcome)"); return }
        try await Task.sleep(for: .milliseconds(150))

        await model.readVersion()
        #expect(model.installedVersion == "2.2.6.18")
        model.temple = .right
        await model.readVersion()
        #expect(model.installedVersion == "2.2.6.10")
        #expect(fake.openAttempts.dropFirst().allSatisfy { $0.side == .right })  // both reads via right
    }

    @Test func leftSendReReadsViaRightThenOpensLeftNeverBoth() async {
        await readyRung1()
        #expect(model.canSend)
        let start = fake.events.count
        await model.send()
        #expect(model.isSending, "\(String(describing: model.error))")
        #expect(events(since: start) == ["open right", "read right", "close right", "open left"])
        #expect(fake.openArms == [.left])
        let log = logText
        for line in ["send (status): opening the right temple exclusively", "send (status): sending sid 0x09 READ_BASIC",
                     "send (status): the right temple closed", "send: re-read via the right temple: left version 2.2.6.10",
                     "send: opening the left temple exclusively", "send: the left temple is open", "send: transfer started"] {
            #expect(log.contains(line), "\(line)")
        }
        await waitForResult()
        guard case .success = model.final else { Issue.record("\(String(describing: model.final))"); return }
        #expect(fake.state(.right)?.packetsWritten == 0)  // nothing ever went to the right temple
        #expect(!fake.events.contains { $0.hasPrefix("refused") })  // never two arms at once
    }

    @Test func leftSendRefusedWhenTheRightReReadFails() async {
        await readyRung1()
        fake.statusArms = []
        let start = fake.events.count
        await model.send()
        #expect(model.error?.contains("re-read via the right temple failed") == true)
        #expect(events(since: start) == ["open right", "read right", "close right"])  // left never opened
        #expect(leftPackets == 0 && model.final == nil)
    }

    @Test func leftSendRefusedOnTheRightReReadsBatteryBeforeOpeningLeft() async {
        await readyRung1()
        fake.battery = 80
        let start = fake.events.count
        await model.send()
        #expect(model.error?.contains("as reported by the right temple") == true)
        #expect(!events(since: start).contains("open left"))
        #expect(leftPackets == 0)
    }

    @Test func rightSendReadsAndSendsOnTheRightArm() async {
        model.temple = .right
        await model.readVersion()
        await model.fetchStock()
        await model.prepareRung1()
        model.evenAppAcknowledged = true
        model.typedTemple = "right"
        #expect(model.canSend, "\(model.gates.filter { !$0.ok })")
        let start = fake.events.count
        await model.send()
        #expect(model.isSending)
        #expect(events(since: start) == ["open right", "read right"])  // same connection for the send
        await waitForResult()
        guard case .success = model.final else { Issue.record("\(String(describing: model.final))"); return }
        #expect(!fake.events.contains { $0.contains("left") })
    }

    @Test func fullRung1SendAndRoundTripBack() async throws {
        await readyRung1()
        let info = try #require(model.prepared?.info)
        #expect(info.sendable)
        fake.register(crc32c: info.mainCrc32c, version: "2.2.6.19")
        #expect(model.canSend, "\(model.gates.filter { !$0.ok })")
        await model.send()
        #expect(model.typedTemple.isEmpty && !model.evenAppAcknowledged)  // used up
        await waitForResult()
        guard case .success = model.final else { Issue.record("\(String(describing: model.final))"); return }
        #expect(model.lastRepack?.version == "2.2.6.19")

        try await Task.sleep(for: .milliseconds(150))
        await model.readVersion()
        #expect(model.installedVersion == "2.2.6.19")
        #expect(model.stockVersion == "2.2.6.10")  // known as the base of the last repack
        await model.fetchStock()
        await model.prepareStockBack()
        let back = try #require(model.prepared?.info)
        fake.register(crc32c: back.mainCrc32c, version: "2.2.6.10")
        model.evenAppAcknowledged = true
        model.typedTemple = "left"
        #expect(model.canSend, "\(model.gates.filter { !$0.ok })")
        await model.send()
        await waitForResult()
        guard case .success = model.final else { Issue.record("\(String(describing: model.final))"); return }
        try await Task.sleep(for: .milliseconds(150))
        await model.readVersion()
        #expect(model.installedVersion == "2.2.6.10")

        let log = model.log.entries.map(\.text).joined(separator: "\n")
        #expect(log.contains(WispStockStore.sha256(stock)))
        #expect(log.contains("result: SUCCESS"))
        #expect(log.contains("hardware log: |"))
    }

    @Test func refusesWithoutTheTypedTempleName() async {
        await readyRung1()
        for typed in ["", "Left", "LEFT", "both", "right", " left"] {
            model.typedTemple = typed
            #expect(!model.canSend, "\(typed)")
        }
        model.typedTemple = "Left"
        await model.send()
        #expect(model.final == nil && !model.isSending)
        #expect(leftPackets == 0)
    }

    @Test func refusesWithoutTheEvenAppAcknowledgement() async {
        await readyRung1()
        model.evenAppAcknowledged = false
        #expect(!model.canSend)
        #expect(gate("even")?.ok == false)
    }

    @Test func refusesAtOrBelow80PercentAndWhenUnreadable() async {
        for battery in [80, 12, nil] as [Int?] {
            fake.battery = battery
            await readyRung1()
            #expect(gate("battery")?.ok == false, "\(String(describing: battery))")
            #expect(!model.canSend)
        }
        fake.battery = 81
        await readyRung1()
        #expect(model.canSend)
    }

    @Test func batteryIsReadAgainRightBeforeSending() async {
        await readyRung1()
        #expect(model.canSend)
        fake.battery = 79  // drained since step 1
        await model.send()
        #expect(model.error?.contains("79 %") == true)
        #expect(model.final == nil)
        #expect(leftPackets == 0)
    }

    @Test func refusesWhenTheTempleDoesNotAnswer() async {
        await readyRung1()
        fake.answersStatus = false
        await model.send()
        #expect(model.error != nil)
        #expect(leftPackets == 0)
    }

    @Test func refusesWhileALottiSessionIsActive() async {
        await readyRung1()
        fake.blocker = "A Lotti glasses session is active."
        #expect(gate("session")?.ok == false)
        #expect(!model.canSend)
        fake.blocker = nil
        #expect(model.canSend)
    }

    @Test func refusesWithoutASendableGuardReport() async {
        await model.readVersion()
        await model.fetchStock()
        model.evenAppAcknowledged = true
        model.typedTemple = "left"
        #expect(gate("guards")?.ok == false)  // nothing prepared
        #expect(!model.canSend)
        model.rung1Version = "2.2.6.10"  // the repacker refuses an unchanged version
        await model.prepareRung1()
        #expect(model.prepared == nil && model.error != nil)
        #expect(!model.canSend)
    }

    @Test func refusesAVersionThatDoesNotMatchTheBundle() async throws {
        await readyRung1()
        // Pretend the temple now runs something else (e.g. the Even app updated it meanwhile).
        let other = try model.engine.prepareRung1(stock: stock, version: "2.2.6.18")
        fake.register(crc32c: other.info.mainCrc32c, version: "2.2.6.18")
        let link = try await fake.open(.left)
        let outcome: WispOtaEngine.Outcome = await withCheckedContinuation { c in
            _ = try? model.engine.startTransfer(temple: .left, bundle: other.bytes, link: link, timing: Self.timing,
                                                onProgress: { _ in }, onFinished: { c.resume(returning: $0) })
        }
        link.close()
        guard case .success = outcome else { Issue.record("setup: \(outcome)"); return }
        try await Task.sleep(for: .milliseconds(150))
        model.typedTemple = "left"
        model.evenAppAcknowledged = true
        let start = fake.events.count
        await model.send()  // the right arm's re-read says the left runs 2.2.6.18, repack is built from 2.2.6.10
        #expect(model.error?.contains("2.2.6.18") == true)
        #expect(model.final == nil)
        #expect(!events(since: start).contains("open left"))
    }

    @Test func switchingTempleClearsTheReadAndConfirmations() async {
        await readyRung1()
        model.temple = .right
        #expect(model.readback == nil)
        #expect(model.typedTemple.isEmpty && !model.evenAppAcknowledged)
        #expect(!model.canSend)
        #expect(gate("typed")?.title.contains("\"right\"") == true)
    }

    @Test func abortBeforeResultCheckIsFailedStockIntact() async throws {
        await readyRung1()
        await model.send()
        #expect(model.isSending)
        model.abort()
        await waitForResult()
        guard case .failedStockIntact(let text) = model.final else { Issue.record("\(String(describing: model.final))"); return }
        #expect(text.hasPrefix("aborted"))
        fake.reset(.left)
        #expect(fake.state(.left)?.installed.name == "stock 2.2.6.10")
    }

    @Test func lostVerdictShowsResultUnknown() async {
        fake.faults = ["dropVerdict": true]
        await readyRung1()
        await model.send()
        await waitForResult()
        guard case .resultUnknown = model.final else { Issue.record("\(String(describing: model.final))"); return }
    }

    @Test func linkDropShowsFailedStockIntact() async {
        fake.faults = ["disconnectAfterBlock": 1]
        await readyRung1()
        await model.send()
        await waitForResult()
        guard case .failedStockIntact = model.final else { Issue.record("\(String(describing: model.final))"); return }
    }

    @Test func stockIsCachedAfterTheFirstDownload() async {
        await model.readVersion()
        await model.fetchStock()
        #expect(model.stock?.fromCache == false)
        await model.fetchStock()
        #expect(model.stock?.fromCache == true)
        #expect(model.stock?.sha256 == WispStockStore.sha256(stock))
    }

    // MARK: System connection (iOS itself holds the arm)

    private var logText: String { model.log.entries.map(\.text).joined(separator: "\n") }

    @Test func systemConnectedArmIsRefusedByDefault() async {
        fake.systemConnected = [.right]
        await model.readVersion()
        #expect(model.readback == nil)
        #expect(model.error?.contains("iOS") == true)
        #expect(model.systemConnectionSeen)
        #expect(!model.systemConnectionAccepted)
        #expect(fake.openAttempts.map(\.acceptSystemConnection) == [false])
    }

    @Test func acceptedSystemConnectionPassesForOneAttemptOnly() async {
        fake.systemConnected = [.right]
        await model.readVersion()
        model.systemConnectionAccepted = true
        await model.readVersion()  // the retry
        #expect(model.readback?.leftVersion == "2.2.6.10")
        #expect(model.error == nil)
        #expect(!model.systemConnectionAccepted)  // used up by that attempt
        #expect(model.systemConnectionSeen)  // still shown, for the send
        #expect(fake.openAttempts.map(\.acceptSystemConnection) == [false, true])
        #expect(logText.contains("user ACCEPTED iOS's own connection to the right and left arms"))
        #expect(logText.contains("acceptance reset (used by this read)"))
        // Every log line carries its timestamp.
        let line = model.log.entries.first { $0.text.contains("user ACCEPTED") }?.text ?? ""
        #expect(line.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil)

        await model.readVersion()  // without a new acceptance: refused again
        #expect(model.error?.contains("iOS") == true)
        #expect(fake.openAttempts.last?.acceptSystemConnection == false)
    }

    @Test func templeChangeResetsTheAcceptance() async {
        fake.systemConnected = [.left, .right]
        await model.readVersion()
        model.systemConnectionAccepted = true
        model.temple = .right
        #expect(!model.systemConnectionAccepted && !model.systemConnectionSeen)
        #expect(logText.contains("acceptance reset (temple changed)"))
        await model.readVersion()
        #expect(model.readback == nil)
        #expect(fake.openAttempts.last?.side == .right && fake.openAttempts.last?.acceptSystemConnection == false)
    }

    @Test func closingTheScreenResetsTheAcceptance() async {
        fake.systemConnected = [.right]
        await model.readVersion()
        model.systemConnectionAccepted = true
        model.screenClosed()
        #expect(!model.systemConnectionAccepted)
        #expect(logText.contains("acceptance reset (screen closed)"))
    }

    /// Steps 1–3 with both arms system-connected, accepted for the read (the right arm's open).
    private func readySystemConnected() async {
        fake.systemConnected = [.left, .right]
        await model.readVersion()
        model.systemConnectionAccepted = true
        await model.readVersion()
        await model.fetchStock()
        await model.prepareRung1()
        model.evenAppAcknowledged = true
        model.typedTemple = "left"
    }

    @Test func sendNeedsTheAcceptanceAgainAndResetsIt() async {
        await readySystemConnected()
        #expect(model.readback != nil)
        #expect(model.canSend)  // the acceptance is not a gate…
        await model.send()  // …but the send's opens are refused without it
        #expect(model.error?.contains("re-read via the right temple failed") == true)
        #expect(!model.isSending && model.final == nil)
        #expect(leftPackets == 0)

        model.evenAppAcknowledged = true
        model.typedTemple = "left"
        model.systemConnectionAccepted = true
        let attempts = fake.openAttempts.count
        await model.send()
        #expect(model.isSending)
        #expect(!model.systemConnectionAccepted)  // reset after the send
        // One acceptance covers both opens of this send: the right re-read, then the left.
        #expect(fake.openAttempts.dropFirst(attempts).map(\.side) == [.right, .left])
        #expect(fake.openAttempts.dropFirst(attempts).allSatisfy { $0.acceptSystemConnection })
        #expect(logText.contains("covers the right and left arms"))
        #expect(logText.contains("acceptance reset (used by this send)"))
        await waitForResult()
        guard case .success = model.final else { Issue.record("\(String(describing: model.final))"); return }
    }

    @Test func acceptanceDoesNotReplaceAnySendGate() async {
        await readySystemConnected()
        // Each gate missing in turn, with the acceptance on: refused, nothing opened, nothing sent.
        let cases: [(String, () -> Void)] = [
            ("typed", { self.model.typedTemple = "" }),
            ("even", { self.model.evenAppAcknowledged = false }),
            ("session", { self.fake.blocker = "A Lotti glasses session is active." }),
        ]
        for (id, breakGate) in cases {
            model.evenAppAcknowledged = true
            model.typedTemple = "left"
            fake.blocker = nil
            breakGate()
            model.systemConnectionAccepted = true
            #expect(gate(id)?.ok == false, "\(id)")
            #expect(!model.canSend, "\(id)")
            let attempts = fake.openAttempts.count
            await model.send()
            #expect(fake.openAttempts.count == attempts, "\(id)")  // refused before opening
            #expect(!model.systemConnectionAccepted, "\(id)")  // a refused send resets it too
            #expect(!model.isSending)
        }
        fake.blocker = nil
        #expect(leftPackets == 0)
    }

    @Test func acceptanceDoesNotReplaceTheBatteryOrVersionReRead() async throws {
        await readySystemConnected()
        fake.battery = 79  // drained since step 1
        model.systemConnectionAccepted = true
        await model.send()
        #expect(model.error?.contains("79 %") == true)
        #expect(model.final == nil)
        #expect(leftPackets == 0)
        // Below 80 % the battery gate itself now fails.
        model.evenAppAcknowledged = true
        model.typedTemple = "left"
        #expect(gate("battery")?.ok == false && !model.canSend)
    }

    @Test func leftOnlySystemConnectionIsFoundAtTheSendsLeftOpen() async {
        fake.systemConnected = [.left]
        await readyRung1()  // the read only opens the right arm: no acceptance needed
        #expect(model.readback != nil && !model.systemConnectionSeen)
        let start = fake.events.count
        await model.send()
        #expect(model.error?.contains("could not open the left temple") == true)
        #expect(events(since: start) == ["open right", "read right", "close right",
                                         "refused left: \(G2ExclusiveArmError.connectedElsewhere(.left).localizedDescription)"])
        #expect(model.systemConnectedArms == [.left])
        #expect(leftPackets == 0 && !model.isSending)
    }
}
