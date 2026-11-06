import Foundation
import JavaScriptCore

/// `@wisp/ota` running inside JavaScriptCore: the EVENOTA guards, the rung-1 repacker, the
/// structural diff and the stock OTA sender, all single-source from `packages/wisp-ota` (bundled
/// by `packages/wisp-ota-jsc` into one JS file). Swift only provides timers, bytes and the
/// `WispStockLink`.
///
/// Not thread-safe by design: everything runs on the main actor, like CoreBluetooth in `G2Link`.
@MainActor
public final class WispOtaEngine {
    public struct StockRelease: Codable, Equatable, Sendable {
        public var version: String
        public var md5: String
        public var size: Int
        public var sha256: String
        public var mainAppEnd: Int
        public var url: String?

        public init(version: String, md5: String, size: Int, sha256: String, mainAppEnd: Int, url: String? = nil) {
            self.version = version
            self.md5 = md5
            self.size = size
            self.sha256 = sha256
            self.mainAppEnd = mainAppEnd
            self.url = url
        }
    }

    public struct StockCheck: Decodable, Equatable, Sendable {
        public var version: String
        public var size: Int
        public var sha256: String
        /// The release record equals the pinned catalog entry (always required by the app).
        public var pinnedOfficial: Bool
        public var inspect: String
    }

    /// A bundle ready to send, with the guard report.
    public struct Prepared: Sendable {
        public enum Kind: String, Decodable, Sendable { case rung1, stock }
        public struct Info: Decodable, Sendable {
            public var kind: Kind
            public var fromVersion: String
            public var toVersion: String
            public var versionSites: [Int]
            public var verifyText: String
            public var diffText: String
            /// verifyBundle sendable **and** the diff shows only allowed changes.
            public var sendable: Bool
            /// CRC-32C of the main payload that will be installed (`0x…`).
            public var mainCrc32c: String
        }

        public var info: Info
        public var bytes: [UInt8]
    }

    public enum EngineError: LocalizedError, Equatable {
        case bundleMissing
        case javaScript(String)
        /// The sender refused before touching the link (`not-sendable`, `temple-mismatch`, …).
        case refused(code: String, message: String)

        public var errorDescription: String? {
            switch self {
            case .bundleMissing: "wisp-ota.js is missing from the app (build it with `pnpm nx run wisp-ota-jsc:bundle`)."
            case .javaScript(let message): message
            case .refused(let code, let message): "Refused (\(code)): \(message)"
            }
        }
    }

    public struct Progress: Decodable, Equatable, Sendable {
        public var state: String
        public var bytesAcked: Int
        public var totalBytes: Int
        public var block: Int
        public var blocks: Int
        public var componentAttempt: Int
    }

    /// How a transfer ended, in the three states the screen shows.
    public enum Outcome: Equatable, Sendable {
        /// RESULT_CHECK → UPDATING: the image is staged and the temple resets into the Even
        /// bootloader. Reconnect and read the version to confirm the install.
        case success(version: String, restartNotified: Bool)
        /// Failed or aborted before RESULT_CHECK: the update flag was never set.
        case failedStockIntact(code: String, message: String)
        /// RESULT_CHECK went out and its verdict was lost: the flag may be set.
        case resultUnknown(code: String, message: String)
    }

    /// A running transfer.
    @MainActor
    public final class Transfer {
        public let id: Int
        public let temple: G2Side
        fileprivate weak var engine: WispOtaEngine?
        fileprivate let link: any WispStockLink
        fileprivate let onProgress: (Progress) -> Void
        fileprivate let onFinished: (Outcome) -> Void

        fileprivate init(id: Int, temple: G2Side, engine: WispOtaEngine, link: any WispStockLink,
                         onProgress: @escaping (Progress) -> Void, onFinished: @escaping (Outcome) -> Void) {
            self.id = id
            self.temple = temple
            self.engine = engine
            self.link = link
            self.onProgress = onProgress
            self.onFinished = onFinished
        }

        /// Only before RESULT_CHECK is sent (the sender decides); false afterwards.
        @discardableResult
        public func abort() -> Bool { engine?.abort(id) ?? false }

