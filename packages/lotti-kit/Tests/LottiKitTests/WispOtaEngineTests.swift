import Foundation
import Testing
@testable import LottiKit

/// The stock OTA path as the app runs it: wisp-ota's sender in JavaScriptCore (`WispOtaEngine`),
/// a Swift `WispStockLink`, and wisp-ota's fake stock temple in a second JSContext. No glasses,
/// no Bluetooth; only synthetic bundles. Needs `pnpm nx run wisp-ota-jsc:bundle` (the Nx test
/// target depends on it).
@MainActor
@Suite(.serialized)
struct WispOtaEngineTests {
    static let dist = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("../../../wisp-ota-jsc/dist").standardized

    static func source(_ name: String) throws -> String {
        try String(contentsOf: dist.appendingPathComponent(name), encoding: .utf8)
    }

    /// Short timeouts so failure paths finish quickly; the logic is the stock one.
    static let timing = WispOtaEngine.Timing(controlAckTimeoutMs: 150, blockAckTimeoutMs: 150, notifyTimeoutMs: 150,
                                             heartbeatIntervalMs: 1000, restartSettleMs: 5)

    let engine: WispOtaEngine
    let fake: WispFakeTempleAccess

    init() throws {
        engine = try WispOtaEngine(source: Self.source("wisp-ota.js"))
        fake = try WispFakeTempleAccess(source: Self.source("wisp-ota-fake-temple.js"), stockVersion: "2.2.6.10")
        fake.restartDelayMs = 20
    }

    func send(_ bundle: [UInt8], temple: G2Side = .left, session: (any WispTempleSession)? = nil,
              abortAfterBytes: Int? = nil) async throws -> (WispOtaEngine.Outcome, [WispOtaEngine.Progress], Bool?) {
        let link = if let session { session } else { try await fake.open(temple) }
        var progress: [WispOtaEngine.Progress] = []
        var aborted: Bool?
        var transfer: WispOtaEngine.Transfer?
        let outcome = try await withCheckedThrowingContinuation { (c: CheckedContinuation<WispOtaEngine.Outcome, Error>) in
            do {
                transfer = try engine.startTransfer(
                    temple: temple, bundle: bundle, link: link, timing: Self.timing,
                    onProgress: { p in
                        progress.append(p)
                        if let limit = abortAfterBytes, p.bytesAcked >= limit, aborted == nil { aborted = transfer?.abort() }
                    },
                    onFinished: { c.resume(returning: $0) })
            } catch { c.resume(throwing: error) }
        }
        return (outcome, progress, aborted)
    }

    @Test func catalogIsThePinnedOne() throws {
        let catalog = try engine.catalog()
        #expect(catalog.count >= 11)
        #expect(Set(catalog.map(\.version)).count == catalog.count)
        let r = try #require(catalog.first { $0.version == "2.2.6.10" })
        #expect(r.sha256 == "f4dfb0b49ad3de3c2daf17f8a27a157c3dc98411d6a0d3ab2cfd0918f41b9afa")
        #expect(r.size == 4_301_227)
        #expect(r.url == "https://cdn.evenreal.co/firmware/e28738432d7b612d625331b00383149b.bin")
    }

    @Test func bytesRoundTripThroughJavaScript() throws {
        let data = (0..<10_000).map { UInt8(truncatingIfNeeded: $0 * 7) }
        #expect(engine.readBytes(engine.makeBytes(data)) == data)
        #expect(engine.readBytes(engine.makeBytes([])) == [])
        // A subarray view: the pointer must start at the view, not the buffer.
        let view = try #require(engine.evaluate("new Uint8Array([9, 8, 7, 6, 5]).subarray(2, 4)"))
        #expect(engine.readBytes(view) == [7, 6])
    }

    @Test func prepareRung1AndStockBack() throws {
        let stock = fake.syntheticStock(version: "2.2.6.10")
        #expect(try engine.defaultRung1Version("2.2.6.10") == "2.2.6.19")
        let rung1 = try engine.prepareRung1(stock: stock, version: "2.2.6.19")
        #expect(rung1.info.sendable)
        #expect(rung1.info.kind == .rung1)
        #expect(rung1.info.versionSites.count == 3)
        #expect(rung1.info.verifyText.lowercased().contains("sendable"))
        let back = try engine.prepareStockBack(stock: stock)
        #expect(back.info.sendable)
        #expect(back.info.toVersion == "2.2.6.10")
        #expect(back.info.mainCrc32c != rung1.info.mainCrc32c)
        #expect(throws: WispOtaEngine.EngineError.self) { try engine.prepareRung1(stock: stock, version: "2.2.6.10") }
    }

