import Foundation
import LottiKit
import Observation

/// The "Wisp update" developer screen (rung 1 of docs/wisp/safety.md): read a temple's version,
/// get the matching pinned stock bundle, repack it (only the version string changes), check the
/// guard report, and send it to that one temple with wisp-ota's stock OTA sender — or send pure
/// stock back. The guards and the sender run in JavaScriptCore (`WispOtaEngine`); this model only
/// sequences the steps and holds the gates. Every step is logged with its SHA-256s.
///
/// Status (sid 0x09 READ_BASIC) is always read through the right arm: it is the master and reports
/// both temples' versions plus one battery value; the left arm doesn't answer it (hardware.md,
/// 2026-11-06). The send goes only to the chosen temple. Only one arm is ever open at a time.
@MainActor
@Observable
final class WispUpdateModel {
    /// The three end states the screen shows.
    enum Final: Equatable {
        case success(String)
        case failedStockIntact(String)
        case resultUnknown(String)
    }

    /// Battery must be above this (safety.md rule 6). Checked against the one battery value the
    /// right temple reports; whether it is per pair or the right arm's own is unknown.
    static let minimumBattery = 80

    /// The arm that answers the status read (sid 0x09).
    static let statusArm: G2Side = .right

    // MARK: Dependencies

    let engine: WispOtaEngine
    let store: WispStockStore
    let log: WispLog
    private(set) var access: any WispTempleAccess
    private let defaults: UserDefaults
    private let timing: WispOtaEngine.Timing

    // MARK: State

    var temple: G2Side = .left {
        didSet { if temple != oldValue { templeChanged() } }
    }
    private(set) var readback: G2Settings.Readback?
    private(set) var readAt: Date?
    private(set) var stock: WispStockStore.Stock?
    var rung1Version = ""
    private(set) var prepared: WispOtaEngine.Prepared?
    private(set) var preparedSHA256: String?
    /// "The Even app is force-quit and won't reconnect" — per send.
    var evenAppAcknowledged = false
    /// Jan types the temple name ("left") — per send.
    var typedTemple = ""
    /// Arms whose last open was refused because they are already connected to the phone
    /// (`connectedElsewhere`), with Lotti and the Even app closed: iOS itself holds them.
    private(set) var systemConnectedArms: Set<G2Side> = []
    var systemConnectionSeen: Bool { !systemConnectedArms.isEmpty }
    /// "Lotti and the Even app are both closed; iOS itself holds these connections." Applies to the
    /// next attempt only: one read (the right arm's open), or one send (the right arm's open for
    /// the re-read, then the target arm's open for the send), and the sessions they create. Reset
    /// as soon as that attempt starts, on temple change and when the screen closes. Not a send
    /// gate: it replaces none of them.
    var systemConnectionAccepted = false {
        didSet {
            guard systemConnectionAccepted != oldValue, !resettingAcceptance else { return }
            log.add("system connection: user \(systemConnectionAccepted ? "ACCEPTED" : "withdrew acceptance of") "
                + "iOS's own connection to \(armsText(for: temple)), for the next read or send only")
        }
    }
    @ObservationIgnored private var resettingAcceptance = false
    private(set) var busy: String?
    private(set) var error: String?
    private(set) var progress: WispOtaEngine.Progress?
    private(set) var transfer: WispOtaEngine.Transfer?
    private(set) var final: Final?

    init(engine: WispOtaEngine, store: WispStockStore, log: WispLog, access: any WispTempleAccess,
         defaults: UserDefaults = .standard, timing: WispOtaEngine.Timing = .stock) {
        self.engine = engine
        self.store = store
        self.log = log
        self.access = access
        self.defaults = defaults
        self.timing = timing
    }

    func use(access: any WispTempleAccess) {
        guard transfer == nil else { return }
        self.access = access
        readback = nil
        resetSystemAcceptance("temple access changed")
        systemConnectedArms = []
    }

    // MARK: Derived

    var isSending: Bool { transfer != nil }