        /// The sender's current state (`file`, `result-check`, …).
        public var state: String { engine?.stringOrNil("state", [id]) ?? "unknown" }
    }

    /// Production timings come from wisp-ota (`DEFAULT_TIMING`); tests pass shorter ones.
    public struct Timing: Encodable, Sendable {
        public var controlAckTimeoutMs: Int?
        public var blockAckTimeoutMs: Int?
        public var notifyTimeoutMs: Int?
        public var heartbeatIntervalMs: Int?
        public var restartSettleMs: Int?

        public init(controlAckTimeoutMs: Int? = nil, blockAckTimeoutMs: Int? = nil, notifyTimeoutMs: Int? = nil,
                    heartbeatIntervalMs: Int? = nil, restartSettleMs: Int? = nil) {
            self.controlAckTimeoutMs = controlAckTimeoutMs
            self.blockAckTimeoutMs = blockAckTimeoutMs
            self.notifyTimeoutMs = notifyTimeoutMs
            self.heartbeatIntervalMs = heartbeatIntervalMs
            self.restartSettleMs = restartSettleMs
        }

        public static let stock = Timing()
    }

    private let context: JSContext
    private var api: JSValue!
    private var lastException: String?
    private var timers: [Int: DispatchWorkItem] = [:]
    private var transfers: [Int: Transfer] = [:]

    /// `source` is the content of `wisp-ota.js`.
    public init(source: String) throws {
        guard let context = JSContext() else { throw EngineError.javaScript("no JSContext") }
        self.context = context
        context.name = "wisp-ota"
        context.exceptionHandler = { [weak self] _, exception in
            let text = exception?.objectForKeyedSubscript("message")?.toString() ?? exception?.toString() ?? "?"
            MainActor.assumeIsolated { self?.lastException = text }
        }
        context.evaluateScript(source, withSourceURL: URL(string: "wisp-ota.js"))
        if let error = takeException() { throw EngineError.javaScript("loading wisp-ota.js: \(error)") }
        guard let factory = context.objectForKeyedSubscript("WispOta"), !factory.isUndefined else {
            throw EngineError.javaScript("wisp-ota.js did not define WispOta")
        }
        api = factory.invokeMethod("create", withArguments: [makeHost()])
        if let error = takeException() { throw EngineError.javaScript(error) }
    }

