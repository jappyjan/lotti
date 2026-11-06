import Foundation
import JavaScriptCore

/// A simulated temple for tests and the iOS Simulator: wisp-ota's fake stock temple
/// (`testing/fake-stock-glasses.ts`, bundled as `wisp-ota-fake-temple.js`) in its **own**
/// JSContext, behind a Swift `WispTempleSession`. Packets only cross through Swift, and
/// notifications arrive asynchronously like CoreBluetooth delivers them, so a transfer exercises
/// the same Swift path a real arm does. Never used with real glasses; device builds don't carry
/// the JS file.
@MainActor
public final class WispFakeTempleAccess: WispTempleAccess {
    /// What the simulated arm reports for sid 0x09 READ.
    public var battery: Int?
    public var charging = false
    /// Version per installed image (main CRC-32C, `0x…`); the starting image is `stock`.
    public private(set) var versions: [String: String] = [:]
    public var stockVersion: String
    /// False makes `readStatus` time out, like an arm that never answers.
    public var answersStatus = true
    public var blocker: String?
    /// Arms the simulated phone already holds at system level (iOS's own connection): `open`
    /// refuses them with `connectedElsewhere` unless the attempt accepts it, like `G2Link`.
    public var systemConnected: Set<G2Side> = []
    /// Every `open` attempt and whether it accepted a system connection, for tests.
    public private(set) var openAttempts: [(side: G2Side, acceptSystemConnection: Bool)] = []
    /// Fault options for the next temple (wisp-ota-jsc `FaultSpec`), e.g. `["dropVerdict": true]`.
    public var faults: [String: Any] = [:]
    public var restartDelayMs = 50

    private let context: JSContext
    private var api: JSValue!
    private var timers: [Int: DispatchWorkItem] = [:]
    private var temples: [G2Side: Int] = [:]
    fileprivate var sessions: [Int: WispFakeTempleSession] = [:]

    public init(source: String, stockVersion: String, battery: Int? = 95) throws {
        guard let context = JSContext() else { throw WispOtaEngine.EngineError.javaScript("no JSContext") }
        self.context = context
        self.stockVersion = stockVersion
        self.battery = battery
        context.evaluateScript(source, withSourceURL: URL(string: "wisp-ota-fake-temple.js"))
        guard let factory = context.objectForKeyedSubscript("WispFakeTemple"), !factory.isUndefined else {
            throw WispOtaEngine.EngineError.javaScript("wisp-ota-fake-temple.js did not define WispFakeTemple")
        }
        api = factory.invokeMethod("create", withArguments: [makeHost()])
    }

