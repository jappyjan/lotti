import CoreLocation
import Foundation

/// Drives the firmware's navigation screen for one trip: opens it, keeps it alive with a
/// heartbeat, sends a progress card on every step change (and at least every 5 s), reroutes when
/// you leave the route, and closes the screen on arrival, stop or when you leave it on the
/// glasses.
///
/// iOS has no turn-by-turn API for third-party apps, so Lotti tracks progress itself against the
/// MapKit route (`StepTracker`). The session is fed location fixes through `locations`; the app
/// produces that stream (with `CLLocationUpdate.liveUpdates`). The route arrives when it's ready:
/// `start` opens the screen with a placeholder, and the app calls `setRoute` once MapKit has
/// planned — so a slow planner never blocks the screen.
@MainActor
public final class NavigationSession {
    public enum Phase: Equatable, Sendable {
        case idle, navigating, recalculating, arrived, stopped
    }

    public private(set) var phase: Phase = .idle
    /// Called once when the session ends, with the final phase.
    public var onEnd: ((Phase) -> Void)?

    private let link: any GlassesLink
    private let replan: @MainActor (CLLocation, NavigationMode) async -> Route?
    private let mapProvider: (any NavMapProviding)?
    private var tracker: StepTracker?
    private var mode: NavigationMode?
    private var magic: UInt64 = 1
    private var heartbeatTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var lastCard: NavProgress?
    private var lastCounter = -1
    private var lastCardSent: Date = .distantPast
    private var lastLocation: CLLocation?
    /// The map view the glasses show (from `viewChanged`): nil when there's no map to stream.
    private var mapView: NavMapRequest.Kind?
    private var lastMapSent: Date = .distantPast
    private var mapSending = false
    /// Each full-map frame gets a new session id; bump by more than 1 after trouble (g2-kit).
    private var mapSessionID: UInt64 = 1

    /// Seconds between heartbeats; the screen ends the session if none lands for 30 s.
    public var heartbeatInterval: Duration = .seconds(5)
    /// Send a card again after this long even when nothing changed.
    public var refreshInterval: Duration = .seconds(5)
    /// Send the map again after this long while a map view is showing.
    public var mapRefreshInterval: Duration = .seconds(15)

    public init(
        link: any GlassesLink,
        mapProvider: (any NavMapProviding)? = nil,
        replan: @escaping @MainActor (CLLocation, NavigationMode) async -> Route?
    ) {
        self.link = link
        self.mapProvider = mapProvider
        self.replan = replan
    }

    /// Opens the navigation screen (with a placeholder card) and runs until the trip ends: the
    /// location stream ends, you arrive, `stop()` is called, or you leave the screen on the
    /// glasses. The app calls `setRoute` when the route is planned.
    public func start(locations: AsyncStream<CLLocation>, destination: String, mode: NavigationMode) async {
        guard phase == .idle else { return }
        phase = .navigating
        self.mode = mode
        link.displaySuspended = true

        do {
            let reply = try await link.navigationRequest(G2Navigation.start(magic: nextMagic()))
            guard G2Navigation.replyError(reply.payload) == 0 else {
                print("[Nav] the glasses refused to open the navigation screen")
                end(.stopped)
                return
            }
        } catch {
            // No ack: proceed anyway; what counts is the screen coming up (like the mic).
            print("[Nav] no ack for START: \(error.localizedDescription)")
        }
        // A placeholder card while MapKit plans: the destination name, dashes for the numbers.
        let placeholder = G2Navigation.basicInfo(
            magic: nextMagic(), direction: NavigateDirectionSign.straight.rawValue,
            road: destination, method: mode.method)
        await link.sendNavigation(placeholder)

        startHeartbeat()
        eventsTask = Task { @MainActor [weak self] in await self?.handleEvents() }
        await run(locations: locations)
    }

    /// The route is ready: swap it in and send the first real card.
    public func setRoute(_ route: Route) {
        guard isRunning else { return }
        mode = route.mode
        tracker = StepTracker(route: route)
        lastCounter = -1
        lastCardSent = .distantPast
        lastCard = nil
        print("[Nav] route set: \(route.steps.count) steps, \(Int(route.totalDistance)) m")
        if let lastLocation { handleLocation(lastLocation) }
    }

