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
    public private(set) var headTracking = false

    @ObservationIgnored private let inputBroadcast = Broadcast<InputEvent>()
    @ObservationIgnored private var mic: AsyncStream<[Int16]>.Continuation?

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

    public func startMicrophone() async throws -> AsyncStream<[Int16]> {
        if let microphoneError { throw microphoneError }
        let (stream, continuation) = AsyncStream<[Int16]>.makeStream()
        mic = continuation
        microphoneOn = true
        return stream
    }

    public func stopMicrophone() async {
        microphoneOn = false
        mic?.finish()
        mic = nil
    }

    /// Deliver PCM to the open microphone stream.
    public func sendAudio(_ samples: [Int16]) { mic?.yield(samples) }

    public func setHeadTracking(_ enabled: Bool) async { headTracking = enabled }
}
