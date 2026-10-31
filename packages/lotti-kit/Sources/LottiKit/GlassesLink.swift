import Foundation

/// A pair of glasses found while scanning, or remembered from last time.
public struct DiscoveredGlasses: Identifiable, Hashable, Codable, Sendable {
    /// Stable id for the pair (for the G2: the pair number in the advertised name).
    public var id: String
    public var name: String
    /// Bluetooth identifiers of the arms seen so far. Both are needed to connect a G2.
    public var leftArm: UUID?
    public var rightArm: UUID?
    /// Signal strength of the strongest arm, if known.
    public var rssi: Int?

    public init(id: String, name: String, leftArm: UUID? = nil, rightArm: UUID? = nil, rssi: Int? = nil) {
        self.id = id
        self.name = name
        self.leftArm = leftArm
        self.rightArm = rightArm
        self.rssi = rssi
    }

    public var isComplete: Bool { leftArm != nil && rightArm != nil }
}

public enum GlassesStatus: Equatable, Sendable {
    /// Bluetooth is off, unsupported or not allowed. The string says which.
    case bluetoothUnavailable(String)
    case disconnected
    case scanning
    /// The string says which step is running ("Authenticating…").
    case connecting(String)
    case connected(DiscoveredGlasses)
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

public enum GlassesLinkError: Error, Equatable, LocalizedError {
    case notConnected
    case timeout(String)
    case missingCharacteristics
    case incompleteGlasses

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Glasses are not connected."
        case .timeout(let step): "Timed out: \(step)."
        case .missingCharacteristics: "The glasses don't expose the expected Bluetooth characteristics."
        case .incompleteGlasses: "Only one arm was found. Make sure both arms are on and out of the case."
        }
    }
}

/// The connection to a pair of smart glasses. The app talks only to this, so other glasses can
/// be added later by writing another implementation.
@MainActor
public protocol GlassesLink: AnyObject, Observable {
    var status: GlassesStatus { get }
    /// Glasses found by the current or last scan.
    var discovered: [DiscoveredGlasses] { get }
    /// The glasses connected most recently, remembered across launches.
    var lastGlasses: DiscoveredGlasses? { get }

    func startScan()
    func stopScan()
    func connect(_ glasses: DiscoveredGlasses) async
    func disconnect()
    /// Show plain text on the glasses' display.
    func showText(_ text: String) async throws
}

extension GlassesLink {
    /// Reconnect to `lastGlasses`, if there are any.
    public func reconnectToLast() async {
        if let last = lastGlasses { await connect(last) }
    }
}
