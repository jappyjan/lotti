import Foundation
import Observation

/// Drives the mascot (the raccoon that wears glasses when yours are on): purely cosmetic, and
/// nothing else depends on it. The view calls `start()` when it is on screen in the foreground and
/// `stop()` otherwise (disappear, background); `enabled` is the settings switch.
///
/// - The glasses pose follows the link's connection and wear state (debounced, off when unknown).
/// - While started, enabled and worn, the controller takes an `IMUDemand` token and turns gravity
///   samples into `pitch` / `roll` targets for the view to ease to over `animationDuration`.
/// - Without a usable IMU (no samples within `noSampleTimeout`) the head stays neutral, the wear
///   pose keeps working, and one line is logged. Nothing is thrown or shown.
@MainActor
@Observable
public final class MascotController {
    public private(set) var glassesOn = false
    /// Whether the view should animate the latest change of `glassesOn`.
    public private(set) var animated = false
    /// Degrees, from `HeadAngleMapper`: nod (positive up), tilt, and yaw (always 0).
    public private(set) var pitch = 0.0
    public private(set) var roll = 0.0
    public private(set) var yaw = 0.0
    /// True while the head follows real samples.
    public private(set) var headSyncActive = false
    /// How long the view should take to ease to the latest target.
    public private(set) var animationDuration: TimeInterval = 1
    public private(set) var isStarted = false

    /// The settings switch. Off behaves like stopped.
    public var enabled = true {
        didSet { if enabled != oldValue { reconcile() } }
    }

    @ObservationIgnored private let link: any GlassesLink
    @ObservationIgnored private let demand: IMUDemand
    @ObservationIgnored private let clock: @Sendable () -> TimeInterval
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async -> Void
    @ObservationIgnored private let logger: @Sendable (String) -> Void
    @ObservationIgnored private let noSampleTimeout: TimeInterval
    @ObservationIgnored private var wear: MascotWearMapper
    @ObservationIgnored private var head = HeadAngleMapper()
    @ObservationIgnored private var running = false
    @ObservationIgnored private var headRequested = false
    @ObservationIgnored private var token: IMUDemand.Token?
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var wearTimer: Task<Void, Never>?
    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var lastSample: TimeInterval?
    @ObservationIgnored private var headStartedAt: TimeInterval = 0
    @ObservationIgnored private var degradedLogged = false

    /// - Parameters:
    ///   - demand: share the app's one `IMUDemand` (`Conductor.imuDemand`) with head-up detection.
    ///   - clock: seconds on a monotonic clock; tests inject their own.
    ///   - sleep: waits; tests inject one that never returns and call `tick()` / `checkHealth()`.
    public init(
        link: any GlassesLink, demand: IMUDemand, debounce: TimeInterval = 1, noSampleTimeout: TimeInterval = 5,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        log: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.link = link
        self.demand = demand
        self.wear = MascotWearMapper(debounce: debounce)
        self.noSampleTimeout = noSampleTimeout
        self.clock = clock
        self.sleep = sleep
        self.logger = log
    }

    /// The mascot is on screen in the foreground.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        reconcile()
    }

    /// The mascot left the screen or the app went to the background.
    public func stop() {
        guard isStarted else { return }
        isStarted = false
        reconcile()
    }

    /// Looks at the link and the clock again; called by the debounce timer, and by tests.
    public func tick() {
        guard running else { return }
        let pose = wear.update(wear: link.wearState, connected: link.status.isConnected, at: clock())
        if glassesOn != pose.glassesOn { glassesOn = pose.glassesOn }
        if animated != pose.animated { animated = pose.animated }
        scheduleWearTimer()
        updateHead()
    }

    /// Declares the head neutral if samples stopped coming; called by the watchdog, and by tests.
    public func checkHealth() {
        guard headRequested else { return }
        let reference = lastSample ?? headStartedAt
        guard clock() - reference >= noSampleTimeout else { return }
        if headSyncActive || !degradedLogged {
            if !degradedLogged { logger("[Mascot] no IMU samples for \(Int(noSampleTimeout)) s, head stays neutral") }
            degradedLogged = true
            headSyncActive = false
            setAngles(.neutral)
        }
    }

    /// Waits for pending IMU acquire/release work (for tests and orderly shutdown).
    public func settled() async {
        while let current = chain {
            await current.value
            if chain == current { break }
        }
    }

    // MARK: - Internals

    private func reconcile() {
        let shouldRun = isStarted && enabled
        guard shouldRun != running else { return }
        running = shouldRun
        epoch += 1
        if shouldRun {
            wear = MascotWearMapper(debounce: wear.debounce)  // first appearance: no animation
            tick()
            observeLink()
        } else {
            wearTimer?.cancel()
            updateHead()
        }
    }

    private func observeLink() {
        let current = epoch
        withObservationTracking {
            _ = link.status
            _ = link.wearState
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.epoch == current, self.running else { return }
                self.tick()
                self.observeLink()
            }
        }
    }

    private func scheduleWearTimer() {
        wearTimer?.cancel()
        guard let deadline = wear.pendingDeadline else { return }
        let wait = max(0, deadline - clock())
        wearTimer = Task { [weak self, sleep] in
            await sleep(wait)
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    private func updateHead() {
        let want = running && glassesOn
        guard want != headRequested else { return }
        headRequested = want
        if want {
            lastSample = nil
            headStartedAt = clock()
            degradedLogged = false
            enqueue { await $0.beginHead() }
        } else {
            headSyncActive = false
            head.reset()
            setAngles(.neutral)
            enqueue { await $0.endHead() }
        }
    }

    private func enqueue(_ work: @escaping @MainActor (MascotController) async -> Void) {
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }

    private func beginHead() async {
        guard headRequested, token == nil else { return }
        // Subscribe first so no sample is missed, then ask for the feed.
        let stream = link.imuSamples()
        sampleTask = Task { [weak self] in
            for await sample in stream { self?.receive(sample) }
        }
        watchTask = Task { [weak self, sleep, noSampleTimeout] in
            while !Task.isCancelled {
                await sleep(noSampleTimeout)
                guard !Task.isCancelled else { return }
                self?.checkHealth()
            }
        }
        token = await demand.acquire("mascot")
    }

    private func endHead() async {
        sampleTask?.cancel()
        watchTask?.cancel()
        sampleTask = nil
        watchTask = nil
        if let token {
            self.token = nil
            await demand.release(token)
        }
    }

    private func receive(_ sample: IMUSample) {
        guard headRequested else { return }
        let now = clock()
        guard let angles = head.feed(sample, straightAhead: link.headUpSettings.straightAhead, at: now) else { return }
        lastSample = now
        degradedLogged = false
        headSyncActive = true
        animationDuration = head.suggestedDuration
        setAngles(angles)
    }

    private func setAngles(_ angles: HeadAngles) {
        if pitch != angles.pitch { pitch = angles.pitch }
        if roll != angles.roll { roll = angles.roll }
        if yaw != angles.yaw { yaw = angles.yaw }
    }
}