    var installedVersion: String? { readback?.version(of: temple) }

    /// The last rung-1 repack sent to this temple: `(stock base, repack version)`.
    var lastRepack: (base: String, version: String)? {
        guard let pair = defaults.stringArray(forKey: Self.repackKey(temple)), pair.count == 2 else { return nil }
        return (pair[0], pair[1])
    }

    /// The stock version the installed firmware corresponds to: the installed version itself if
    /// it is a pinned release, or the base of the last repack this screen sent to the temple.
    var stockVersion: String? {
        guard let installed = installedVersion else { return nil }
        if store.release(for: installed) != nil { return installed }
        if let last = lastRepack, last.version == installed { return last.base }
        return nil
    }

    /// Why the installed version doesn't fit the prepared bundle, or nil when it does.
    private func versionProblem(installed: String?, for prepared: WispOtaEngine.Prepared) -> String? {
        guard let installed else { return "The \(temple) temple's version is unknown: read it first." }
        switch prepared.info.kind {
        case .rung1:
            if installed != prepared.info.fromVersion {
                return "The \(temple) temple runs \(installed), but the repack is built from stock \(prepared.info.fromVersion)."
            }
        case .stock:
            let repack = lastRepack.flatMap { $0.base == prepared.info.fromVersion ? $0.version : nil }
            if installed != prepared.info.fromVersion && installed != repack {
                return "The \(temple) temple runs \(installed): neither stock \(prepared.info.fromVersion) nor its repack."
            }
        }
        return nil
    }

    private func batteryProblem(_ readback: G2Settings.Readback?) -> String? {
        guard let battery = readback?.battery else {
            return "The battery (as reported by the right temple) is unreadable: refusing."
        }
        if battery <= Self.minimumBattery {
            return "The battery (as reported by the right temple) is \(battery) %, it must be above \(Self.minimumBattery) %."
        }
        return nil
    }

    /// One row of the send checklist.
    struct Gate: Identifiable, Equatable {
        var id: String
        var title: String
        var ok: Bool
        var detail: String?
    }

    /// Every condition the send button needs. All must be `ok`.
    var gates: [Gate] {
        let report = prepared?.info
        return [
            Gate(id: "session", title: "No other Lotti glasses session", ok: access.blocker == nil, detail: access.blocker),
            Gate(id: "guards", title: "Guard report: sendable", ok: report?.sendable == true,
                 detail: report == nil ? "Prepare a bundle first." : (report!.sendable ? nil : "Not sendable.")),
            Gate(id: "version", title: "Installed version matches the bundle",
                 ok: prepared.map { versionProblem(installed: installedVersion, for: $0) == nil } ?? false,
                 detail: prepared.flatMap { versionProblem(installed: installedVersion, for: $0) }),
            Gate(id: "battery", title: "Battery (as reported by the right temple) above \(Self.minimumBattery) %",
                 ok: batteryProblem(readback) == nil,
                 detail: readback == nil ? "Read the temple first." : batteryProblem(readback)),
            Gate(id: "even", title: "Even app force-quit (acknowledged)", ok: evenAppAcknowledged, detail: nil),
            Gate(id: "typed", title: "Typed \"\(temple.rawValue)\" to confirm", ok: typedTemple == temple.rawValue, detail: nil),
        ]
    }

    var canSend: Bool { !isSending && busy == nil && gates.allSatisfy(\.ok) }

    // MARK: Steps

    /// Step 1: read-only. Opens the right arm, sid 0x09 READ, closes it again. The reply carries
    /// both temples' versions; the screen uses the selected temple's.
    func readVersion() async {
        await run("Reading via the right temple") {
            let side = temple
            let accept = takeSystemAcceptance(for: "read")
            let rb = try await readStatusViaRight(for: "read", accept: accept)
            readback = rb
            readAt = .now
            log.add("read: right temple reports left \(rb.leftVersion ?? "–"), right \(rb.rightVersion ?? "–"), "
                + "battery (as reported by the right temple) \(rb.battery.map { "\($0) %" } ?? "unreadable")"
                + "\(rb.charging ? " (charging)" : ""); the \(side) temple's version is \(rb.version(of: side) ?? "–")")
            if let version = stockVersion, rung1Version.isEmpty || prepared == nil {
                rung1Version = (try? engine.defaultRung1Version(version)) ?? ""
            }
        }
    }