    /// Loads `wisp-ota.js` from `bundle` (the app bundle).
    public convenience init(bundle: Bundle) throws {
        guard let url = bundle.url(forResource: "wisp-ota", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { throw EngineError.bundleMissing }
        try self.init(source: source)
    }

    // MARK: - Offline steps

    /// The pinned official releases (wisp-ota `catalog.ts`), with CDN URLs.
    public func catalog() throws -> [StockRelease] {
        try decode([StockRelease].self, callString("catalog", []))
    }

    /// The `wisp-ota fetch` checks on downloaded bytes whose SHA-256 the caller computed.
    public func checkStock(_ release: StockRelease, bytes: [UInt8], sha256: String) throws -> StockCheck {
        let json = String(decoding: try JSONEncoder().encode(release), as: UTF8.self)
        return try decode(StockCheck.self, callString("checkStock", [json, makeBytes(bytes), sha256]))
    }

    public func defaultRung1Version(_ stockVersion: String) throws -> String {
        try callString("defaultRung1Version", [stockVersion])
    }

    /// Rung 1: `repack-main` + verify + structural diff.
    public func prepareRung1(stock: [UInt8], version: String) throws -> Prepared {
        try prepared(call("prepareRung1", [makeBytes(stock), version]))
    }

    /// The round trip: the unchanged stock main as a main-only bundle.
    public func prepareStockBack(stock: [UInt8]) throws -> Prepared {
        try prepared(call("prepareStockBack", [makeBytes(stock)]))
    }

    // MARK: - Sending

    /// Starts the stock OTA sender on `link`. The sender verifies `bundle` again and refuses
    /// anything not sendable, or a temple that differs from `link.temple`, before any write.
    public func startTransfer(
        temple: G2Side, bundle: [UInt8], link: any WispStockLink, timing: Timing = .stock,
        onProgress: @escaping (Progress) -> Void, onFinished: @escaping (Outcome) -> Void
    ) throws -> Transfer {
        let timingJSON = String(decoding: try JSONEncoder().encode(timing), as: UTF8.self)
        let value = api.invokeMethod("startTransfer", withArguments: [
            temple.rawValue, link.temple.rawValue, makeBytes(bundle), timingJSON,
        ])
        if let error = takeException() {
            if let data = error.data(using: .utf8),
               let refusal = try? JSONDecoder().decode(Finished.self, from: data) {
                throw EngineError.refused(code: refusal.code ?? "refused", message: refusal.message ?? error)
            }
            throw EngineError.javaScript(error)
        }
        guard let id = value.flatMap({ Int($0.toInt32()) }), id > 0 else {
            throw EngineError.javaScript("startTransfer returned no id")
        }
        let transfer = Transfer(id: id, temple: temple, engine: self, link: link,
                                onProgress: onProgress, onFinished: onFinished)
        transfers[id] = transfer
        link.onPacket = { [weak self] channel, bytes in
            guard let self else { return }
            self.callVoid("packet", [id, channel.rawValue, self.makeBytes(bytes)])
        }
        link.onDisconnect = { [weak self] reason in
            self?.callVoid("disconnected", [id, reason])
        }
        callVoid("run", [id])
        return transfer
    }

    fileprivate func abort(_ id: Int) -> Bool {
        let value = call("abort", [id])
        return value?.toBool() ?? false
    }

    // MARK: - Host (called from JavaScript, on the main thread)

    private func makeHost() -> JSValue {
        let host = JSValue(newObjectIn: context)!
        let setTimeout: @convention(block) (Int, Double) -> Void = { [weak self] id, ms in
            MainActor.assumeIsolated { self?.schedule(id, ms: ms) }
        }
        let clearTimeout: @convention(block) (Int) -> Void = { [weak self] id in
            MainActor.assumeIsolated { self?.timers.removeValue(forKey: id)?.cancel() }
        }
        let now: @convention(block) () -> Double = { Date().timeIntervalSince1970 * 1000 }
        let write: @convention(block) (Int, String, JSValue, Int) -> Void = { [weak self] transfer, channel, bytes, writeId in
            MainActor.assumeIsolated { self?.write(transfer: transfer, channel: channel, bytes: bytes, writeId: writeId) }
        }
        let progress: @convention(block) (Int, String) -> Void = { [weak self] transfer, json in
            MainActor.assumeIsolated { self?.progress(transfer: transfer, json: json) }
        }
        let finished: @convention(block) (Int, String) -> Void = { [weak self] transfer, json in
            MainActor.assumeIsolated { self?.finished(transfer: transfer, json: json) }
        }
        host.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)
        host.setObject(clearTimeout, forKeyedSubscript: "clearTimeout" as NSString)
        host.setObject(now, forKeyedSubscript: "now" as NSString)
        host.setObject(write, forKeyedSubscript: "write" as NSString)
        host.setObject(progress, forKeyedSubscript: "progress" as NSString)
        host.setObject(finished, forKeyedSubscript: "finished" as NSString)
        return host
    }

