import CoreLocation
import Foundation

/// Drives the firmware's navigation screen for one trip: opens it, keeps it alive with a
/// heartbeat, pushes frames — a progress card followed by the map of the view the glasses show —
/// on every step change and while you move, reroutes when you leave the route, and closes the
/// screen on arrival, stop or when you leave it on the glasses.
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
    private var lastLocation: CLLocation?
    /// The view the glasses show: the screen opens on the arrow view with the mini map; a
    /// `viewChanged` other than 1 switches to the full map (the Even app's rule).
    private var mapView: NavMapRequest.Kind = .mini
    /// The glasses' own compass heading (degrees), which turns the mini map.
    private var glassesHeading: Double?
    /// `basicInfoIndex` of the next card: counts every pushed frame, reset with each route.
    private var frameIndex: UInt64 = 0
    private var lastFramePush: Date = .distantPast
    private var pushing = false
    private var pushPending = false
    /// What the last full map showed: it's resent only when this moved on (`_shouldSendOverviewMap`).
    private var lastOverview: (sent: Date, heading: Double?, location: CLLocation)?
    /// One session id counter for both maps, wrapping 0…255 (the app's `nextSessionId`).
    private var mapSessionID: UInt64 = 0

    /// Seconds between heartbeats; the screen ends the session if none lands for 30 s.
    public var heartbeatInterval: Duration = .seconds(5)
    /// Shortest gap between two frames (card + map) pushed for location updates alone; a new
    /// step or a view change pushes right away.
    public var frameInterval: Duration = .seconds(2)
    /// The full map is resent at most this often, and only once the picture moved on.
    public var overviewInterval: Duration = .seconds(5)

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
        // Subscribe before anything is sent: an event from the glasses right after the screen
        // opens (or a slow task start) must not be lost.
        let events = link.navigationEvents()

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
        eventsTask = Task { @MainActor [weak self] in await self?.handleEvents(events) }
        await run(locations: locations)
    }

    /// The route is ready: swap it in and send the first real card.
    public func setRoute(_ route: Route) {
        guard isRunning else { return }
        mode = route.mode
        restart(with: route)
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

    private func handleEvents(_ events: AsyncStream<G2NavigationEvent>) async {
        for await event in events {
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
                // 1 = the arrow view with the mini map; anything else is the full map (the Even
                // app keeps exactly this flag and lets the next frame carry the right map).
                mapView = view == 1 ? .mini : .full
                print("[Nav] view changed to \(view)")
                requestFrame(now: true)
            case .compassChanged(let value):
                // The glasses' heading: it decides when the full map is due again.
                glassesHeading = Double(value % 360)
            case .locationSelected, .compassCalibrateStart, .compassCalibrateDone, .other:
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
            let newStep = card.counter != lastCounter
            lastCounter = card.counter
            requestFrame(now: newStep)
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

    // MARK: Frames

    /// Pushes a frame: the progress card, then — once the glasses took it — the map of the view
    /// they show. That's the Even app's `MapImagePusher` cycle: the card always goes first, its
    /// `basicInfoIndex` counts the frames, the mini map rides along with every frame on the
    /// arrow view, the full map only when its picture moved on. `now` skips the frame interval
    /// (new step, view change); a request during a push runs one more frame after it.
    private func requestFrame(now: Bool = false) {
        guard isRunning, lastCard != nil else { return }
        if pushing {
            pushPending = true
            return
        }
        let due = Date().timeIntervalSince(lastFramePush) >= seconds(frameInterval)
        guard now || due else { return }
        pushing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pushing = false }
            repeat {
                self.pushPending = false
                await self.pushFrame()
            } while self.pushPending && self.isRunning
        }
    }

    private func pushFrame() async {
        guard phase == .navigating, let card = lastCard, let mode else { return }
        lastFramePush = Date()
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
            counter: frameIndex
        )
        do {
            let reply = try await link.navigationRequest(payload)
            guard G2Navigation.replyError(reply.payload) == 0 else {
                print("[Nav] the glasses rejected a card")
                return
            }
        } catch {
            print("[Nav] no answer for a card: \(error.localizedDescription)")
            return
        }
        frameIndex += 1
        guard phase == .navigating else { return }
        switch mapView {
        case .mini: await sendMap(kind: .mini)
        case .full: if overviewDue() { await sendMap(kind: .full) }
        }
    }

    /// The app's `_shouldSendOverviewMap`: the first time, then at most every
    /// `overviewInterval`, and only once the heading turned > 15° or Jan moved on (≥ 1 % of the
    /// route) — otherwise the glasses keep showing the last one.
    private func overviewDue() -> Bool {
        guard let last = lastOverview else { return true }
        guard Date().timeIntervalSince(last.sent) >= seconds(overviewInterval) else { return false }
        let heading = currentHeading
        if (last.heading == nil) != (heading == nil) { return true }
        if let a = last.heading, let b = heading {
            let turn = abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180)
            if turn >= 15 { return true }
        }
        guard let location = lastLocation, let tracker else { return false }
        return location.distance(from: last.location) >= max(tracker.route.totalDistance, 1) * 0.01
    }

    /// The glasses' compass when they report one, else the phone's course.
    private var currentHeading: Double? {
        glassesHeading ?? lastLocation.flatMap { $0.course >= 0 ? $0.course : nil }
    }

    private func sendMap(kind: NavMapRequest.Kind) async {
        guard let provider = mapProvider, let location = lastLocation, let tracker else { return }
        let heading = currentHeading
        let routePoints = tracker.route.steps.flatMap(\.points)
        let request = NavMapRequest(
            kind: kind, coordinate: location.coordinate, heading: heading, route: routePoints)
        guard let bitmap = await provider.bitmap(for: request) else {
            print("[Nav] no \(kind) map bitmap")
            return
        }
        // RGBA → 4 bpp BMP (green roads, red route) → LZ4 (mode 2), or raw (mode 0) when that
        // doesn't shrink it (the app's rule).
        guard let frame = NavMapBmp.encode(rgba: bitmap.rgba, width: bitmap.width, height: bitmap.height) else {
            print("[Nav] couldn't encode the \(kind) map bitmap")
            return
        }
        // The Even app leaves `rotationAngle` at 0 even while the compass reports (trace).
        let rotation: UInt64 = 0
        switch kind {
        case .mini:
            // A mini map ≤ 8192 bytes is one message without session fields (the app's rule).
            if frame.data.count <= 8192 {
                await sendMapFragment(G2Navigation.miniMapFragment(
                    magic: nextMagic(), size: UInt64(frame.data.count),
                    compressMode: frame.mode.rawValue, data: frame.data, rotationAngle: rotation))
            } else {
                let sessionID = nextMapSessionID()
                for (index, chunk) in chunks(of: frame.data, size: 8192).enumerated() {
                    await sendMapFragment(G2Navigation.miniMapFragment(
                        magic: nextMagic(), size: UInt64(frame.data.count),
                        compressMode: frame.mode.rawValue, data: chunk, rotationAngle: rotation,
                        sessionID: sessionID, index: UInt64(index), packetSize: UInt64(chunk.count)))
                }
            }
        case .full:
            let sessionID = nextMapSessionID()
            for (index, chunk) in chunks(of: frame.data, size: 4096).enumerated() {
                await sendMapFragment(G2Navigation.maxMapFragment(
                    magic: nextMagic(), sessionID: sessionID, totalSize: UInt64(frame.data.count),
                    compressMode: frame.mode.rawValue, index: UInt64(index),
                    packetSize: UInt64(chunk.count), data: chunk))
            }
            lastOverview = (Date(), heading, location)
        }
        print("[Nav] \(kind) map sent (\(bitmap.width)×\(bitmap.height), \(frame.data.count) bytes, "
              + "\(frame.mode == .lz4 ? "lz4" : "raw"))")
    }

    /// Sends one map message and checks the firmware's answer: every fragment gets a reply
    /// carrying an `errorCode`, 0 = success (the Even app retries timeouts up to 4×).
    private func sendMapFragment(_ payload: [UInt8]) async {
        let cmd = ProtoReader.varintFields(payload)[1]
        do {
            let reply = try await link.navigationRequest(payload)
            let error = G2Navigation.mapReplyError(reply.payload, mini: cmd == G2Navigation.cmdMiniMap)
            if error != 0 {
                print("[Nav] the glasses rejected a map fragment (error \(error))")
            }
        } catch {
            print("[Nav] no answer for a map fragment: \(error.localizedDescription)")
        }
    }

    private func chunks(of data: [UInt8], size: Int) -> [[UInt8]] {
        stride(from: 0, to: data.count, by: size).map { Array(data[$0..<min($0 + size, data.count)]) }
    }

    private func nextMapSessionID() -> UInt64 {
        mapSessionID = (mapSessionID + 1) & 0xFF
        return mapSessionID
    }

    /// A new route: the frame index and the full map start over (the app's `reset`).
    private func restart(with route: Route) {
        tracker = StepTracker(route: route)
        lastCounter = -1
        lastCard = nil
        frameIndex = 0
        lastFramePush = .distantPast
        lastOverview = nil
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
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
            restart(with: route)
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
