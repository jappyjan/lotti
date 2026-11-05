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

/// Whether the glasses are on your head, from the firmware's wear detection (sid 0x0D).
public enum WearState: Equatable, Sendable {
    /// Nothing reported yet this session.
    case unknown
    case worn
    case removed
}

/// One line of the wear trace: a wear answer (sid 0x10) or state message (sid 0x0D) from the
/// glasses, or a marker you set ("glasses ON now") so the answers can be matched to what you did.
public struct StateTraceEntry: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var time: Date
    public var text: String
    public var isMarker: Bool

    public init(time: Date = .now, text: String, isMarker: Bool = false) {
        self.time = time
        self.text = text
        self.isMarker = isMarker
    }
}

/// One block of text at a fixed place on the display (pixels, 576 × 288 on the G2).
public struct FrameBox: Equatable, Sendable {
    /// Short and unique within a frame ("main", "rail", "card1"); at most 14 characters.
    public var name: String
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var text: String

    public init(_ name: String, x: Int, y: Int, width: Int, height: Int, text: String) {
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.text = text
    }
}

/// What the display shows: text boxes, already laid out by `ScreenRenderer`; the link only draws
/// them. The first box is the main one (Lotti's sentence; it takes the touch events); `rail` is
/// the block of choices under it. Black is invisible on the lens, so `.dark` (empty text) turns
/// the display off without ending the session.
public struct GlassesFrame: Equatable, Sendable {
    public var boxes: [FrameBox]
    /// Small image containers (the attention and location indicators) drawn over the page.
    /// They don't count for `isDark`: a dark frame with an indicator is the "display off" state.
    public var images: [G2ImageBox]

    public init(boxes: [FrameBox], images: [G2ImageBox] = []) {
        self.boxes = boxes
        self.images = images
    }

    /// Lotti's text across the display, with the choices block underneath if there is one.
    public init(main: String, rail: String? = nil, images: [G2ImageBox] = []) {
        var boxes = [FrameBox("main", x: 0, y: 0, width: G2Layout.width,
                              height: rail == nil ? G2Layout.height : G2Layout.choicesY, text: main)]
        if let rail {
            boxes.append(FrameBox("rail", x: 0, y: G2Layout.choicesY, width: G2Layout.width,
                                  height: G2Layout.height - G2Layout.choicesY, text: rail))
        }
        self.init(boxes: boxes, images: images)
    }

    public static let dark = GlassesFrame(main: "")
    public var isDark: Bool { boxes.allSatisfy(\.text.isEmpty) }

    /// The main box's text.
    public var main: String { boxes.first?.text ?? "" }
    /// The choices block's text, if there are choices.
    public var rail: String? { self["rail"] }
    public subscript(name: String) -> String? { boxes.first { $0.name == name }?.text }
    /// Every box's text, top to bottom, for logs and tests.
    public var allText: String { boxes.map(\.text).joined(separator: "\n") }
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
    /// Show plain text on the glasses' display, full width.
    func showText(_ text: String) async throws
    /// Show a frame. Only what changed is sent; switching between "with rail" and "without rail"
    /// rebuilds the page.
    func show(_ frame: GlassesFrame) async throws
    /// Turn on the glasses' microphone. The stream yields 16 kHz mono PCM chunks until
    /// `stopMicrophone()` is called or the link drops.
    func startMicrophone() async throws -> AsyncStream<[Int16]>
    func stopMicrophone() async
    /// Report head-up / head-down (from the glasses' IMU) as `.headUp` / `.headDown` inputs.
    /// Prefer `IMUDemand` over calling this directly: it is reference-counted, so several users
    /// (head-up, the mascot) can share the feed.
    func setHeadTracking(_ enabled: Bool) async
    /// Raw gravity samples while head tracking is on (about one a second on the G2). Each call
    /// returns a new stream; listening adds no traffic on the link.
    func imuSamples() -> AsyncStream<IMUSample>
    /// Wear detection: `.unknown` until the glasses answer. The G2 only says when asked, so the
    /// link asks every few seconds while connected (see `G2Payload.wearStatusQuery`). Changes
    /// also arrive as `.worn` / `.removed` inputs.
    var wearState: WearState { get }
    /// Ask the glasses now instead of waiting for the next regular question.
    func checkWear() async
    /// Every wear answer, state message and marker this session, newest last (at most 100). Also
    /// written to the log as `[state]` and `[MARK]` lines.
    var stateTrace: [StateTraceEntry] { get }
    /// Adds a marker to the trace and the log, e.g. "glasses ON".
    func addStateMarker(_ text: String)
    /// When looking up counts as head-up.
    var headUpSettings: HeadUpSettings { get set }
    /// The head's latest pitch in degrees while head tracking is on, for calibrating.
    var headPitch: Double? { get }
    /// Gestures from the touchpads and from the ring. The ring is linked to the glasses, which
    /// relay its gestures. Each call returns a new stream; repeats are already filtered out.
    func inputs() -> AsyncStream<InputEvent>

    // MARK: Navigation (service 0x08)

    /// While the firmware's own navigation screen is up, Lotti's EvenHub page stays down and
    /// `show` is a no-op.
    var displaySuspended: Bool { get set }
    /// Send one `G2Navigation` payload to the navigation service, fire and forget
    /// (heartbeat, BASIC_INFO updates).
    func sendNavigation(_ payload: [UInt8]) async
    /// Send one `G2Navigation` payload and wait for the reply that echoes its magic (field 2).
    /// Throws on timeout; an explicit failure shows up as a non-zero `G2Navigation.replyError`.
    func navigationRequest(_ payload: [UInt8]) async throws -> G2Message
    /// Glasses-initiated navigation events (user exits, view changes, transport switch, …).
    /// Reply echoes are filtered out.
    func navigationEvents() -> AsyncStream<G2NavigationEvent>
}

extension GlassesLink {
    /// Reconnect to `lastGlasses`, if there are any.
    public func reconnectToLast() async {
        if let last = lastGlasses { await connect(last) }
    }
}
