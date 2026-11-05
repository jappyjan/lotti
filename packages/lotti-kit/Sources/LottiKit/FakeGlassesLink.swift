import Foundation
import Observation

/// A `GlassesLink` without hardware, for tests and previews. Records what was shown and lets the
/// test push gestures and microphone audio.
@MainActor
@Observable
public final class FakeGlassesLink: GlassesLink {
    public var status: GlassesStatus = .disconnected
    public var discovered: [DiscoveredGlasses] = []
    public var lastGlasses: DiscoveredGlasses?

    public private(set) var scanned = false
    public private(set) var connected: [String] = []
    /// Every frame shown, oldest first. `showText` records a full-width frame.
    public private(set) var frames: [GlassesFrame] = []
    public var showError: Error?
    /// Makes `startMicrophone()` throw, to test the phone-mic fallback.
    public var microphoneError: Error?
    public private(set) var microphoneOn = false
    /// How often the mic was switched on and off, to check streams are shared, not restarted.
    public private(set) var microphoneStarts = 0
    public private(set) var microphoneStops = 0
    /// Every `startMicrophone()` call, failed ones included (to check retries back off).
    public private(set) var microphoneAttempts = 0
    /// Makes `startMicrophone()` take this long, like the real glasses' ack.
    public var microphoneDelay: Duration?
    public private(set) var headTracking = false
    /// Every `setHeadTracking` call, oldest first.
    public private(set) var headTrackingCalls: [Bool] = []
    /// How long `setHeadTracking` takes, like the BLE round trip (zero by default).
    public var headTrackingDelay: Duration = .zero
    public var headUpSettings = HeadUpSettings()
    public var headPitch: Double?
    public private(set) var wearState: WearState = .unknown
    public private(set) var stateTrace: [StateTraceEntry] = []
    public func addStateMarker(_ text: String) { stateTrace.append(StateTraceEntry(text: text, isMarker: true)) }
    /// How often `checkWear()` was called.
    public private(set) var wearChecks = 0
    public func checkWear() async { wearChecks += 1 }

    @ObservationIgnored private let imuBroadcast = Broadcast<IMUSample>()
    @ObservationIgnored private let inputBroadcast = Broadcast<InputEvent>()
    @ObservationIgnored private var mic: AsyncStream<[Int16]>.Continuation?
    @ObservationIgnored private let navigationBroadcast = Broadcast<G2NavigationEvent>()

    // Navigation
    public var displaySuspended = false
    /// Every payload sent to the navigation service, oldest first (both `sendNavigation` and
    /// `navigationRequest`).
    public private(set) var navigationPayloads: [[UInt8]] = []
    /// The payload `navigationRequest` answers with; nil (default) echoes the request.
    public var navigationReply: [UInt8]?
    /// When set, `navigationRequest` throws it instead of replying.
    public var navigationRequestError: Error?

    public init(last: DiscoveredGlasses? = nil) { lastGlasses = last }

    public var shownTexts: [String] { frames.map(\.main) }

    public func startScan() { scanned = true }
    public func stopScan() {}
    public func connect(_ glasses: DiscoveredGlasses) async {
        connected.append(glasses.id)
        status = .connected(glasses)
    }
    public func disconnect() { status = .disconnected }

    public func showText(_ text: String) async throws {
        try await show(GlassesFrame(main: text))
    }

    public func show(_ frame: GlassesFrame) async throws {
        if let showError { throw showError }
        frames.append(frame)
    }

    public func inputs() -> AsyncStream<InputEvent> { inputBroadcast.stream() }

    /// Deliver a gesture to every `inputs()` stream.
    public func send(_ event: InputEvent) { inputBroadcast.send(event) }

    /// The glasses report being put on or taken off: updates `wearState` and sends the input.
    public func sendWear(_ worn: Bool) {
        wearState = worn ? .worn : .removed
        inputBroadcast.send(InputEvent(worn ? .worn : .removed, from: .glasses))
    }

    public func startMicrophone() async throws -> AsyncStream<[Int16]> {
        microphoneAttempts += 1
        if let microphoneDelay { try? await Task.sleep(for: microphoneDelay) }
        if let microphoneError { throw microphoneError }
        mic?.finish()
        let (stream, continuation) = AsyncStream<[Int16]>.makeStream()
        mic = continuation
        microphoneOn = true
        microphoneStarts += 1
        return stream
    }

    public func stopMicrophone() async {
        microphoneStops += 1
        microphoneOn = false
        mic?.finish()
        mic = nil
    }

    /// Ends the open microphone stream as if the firmware stopped the mic (the link stays up).
    public func dropMicrophone() {
        mic?.finish()
        mic = nil
        microphoneOn = false
    }

    /// Deliver PCM to the open microphone stream.
    public func sendAudio(_ samples: [Int16]) { mic?.yield(samples) }

    public func setHeadTracking(_ enabled: Bool) async {
        if headTrackingDelay > .zero { try? await Task.sleep(for: headTrackingDelay) }
        headTracking = enabled
        headTrackingCalls.append(enabled)
    }

    public func imuSamples() -> AsyncStream<IMUSample> { imuBroadcast.stream() }

    /// Deliver a gravity sample to every `imuSamples()` stream (only while head tracking is on,
    /// like the real link).
    public func sendIMU(x: Float, y: Float, z: Float) {
        guard headTracking else { return }
        imuBroadcast.send(IMUSample(x: x, y: y, z: z))
    }

    // MARK: Navigation

    public func sendNavigation(_ payload: [UInt8]) async {
        navigationPayloads.append(payload)
    }

    public func navigationRequest(_ payload: [UInt8]) async throws -> G2Message {
        if let navigationRequestError { throw navigationRequestError }
        navigationPayloads.append(payload)
        return G2Message(sid: G2Service.navigation, flag: G2Flag.request, seq: 0, payload: navigationReply ?? payload)
    }

    public func navigationEvents() -> AsyncStream<G2NavigationEvent> { navigationBroadcast.stream() }

    /// Deliver a glasses-initiated navigation event to every `navigationEvents()` stream.
    public func sendNavEvent(_ event: G2NavigationEvent) { navigationBroadcast.send(event) }
}