    private func schedule(_ id: Int, ms: Double) {
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.timers.removeValue(forKey: id) != nil else { return }
                self.callVoid("timerFired", [id])
            }
        }
        timers[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, ms) / 1000, execute: item)
    }

    private func write(transfer id: Int, channel: String, bytes: JSValue, writeId: Int) {
        guard let transfer = transfers[id], let channel = WispChannel(rawValue: channel),
              let packet = readBytes(bytes)
        else {
            callVoid("writeDone", [writeId, "no such transfer or channel"])
            return
        }
        // Answer asynchronously, like a radio: the sender awaits each write before the next.
        Task { @MainActor [weak self] in
            var failure: String?
            do { try await transfer.link.write(channel, packet) } catch { failure = error.localizedDescription }
            self?.callVoid("writeDone", [writeId, failure.map { $0 as Any } ?? NSNull()])
        }
    }

    private func progress(transfer id: Int, json: String) {
        guard let transfer = transfers[id], let progress = try? decode(Progress.self, json) else { return }
        transfer.onProgress(progress)
    }

    private struct Finished: Decodable {
        struct Result: Decodable {
            var version: String
            var restartNotified: Bool
        }

        enum Intact: Decodable, Equatable {
            case yes, unknown
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let flag = try? c.decode(Bool.self), flag { self = .yes } else { self = .unknown }
            }
        }

        var outcome: String
        var stockIntact: Intact?
        var code: String?
        var message: String?
        var result: Result?
    }

    private func finished(transfer id: Int, json: String) {
        guard let transfer = transfers.removeValue(forKey: id) else { return }
        transfer.link.onPacket = nil
        transfer.link.onDisconnect = nil
        let outcome: Outcome
        if let f = try? decode(Finished.self, json) {
            switch (f.outcome, f.stockIntact) {
            case ("staged", _):
                let version = f.result?.version ?? "?"
                outcome = .success(version: version.hasPrefix("s200_v") ? String(version.dropFirst(6)) : version,
                                   restartNotified: f.result?.restartNotified ?? false)
            case (_, .yes?):
                outcome = .failedStockIntact(code: f.code ?? f.outcome, message: f.message ?? "")
            default:
                outcome = .resultUnknown(code: f.code ?? f.outcome, message: f.message ?? "")
            }
        } else {
            outcome = .resultUnknown(code: "internal", message: "unreadable result: \(json)")
        }
        callVoid("release", [id])
        transfer.onFinished(outcome)
    }

    // MARK: - JS plumbing

    private func takeException() -> String? {
        defer { lastException = nil }
        return lastException
    }

    @discardableResult
    private func call(_ method: String, _ arguments: [Any]) -> JSValue? {
        lastException = nil
        return api.invokeMethod(method, withArguments: arguments)
    }

    private func callVoid(_ method: String, _ arguments: [Any]) {
        call(method, arguments)
        if let error = takeException() { print("[Wisp] JS \(method) threw: \(error)") }
    }

    fileprivate func callString(_ method: String, _ arguments: [Any]) throws -> String {
        let value = call(method, arguments)
        if let error = takeException() { throw EngineError.javaScript(error) }
        guard let value, value.isString, let text = value.toString() else {
            throw EngineError.javaScript("\(method) returned no string")
        }
        return text
    }

    fileprivate func stringOrNil(_ method: String, _ arguments: [Any]) -> String? {
        try? callString(method, arguments)
    }

    private func prepared(_ value: JSValue?) throws -> Prepared {
        if let error = takeException() { throw EngineError.javaScript(error) }
        guard let value, let json = value.objectForKeyedSubscript("json")?.toString(),
              let bytesValue = value.objectForKeyedSubscript("bytes"), let bytes = readBytes(bytesValue)
        else { throw EngineError.javaScript("prepare returned nothing") }
        return Prepared(info: try decode(Prepared.Info.self, json), bytes: bytes)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// A fresh `Uint8Array` holding a copy of `bytes`.
    func makeBytes(_ bytes: [UInt8]) -> JSValue {
        let ctx = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard let object = JSObjectMakeTypedArray(ctx, kJSTypedArrayTypeUint8Array, bytes.count, &exception) else {
            return JSValue(undefinedIn: context)
        }
        if !bytes.isEmpty, let pointer = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception) {
            bytes.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        }
        return JSValue(jsValueRef: object, in: context)
    }

    /// Copies a JS `Uint8Array` (any view, including a subarray) out.
    func readBytes(_ value: JSValue) -> [UInt8]? {
        let ctx = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard let ref = value.jsValueRef,
              JSValueGetTypedArrayType(ctx, ref, &exception) == kJSTypedArrayTypeUint8Array,
              let object = JSValueToObject(ctx, ref, &exception)
        else { return nil }
        let length = JSObjectGetTypedArrayByteLength(ctx, object, &exception)
        guard length > 0 else { return [] }
        // The pointer is the start of the backing buffer; a view (subarray) starts byteOffset later.
        let offset = JSObjectGetTypedArrayByteOffset(ctx, object, &exception)
        guard let pointer = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception) else { return nil }
        return Array(UnsafeRawBufferPointer(start: pointer + offset, count: length))
    }

    /// Evaluates `script` in the engine's context (tests only).
    func evaluate(_ script: String) -> JSValue? { context.evaluateScript(script) }
}