    /// Step 2: the pinned stock bundle for the installed version (cached after the first download).
    func fetchStock() async {
        await run("Getting the stock bundle") {
            guard let version = stockVersion else {
                throw Problem("The installed version \(installedVersion ?? "(unknown)") is neither a pinned stock release nor the last repack sent to this temple. Stop and check.")
            }
            log.add("stock: looking for \(version)")
            let s = try await store.stock(version: version)
            stock = s
            prepared = nil
            preparedSHA256 = nil
            rung1Version = try engine.defaultRung1Version(version)
            log.add("stock: \(version) \(s.fromCache ? "from cache" : "downloaded from \(s.release.url ?? "?")"), \(s.bytes.count) bytes, "
                + "SHA-256 \(s.sha256) (pinned \(s.release.sha256 == s.sha256 ? "match" : "MISMATCH")), pinned official: \(s.check.pinnedOfficial)")
        }
    }

    /// Step 3a: `repack-main` + verify + structural diff.
    func prepareRung1() async {
        await run("Repacking") {
            guard let stock else { throw Problem("Get the stock bundle first.") }
            let version = rung1Version.trimmingCharacters(in: .whitespaces)
            let p = try engine.prepareRung1(stock: stock.bytes, version: version)
            accept(p, from: stock)
        }
    }

    /// Step 3b: pure stock as a main-only bundle (the round trip back).
    func prepareStockBack() async {
        await run("Preparing pure stock") {
            guard let stock else { throw Problem("Get the stock bundle first.") }
            accept(try engine.prepareStockBack(stock: stock.bytes), from: stock)
        }
    }

    private func accept(_ p: WispOtaEngine.Prepared, from stock: WispStockStore.Stock) {
        prepared = p
        // Simulated temple only: it can't parse versions, so tell it what this image reports.
        (access as? WispFakeTempleAccess)?.register(crc32c: p.info.mainCrc32c, version: p.info.toVersion)
        let digest = WispStockStore.sha256(p.bytes)
        preparedSHA256 = digest
        let what = p.info.kind == .rung1 ? "rung 1 repack \(p.info.fromVersion) → \(p.info.toVersion)" : "pure stock \(p.info.toVersion) (main only)"
        log.add("prepare: \(what) from stock SHA-256 \(stock.sha256): \(p.bytes.count) bytes, SHA-256 \(digest), "
            + "main CRC-32C \(p.info.mainCrc32c), guard report \(p.info.sendable ? "SENDABLE" : "NOT sendable")"
            + (p.info.versionSites.isEmpty ? "" : ", \(p.info.versionSites.count) version strings changed"))
    }