    /// MapKit couldn't plan the route: tell the screen and close it.
    public func failPlanning(_ message: String) {
        guard isRunning else { return }
        print("[Nav] planning failed: \(message)")
        Task { await link.sendNavigation(G2Navigation.errorInfo(magic: nextMagic(), message: message)) }
        end(.stopped)
    }

    /// The app cancels the trip (new session, glasses disconnected, …).
    public func stop() {
        guard isRunning else { return }
        Task { await link.sendNavigation(G2Navigation.stop(magic: nextMagic())) }
        end(.stopped)
    }

    private var isRunning: Bool {
        phase == .navigating || phase == .recalculating
    }

    // MARK: - Loops

    private func run(locations: AsyncStream<CLLocation>) async {
        defer {
            eventsTask?.cancel()
            end(.stopped)
        }
        for await location in locations {
            guard isRunning else { return }
            handleLocation(location)
        }
    }

    private func handleEvents() async {
        for await event in link.navigationEvents() {
            guard isRunning else { return }
            switch event {
            case .notifyExit, .endSessionReq:
                // The user left the screen; the firmware is already tearing down.
                print("[Nav] user left the navigation screen")
                end(.stopped)
            case .switchTransportReq(let method, let magic):
                let requested: NavigationMode? = switch method {
                case G2Navigation.methodCycling: .cycling
                case G2Navigation.methodWalking: .walking
                default: nil
                }
                _ = try? await link.navigationRequest(G2Navigation.switchTransportResponse(magic: magic))
                guard let requested, let mode, requested != mode else { continue }
                print("[Nav] switching to \(requested.rawValue)")
                await replanWith(mode: requested)
            case .menuStartup(let magic):
                // Navigation launched from the glasses' menu: no favorites yet.
                _ = try? await link.navigationRequest(G2Navigation.locationNone(magic: magic))
            case .viewChanged(let view):
                // 1 = arrow view (with a small map next to it), 2 = the full map view
                // (the Even app's order; the firmware shows "Karte wird geladen" until the
                // right bitmap arrives).
                mapView = switch view {
                case 1: .mini
                case 2, 3: .full
                default: nil
                }
                print("[Nav] view changed to \(view)")
                lastMapSent = .distantPast
                Task { await sendMap() }
            case .locationSelected, .compassChanged, .compassCalibrateStart, .compassCalibrateDone, .other:
                break
            }
        }
    }

    private func handleLocation(_ location: CLLocation) {
        guard phase == .navigating else { return }
        lastLocation = location
        guard var tracker else { return }  // no route yet: nothing to track
        switch tracker.update(location) {
        case .progress(let card):
            self.tracker = tracker
            lastCard = card
            sendCardIfNeeded()
            Task { await sendMapIfStale() }
        case .unreliable:
            self.tracker = tracker
        case .arrived:
            self.tracker = tracker
            print("[Nav] arrived")
            Task { await link.sendNavigation(G2Navigation.arrive(magic: nextMagic())) }
            end(.arrived)
        case .offRoute:
            self.tracker = tracker
            print("[Nav] off route")
            Task { await replanFromCurrentLocation() }
        }
    }

    // MARK: Maps

    /// Streams the current map view's bitmap when the last frame is older than
    /// `mapRefreshInterval` (or a view change asked for one right away).
    private func sendMapIfStale() async {
        guard mapView != nil, !mapSending,
              Date().timeIntervalSince(lastMapSent) >= Double(mapRefreshInterval.components.seconds) else { return }
        await sendMap()
    }