    @Test func checkStockRefusesMismatches() throws {
        let stock = fake.syntheticStock(version: "2.2.6.10")
        let catalog = try engine.catalog()
        let pinned = try #require(catalog.first { $0.version == "2.2.6.10" })
        #expect(throws: WispOtaEngine.EngineError.self) {
            try engine.checkStock(pinned, bytes: stock, sha256: pinned.sha256)  // wrong size
        }
    }

    @Test func rung1ThenStockBackOverTheSwiftLink() async throws {
        let stock = fake.syntheticStock(version: "2.2.6.10")
        let rung1 = try engine.prepareRung1(stock: stock, version: "2.2.6.19")
        fake.register(crc32c: rung1.info.mainCrc32c, version: "2.2.6.19")
        let (first, progress, _) = try await send(rung1.bytes)
        #expect(first == .success(version: "2.2.6.19", restartNotified: true))
        #expect(progress.contains { $0.state == "file" && $0.bytesAcked == $0.totalBytes })
        try await Task.sleep(for: .milliseconds(150))  // the fake resets 20 ms after NOTIFY
        #expect(fake.state(.left)?.installed.name == "staged image")
        // Status comes from the right arm, which reports both temples.
        let session = try await fake.open(.right)
        #expect(try await session.readStatus().leftVersion == "2.2.6.19")
        session.close()

        let back = try engine.prepareStockBack(stock: stock)
        fake.register(crc32c: back.info.mainCrc32c, version: "2.2.6.10")
        let (second, _, _) = try await send(back.bytes)
        #expect(second == .success(version: "2.2.6.10", restartNotified: true))
        try await Task.sleep(for: .milliseconds(150))
        let again = try await fake.open(.right)
        #expect(try await again.readStatus().leftVersion == "2.2.6.10")
        again.close()
    }

    @Test func abortBeforeResultCheckLeavesStockIntact() async throws {
        let bundle = try engine.prepareRung1(stock: fake.syntheticStock(version: "2.2.6.10"), version: "2.2.6.19").bytes
        let (outcome, _, aborted) = try await send(bundle, abortAfterBytes: 4096)
        #expect(aborted == true)
        guard case .failedStockIntact(let code, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(code == "aborted")
        fake.reset(.left)
        #expect(fake.state(.left)?.installPending == false)
        #expect(fake.state(.left)?.installed.name == "stock 2.2.6.10")
    }

    @Test func linkDropMidTransferIsFailedStockIntact() async throws {
        let bundle = try engine.prepareRung1(stock: fake.syntheticStock(version: "2.2.6.10"), version: "2.2.6.19").bytes
        fake.faults = ["disconnectAfterBlock": 1]
        let (outcome, _, _) = try await send(bundle)
        guard case .failedStockIntact(let code, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(code == "disconnected")
        fake.reset(.left)
        #expect(fake.state(.left)?.installed.name == "stock 2.2.6.10")
    }

    @Test func lostVerdictIsResultUnknown() async throws {
        let bundle = try engine.prepareRung1(stock: fake.syntheticStock(version: "2.2.6.10"), version: "2.2.6.19").bytes
        fake.faults = ["dropVerdict": true]
        let (outcome, _, _) = try await send(bundle)
        guard case .resultUnknown(let code, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(code == "result-unknown")
    }

    @Test func refusesFullStockAndOtherTempleBeforeWriting() async throws {
        let stock = fake.syntheticStock(version: "2.2.6.10")
        let link = try await fake.open(.left)
        #expect(throws: WispOtaEngine.EngineError.self) {
            try engine.startTransfer(temple: .left, bundle: stock, link: link, onProgress: { _ in }, onFinished: { _ in })
        }
        let rung1 = try engine.prepareRung1(stock: stock, version: "2.2.6.19").bytes
        do {
            _ = try engine.startTransfer(temple: .right, bundle: rung1, link: link, onProgress: { _ in }, onFinished: { _ in })
            Issue.record("expected a temple mismatch refusal")
        } catch WispOtaEngine.EngineError.refused(let code, _) {
            #expect(code == "temple-mismatch")
        }
        #expect(fake.state(.left)?.packetsWritten == 0)
    }
}

struct G2SettingsTests {
    /// Golden frames from the official app's captures (even-g2-protocol tests, MIT).
    @Test func readRequestMatchesCapture() {
        let packets = G2Frame.encode(payload: G2Settings.readBasic(magic: 0x3B), sid: G2Service.settings,
                                     flag: G2Flag.request, seq: 0x3B)
        #expect(packets == [bytes("aa213b0a01010920080210" + "3b22020801" + "5c98")])
    }

    @Test func decodesTheCapturedReply() throws {
        let frame = bytes("aa12b62e0101090008021" + "03b22260801106418062a08322e332e302e3234"
            + "3208322e332e302e3234401e500160649001019801" + "01ae48")
        var assembler = G2FrameAssembler()
        let fed = assembler.feed(frame)
        let message = try #require(fed)
        #expect(message.sid == G2Service.settings)
        #expect(message.magic == 0x3B)
        let r = try #require(G2Settings.decodeReadback(message.payload))
        #expect(r == G2Settings.Readback(leftVersion: "2.3.0.24", rightVersion: "2.3.0.24", battery: 100,
                                          charging: false, isReply: true))
        #expect(r.version(of: .left) == "2.3.0.24")
    }

    @Test func decodesTheChargingPushAndMissingBattery() throws {
        let frame = bytes("aa12ec2f01010901080210a601222610641806" + "2a08322e332e302e3234"
            + "3208322e332e302e3234401e50016064680190010198010147" + "54")
        var assembler = G2FrameAssembler()
        let fed = assembler.feed(frame)
        let message = try #require(fed)
        let r = try #require(G2Settings.decodeReadback(message.payload))
        #expect(r.charging)
        #expect(r.battery == 100)
        #expect(!r.isReply)
        // No field 12 → unknown, never 0 % or "full".
        #expect(G2Settings.decodeReadback([0x08, 0x02, 0x10, 0x01, 0x22, 0x02, 0x08, 0x01])?.battery == nil)
        #expect(G2Settings.decodeReadback([0x08, 0x01, 0x10, 0x01]) == nil)
    }
}