    /// Step 4. Re-reads the status through the right arm right before sending: the battery and the
    /// target's version must still pass. For a right send that is the same connection the send
    /// uses; for a left send the right arm is closed again before the left arm is opened. The
    /// typed confirmation, the acknowledgement and the system-connection acceptance are used up.
    func send() async {
        guard canSend, let prepared, let digest = preparedSHA256 else {
            let failed = gates.filter { !$0.ok }.map(\.title).joined(separator: ", ")
            log.add("send: refused (\(failed.isEmpty ? "busy" : failed))")
            resetSystemAcceptance("send refused")
            error = "Not all checks pass: \(failed)."
            return
        }
        let side = temple
        typedTemple = ""
        evenAppAcknowledged = false
        final = nil
        progress = nil
        error = nil
        log.add("send: requested to the \(side) temple, bundle SHA-256 \(digest) (\(prepared.info.kind.rawValue) \(prepared.info.toVersion))")
        let accept = takeSystemAcceptance(for: "send")
        let session: any WispTempleSession
        if side == Self.statusArm {
            // The right temple: re-read and send on the same connection.
            busy = "Opening the \(side) temple"
            do {
                session = try await open(side, for: "send", accept: accept)
            } catch {
                fail("send: could not open the \(side) temple: \(error.localizedDescription)")
                return
            }
            do {
                busy = "Checking the \(side) temple"
                let rb = try await session.readStatus()
                if let problem = recheck(rb, side: side, prepared: prepared) {
                    session.close()
                    fail("send: refused: \(problem)")
                    return
                }
            } catch {
                session.close()
                fail("send: refused before any firmware byte was sent: \(error.localizedDescription)")
                return
            }
        } else {
            // The left temple: re-read through the right arm (closed again), then open the left.
            busy = "Checking via the right temple"
            let rb: G2Settings.Readback
            do {
                rb = try await readStatusViaRight(for: "send", accept: accept)
            } catch {
                fail("send: refused before any firmware byte was sent: re-read via the right temple failed: \(error.localizedDescription)")
                return
            }
            if let problem = recheck(rb, side: side, prepared: prepared) {
                fail("send: refused: \(problem)")
                return
            }
            busy = "Opening the \(side) temple"
            do {
                session = try await open(side, for: "send", accept: accept)
            } catch {
                fail("send: could not open the \(side) temple: \(error.localizedDescription)")
                return
            }
        }
        do {
            busy = nil
            transfer = try engine.startTransfer(
                temple: side, bundle: prepared.bytes, link: session, timing: timing,
                onProgress: { [weak self] p in self?.progress = p },
                onFinished: { [weak self] outcome in
                    session.close()
                    self?.finished(outcome, side: side, prepared: prepared, digest: digest)
                })
            log.add("send: transfer started (\(prepared.bytes.count) bytes)")
        } catch {
            session.close()
            fail("send: refused before any firmware byte was sent: \(error.localizedDescription)")
        }
    }

    /// Only before RESULT_CHECK; the sender refuses afterwards.
    func abort() {
        guard let transfer else { return }
        if transfer.abort() {
            log.add("abort: requested in state \(progress?.state ?? "?")")
        } else {
            log.add("abort: refused, RESULT_CHECK is already out (state \(transfer.state))")
            error = "Too late to abort: RESULT_CHECK has been sent. Wait for the result."
        }
    }

    var canAbort: Bool {
        guard transfer != nil, let state = progress?.state else { return transfer != nil }
        return !["result-check", "notify", "staged"].contains(state)
    }

    /// The pre-send re-read: stores it, logs it, returns why the send must not go, or nil.
    private func recheck(_ rb: G2Settings.Readback, side: G2Side, prepared: WispOtaEngine.Prepared) -> String? {
        readback = rb
        readAt = .now
        log.add("send: re-read via the right temple: \(side) version \(rb.version(of: side) ?? "–"), "
            + "battery (as reported by the right temple) \(rb.battery.map { "\($0) %" } ?? "unreadable")")
        return batteryProblem(rb) ?? versionProblem(installed: rb.version(of: side), for: prepared)
    }