    private func sendMap() async {
        guard !mapSending, let provider = mapProvider, let kind = mapView, let location = lastLocation,
              let tracker else { return }
        mapSending = true
        defer { mapSending = false }
        lastMapSent = Date()  // set up front: concurrent stale-checks can't stack sends
        let routePoints = tracker.route.steps.flatMap(\.points)
        let request = NavMapRequest(
            kind: kind, coordinate: location.coordinate,
            heading: location.course > 0 ? location.course : nil, route: routePoints)
        guard let bitmap = await provider.bitmap(for: request) else {
            print("[Nav] no \(kind) map bitmap")
            return
        }
        switch kind {
        case .mini:
            let rotation = request.heading.map { UInt64($0.rounded()) } ?? 0
            let payload = G2Navigation.miniMap(magic: nextMagic(), data: bitmap.pixels,
                                               rotationAngle: rotation, border: 1)
            await link.sendNavigation(payload)
            print("[Nav] mini map sent (\(bitmap.width)×\(bitmap.height), \(bitmap.pixels.count) bytes)")
        case .full:
            let chunkSize = 4096
            let chunks = stride(from: 0, to: bitmap.pixels.count, by: chunkSize).map {
                Array(bitmap.pixels[$0..<min($0 + chunkSize, bitmap.pixels.count)])
            }
            let sessionID = mapSessionID
            mapSessionID += 2  // g2-kit: larger steps keep a failed session from sticking
            for (index, chunk) in chunks.enumerated() {
                let payload = G2Navigation.maxMapFragment(
                    magic: nextMagic(), sessionID: sessionID, totalSize: UInt64(bitmap.pixels.count),
                    index: UInt64(index), packetSize: UInt64(chunk.count), data: chunk)
                await link.sendNavigation(payload)
            }
            print("[Nav] full map sent (\(bitmap.width)×\(bitmap.height), \(chunks.count) fragments)")
        }
    }

    private func sendCardIfNeeded() {
        guard let card = lastCard, let mode else { return }
        let changed = card.counter != lastCounter
        let stale = Date().timeIntervalSince(lastCardSent) >= Double(refreshInterval.components.seconds)
        guard changed || stale else { return }
        lastCounter = card.counter
        lastCardSent = Date()
        let payload = G2Navigation.basicInfo(
            magic: nextMagic(),
            direction: card.direction.rawValue,
            distance: card.distance,
            road: card.road,
            remainingTime: card.remainingTime,
            remainingDistance: card.remainingDistance,
            eta: card.eta,
            speed: card.speed,
            method: mode.method,
            counter: UInt64(card.counter)
        )
        Task { await link.sendNavigation(payload) }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.heartbeatInterval)
                guard !Task.isCancelled else { return }
                do {
                    _ = try await self.link.navigationRequest(G2Navigation.heartbeat(magic: self.nextMagic()))
                    failures = 0
                } catch {
                    failures += 1
                    print("[Nav] heartbeat failed (\(failures)): \(error.localizedDescription)")
                    if failures >= 6 {
                        print("[Nav] the screen stopped answering heartbeats; giving up")
                        self.end(.stopped)
                        return
                    }
                }
            }
        }
    }

    // MARK: - Rerouting

    private func replanFromCurrentLocation() async {
        guard let location = lastLocation, let mode, isRunning else { return }
        await replanWith(mode: mode, from: location)
    }

    private func replanWith(mode: NavigationMode, from location: CLLocation? = nil) async {
        guard let location = location ?? lastLocation, phase == .navigating, tracker != nil else { return }
        phase = .recalculating
        await link.sendNavigation(G2Navigation.recalculating(magic: nextMagic()))
        if let route = await replan(location, mode) {
            self.mode = route.mode
            self.tracker = StepTracker(route: route)
            lastCounter = -1
            lastCardSent = .distantPast
            lastCard = nil
            phase = .navigating
            handleLocation(location)
        } else {
            print("[Nav] no replacement route")
            await link.sendNavigation(G2Navigation.errorInfo(magic: nextMagic(), message: "No route found."))
            end(.stopped)
        }
    }

    // MARK: - End

    private func end(_ finalPhase: Phase) {
        guard isRunning else { return }
        phase = finalPhase
        mapView = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        link.displaySuspended = false
        onEnd?(finalPhase)
    }

    private func nextMagic() -> UInt64 {
        magic = magic >= 255 ? 1 : magic + 1
        return magic
    }
}