    public convenience init(bundle: Bundle, stockVersion: String, battery: Int? = 95) throws {
        guard let url = bundle.url(forResource: "wisp-ota-fake-temple", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { throw WispOtaEngine.EngineError.bundleMissing }
        try self.init(source: source, stockVersion: stockVersion, battery: battery)
    }

    /// Tells the fake which version an image (by main CRC-32C) carries, for `readStatus`.
    public func register(crc32c: String, version: String) {
        versions[crc32c.lowercased()] = version
    }

    public func open(_ side: G2Side, acceptSystemConnection: Bool) async throws -> any WispTempleSession {
        openAttempts.append((side, acceptSystemConnection))
        if let blocker { throw WispSessionError.blocked(blocker) }
        _ = try G2ExclusiveArmError.checkSystemConnection(side, systemConnected: systemConnected.contains(side),
                                                          acceptSystemConnection: acceptSystemConnection)
        let id = temples[side] ?? createTemple(side)
        temples[side] = id
        let session = WispFakeTempleSession(access: self, templeID: id, temple: side)
        sessions[id] = session
        return session
    }

    /// The fake's persistent state (flag, installed image, staging file…).
    public func state(_ side: G2Side) -> FakeState? {
        guard let id = temples[side],
              let json = api.invokeMethod("state", withArguments: [id])?.toString() else { return nil }
        return try? JSONDecoder().decode(FakeState.self, from: Data(json.utf8))
    }

    public struct FakeState: Decodable, Equatable {
        public struct Installed: Decodable, Equatable {
            public var name: String
            public var crc32c: UInt32?
        }

        public var flag: UInt32
        public var installPending: Bool
        public var installed: Installed
        public var resets: Int
        public var packetsWritten: Int
    }

    /// A reset into the bootloader (installs a staged image only if the flag is set).
    public func reset(_ side: G2Side) {
        guard let id = temples[side] else { return }
        api.invokeMethod("reset", withArguments: [id])
    }

    /// Drops the link (radio loss).
    public func dropLink(_ side: G2Side, reason: String = "link lost") {
        guard let id = temples[side] else { return }
        api.invokeMethod("disconnect", withArguments: [id, reason])
    }

    /// A stock-shaped synthetic bundle (never Even's firmware).
    public func syntheticStock(version: String, appSize: Int = 3 * 4096 + 0x321) -> [UInt8] {
        guard let value = api.invokeMethod("syntheticStock", withArguments: [version, appSize]) else { return [] }
        return readBytes(value) ?? []
    }

    fileprivate func version(of side: G2Side) -> String? {
        guard let installed = state(side)?.installed else { return nil }
        guard let crc = installed.crc32c else { return stockVersion }
        return versions[String(format: "0x%08x", crc)] ?? "unknown"
    }

    private func createTemple(_ side: G2Side) -> Int {
        let options: [String: Any] = ["faults": faults, "restartDelayMs": restartDelayMs]
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: options)) ?? Data("{}".utf8),
                          as: UTF8.self)
        let value = api.invokeMethod("create", withArguments: [side.rawValue, "stock \(stockVersion)", json])
        return Int(value?.toInt32() ?? 0)
    }

    fileprivate func write(_ id: Int, _ channel: WispChannel, _ packet: [UInt8]) -> Bool {
        api.invokeMethod("write", withArguments: [id, channel.rawValue, makeBytes(packet)])?.toBool() ?? false
    }

    private func makeHost() -> JSValue {
        let host = JSValue(newObjectIn: context)!
        let setTimeout: @convention(block) (Int, Double) -> Void = { [weak self] id, ms in
            MainActor.assumeIsolated {
                guard let self else { return }
                let item = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.timers.removeValue(forKey: id) != nil else { return }
                        self.api.invokeMethod("timerFired", withArguments: [id])
                    }
                }
                self.timers[id] = item
                DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000, execute: item)
            }
        }
        let clearTimeout: @convention(block) (Int) -> Void = { [weak self] id in
            MainActor.assumeIsolated { self?.timers.removeValue(forKey: id)?.cancel() }
        }
        let now: @convention(block) () -> Double = { Date().timeIntervalSince1970 * 1000 }
        let emit: @convention(block) (Int, String, JSValue) -> Void = { [weak self] id, channel, bytes in
            MainActor.assumeIsolated {
                guard let self, let channel = WispChannel(rawValue: channel), let packet = self.readBytes(bytes) else { return }
                // Asynchronous, like a BLE notification.
                DispatchQueue.main.async { MainActor.assumeIsolated { self.sessions[id]?.onPacket?(channel, packet) } }
            }
        }
        let disconnect: @convention(block) (Int, String) -> Void = { [weak self] id, reason in
            MainActor.assumeIsolated {
                guard let self else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let session = self.sessions.removeValue(forKey: id) else { return }
                        session.closed = true
                        session.onDisconnect?(reason)
                    }
                }
            }
        }
        host.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)
        host.setObject(clearTimeout, forKeyedSubscript: "clearTimeout" as NSString)
        host.setObject(now, forKeyedSubscript: "now" as NSString)
        host.setObject(emit, forKeyedSubscript: "emit" as NSString)
        host.setObject(disconnect, forKeyedSubscript: "disconnect" as NSString)
        return host
    }

    private func makeBytes(_ bytes: [UInt8]) -> JSValue {
        let ctx = context.jsGlobalContextRef
        var exception: JSValueRef?
        let object = JSObjectMakeTypedArray(ctx, kJSTypedArrayTypeUint8Array, bytes.count, &exception)!
        if !bytes.isEmpty, let pointer = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception) {
            bytes.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        }
        return JSValue(jsValueRef: object, in: context)
    }

    private func readBytes(_ value: JSValue) -> [UInt8]? {
        let ctx = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard let ref = value.jsValueRef, let object = JSValueToObject(ctx, ref, &exception) else { return nil }
        let length = JSObjectGetTypedArrayByteLength(ctx, object, &exception)
        let offset = JSObjectGetTypedArrayByteOffset(ctx, object, &exception)
        guard length > 0, let pointer = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception) else { return [] }
        return Array(UnsafeRawBufferPointer(start: pointer + offset, count: length))
    }
}

public enum WispSessionError: LocalizedError, Equatable {
    case blocked(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .blocked(let why): why
        case .closed: "The temple link is closed."
        }
    }
}

@MainActor
final class WispFakeTempleSession: WispTempleSession {
    let temple: G2Side
    var onPacket: ((WispChannel, [UInt8]) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var closed = false
    private weak var access: WispFakeTempleAccess?
    private let templeID: Int

    init(access: WispFakeTempleAccess, templeID: Int, temple: G2Side) {
        self.access = access
        self.templeID = templeID
        self.temple = temple
    }

    func write(_ channel: WispChannel, _ packet: [UInt8]) async throws {
        guard !closed, let access, access.write(templeID, channel, packet) else { throw WispSessionError.closed }
    }

    func readStatus() async throws -> G2Settings.Readback {
        guard !closed, let access else { throw WispSessionError.closed }
        try await Task.sleep(for: .milliseconds(150))
        guard access.answersStatus else { throw GlassesLinkError.timeout("reading the \(temple) arm's status") }
        let version = access.version(of: temple)
        return G2Settings.Readback(
            leftVersion: temple == .left ? version : nil, rightVersion: temple == .right ? version : nil,
            battery: access.battery, charging: access.charging, isReply: true)
    }

    func close() {
        closed = true
        if access?.sessions[templeID] === self { access?.sessions[templeID] = nil }
    }
}