    private func finished(_ outcome: WispOtaEngine.Outcome, side: G2Side, prepared: WispOtaEngine.Prepared, digest: String) {
        transfer = nil
        switch outcome {
        case .success(let version, let restartNotified):
            final = .success("Staged \(version) on the \(side) temple\(restartNotified ? "; it is restarting" : ""). "
                + "Wait about 2 minutes for the Even bootloader to install it, then read the version again.")
            if prepared.info.kind == .rung1 {
                defaults.set([prepared.info.fromVersion, prepared.info.toVersion], forKey: Self.repackKey(side))
            }
            log.add("result: SUCCESS, \(side) temple staged \(version) (SHA-256 \(digest)), restart notified: \(restartNotified)")
            log.add("hardware log: | \(Self.day.string(from: .now)) | \(side) | 1 | \(digest.prefix(12)) | staged \(version); boot check pending |")
        case .failedStockIntact(let code, let message):
            final = .failedStockIntact("\(code): \(message)")
            log.add("result: FAILED, STOCK INTACT (\(code)): \(message)")
        case .resultUnknown(let code, let message):
            final = .resultUnknown("\(code): \(message)")
            log.add("result: RESULT UNKNOWN (\(code)): \(message). Do nothing else; reconnect and read the version.")
        }
        readback = nil  // the temple resets or may have changed: read again
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func repackKey(_ side: G2Side) -> String { "wisp.lastRepack.\(side.rawValue)" }

    private func templeChanged() {
        readback = nil
        readAt = nil
        typedTemple = ""
        evenAppAcknowledged = false
        final = nil
        resetSystemAcceptance("temple changed")
        systemConnectedArms = []
        log.add("temple: \(temple) selected")
    }

    /// The screen went away: no acceptance carries over to a later visit.
    func screenClosed() {
        resetSystemAcceptance("screen closed")
    }

    /// "the right arm" or "the right and left arms": what one read or send of `side` opens.
    private func armsText(for side: G2Side) -> String {
        side == Self.statusArm ? "the \(side) arm" : "the \(Self.statusArm) and \(side) arms"
    }

    /// Takes the system-connection acceptance for one attempt (a read, or a send with its re-read)
    /// and resets the toggle right away, whatever the outcome.
    private func takeSystemAcceptance(for step: String) -> Bool {
        let accept = systemConnectionAccepted
        if accept {
            log.add("\(step): system connection accepted by user for this attempt only (covers \(step == "read" ? "the right arm" : armsText(for: temple)))")
        }
        resetSystemAcceptance("used by this \(step)")
        return accept
    }

    /// Opens the right arm, reads sid 0x09, closes it again (also when the read fails).
    private func readStatusViaRight(for step: String, accept: Bool) async throws -> G2Settings.Readback {
        let session = try await open(Self.statusArm, for: "\(step) (status)", accept: accept)
        defer {
            session.close()
            log.add("\(step) (status): the \(Self.statusArm) temple closed")
        }
        log.add("\(step) (status): sending sid 0x09 READ_BASIC to the \(Self.statusArm) temple")
        return try await session.readStatus()
    }

    /// The one place a temple is opened. `accept` is the acceptance taken for this attempt.
    private func open(_ side: G2Side, for step: String, accept: Bool) async throws -> any WispTempleSession {
        log.add("\(step): opening the \(side) temple exclusively\(accept ? " (system connection accepted by user for this attempt)" : "")")
        do {
            let session = try await access.open(side, acceptSystemConnection: accept)
            if !accept { systemConnectedArms.remove(side) }
            log.add("\(step): the \(side) temple is open")
            return session
        } catch G2ExclusiveArmError.connectedElsewhere(let arm) {
            systemConnectedArms.insert(arm)
            throw G2ExclusiveArmError.connectedElsewhere(arm)
        }
    }

    private func resetSystemAcceptance(_ reason: String) {
        guard systemConnectionAccepted else { return }
        resettingAcceptance = true
        systemConnectionAccepted = false
        resettingAcceptance = false
        log.add("system connection: acceptance reset (\(reason))")
    }

    private struct Problem: LocalizedError {
        var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private func fail(_ text: String) {
        busy = nil
        error = text
        log.add(text)
    }

    private func run(_ label: String, _ step: () async throws -> Void) async {
        guard busy == nil, transfer == nil else { return }
        if let blocker = access.blocker, label.hasPrefix("Reading") {
            error = blocker
            log.add("read: refused: \(blocker)")
            return
        }
        busy = label
        error = nil
        defer { busy = nil }
        do {
            try await step()
        } catch {
            self.error = error.localizedDescription
            log.add("\(label.lowercased()): failed: \(error.localizedDescription)")
        }
    }
}
