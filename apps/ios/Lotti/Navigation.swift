import CoreLocation
import Foundation
import LottiKit
import MapKit

/// Owns navigation on the phone: resolves destinations, plans MapKit routes, and runs the
/// `NavigationSession` that drives the firmware's nav screen. One trip at a time.
///
/// The tap opens the nav screen right away; MapKit planning runs in the background and the
/// route streams in when ready (`session.setRoute`). A slow or failed search never blocks the
/// screen: `failPlanning` closes it with an error after a deadline.
@MainActor
final class NavigationController {
    private let link: any GlassesLink
    private let today: DeviceToday
    private let planner = RoutePlanner()
    /// Renders the nav maps; keeps the last ones for the Debug section.
    let renderer = NavMapRenderer()
    private var session: NavigationSession?
    private var locationTask: Task<Void, Never>?
    private var planningTask: Task<Void, Never>?
    private var destination: MKMapItem?

    init(link: any GlassesLink, today: DeviceToday) {
        self.link = link
        self.today = today
    }

    /// The `start_navigation` tool body: opens the trip on the glasses and plans the route in
    /// the background. Returns the sentence Lotti says when the action runs — never waits for a
    /// location fix or the route, so the tool can't time out.
    func start(destination name: String, mode: NavigationMode) async throws -> String {
        stop()
        // The tap opens the screen right away; MapKit planning runs in the background and the
        // route streams in when ready (`session.setRoute`). Planning starts from the cached fix,
        // or from the session stream's first live fix when there is none — the stream feeds both
        // the session and the planner.
        let session = NavigationSession(link: link, mapProvider: renderer) { [weak self] location, mode in
            guard let self, let place = self.destination else { return nil }
            return try? await self.planner.route(from: location.coordinate, to: place, mode: mode)
        }
        session.onEnd = { [weak self] phase in
            print("[Nav] session ended: \(phase)")
            self?.session = nil
            self?.destination = nil
        }
        self.session = session
        let (sessionStream, sessionFeed) = AsyncStream<CLLocation>.makeStream(bufferingPolicy: .bufferingNewest(10))
        let (plannerStream, plannerFeed) = AsyncStream<CLLocation>.makeStream(bufferingPolicy: .bufferingNewest(10))
        let updates = Task { [sessionFeed, plannerFeed] in
            let service = CLServiceSession(authorization: .whenInUse)
            defer {
                service.invalidate()
                sessionFeed.finish()
                plannerFeed.finish()
            }
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    if let location = update.location {
                        sessionFeed.yield(location)
                        plannerFeed.yield(location)
                    }
                    if update.authorizationDenied || Task.isCancelled { return }
                }
            } catch {
                print("[Nav] location stream ended: \(error.localizedDescription)")
            }
        }
        let cached = await today.lastKnownLocation()
        locationTask = Task { [weak self] in
            await self?.run(session, stream: sessionStream, destination: name, mode: mode, updates: updates)
        }
        planningTask = Task { [weak self, weak session] in
            await self?.plan(session: session, name: name, mode: mode, cached: cached, locations: plannerStream)
        }
        return "Navigating to \(name) \(mode.spoken)."
    }

    /// Ends a running trip, if any.
    func stop() {
        planningTask?.cancel()
        planningTask = nil
        locationTask?.cancel()
        locationTask = nil
        session?.stop()
        session = nil
        destination = nil
    }

    /// Resolves the place and plans the route; on success hands it to the session, on failure
    /// closes the screen with an error. Each MapKit call has a deadline: they have no timeout
    /// of their own and can hang for minutes. Without a cached fix, waits for the session
    /// stream's first live fix (the tap already opened the screen, so waiting is fine here).
    private func plan(
        session: NavigationSession?, name: String, mode: NavigationMode,
        cached: CLLocationCoordinate2D?, locations: AsyncStream<CLLocation>
    ) async {
        let here: CLLocationCoordinate2D
        if let cached {
            here = cached
        } else {
            print("[Nav] waiting for the first location fix")
            var iterator = locations.makeAsyncIterator()
            guard let first = await iterator.next() else {
                session?.failPlanning("Lotti couldn't get a location fix.")
                return
            }
            here = first.coordinate
        }
        do {
            let box = try await withDeadline(10, "finding the place took too long") {
                let started = Date()
                let place = await RoutePlanner.findPlace(name, near: here)
                print("[Nav] place search: \(place?.name ?? "nothing") in \(Self.s(Date().timeIntervalSince(started)))")
                return SendableBox(place)
            }
            guard let place = box.value else { throw ToolError("No place called \(name) found near Jan.") }
            destination = place
            let route = try await withDeadline(15, "planning the route took too long") { [self] in
                let started = Date()
                let route = try await planner.route(from: here, to: place, mode: mode)
                print("[Nav] route: \(route.steps.count) steps, \(Int(route.totalDistance)) m in \(Self.s(Date().timeIntervalSince(started)))")
                return route
            }
            session?.setRoute(route)
        } catch {
            session?.failPlanning(error.localizedDescription)
        }
    }

    /// Feeds the session location fixes while it runs, then stops the stream.
    private func run(
        _ session: NavigationSession, stream: AsyncStream<CLLocation>,
        destination: String, mode: NavigationMode, updates: Task<Void, Never>
    ) async {
        defer { updates.cancel() }
        await session.start(locations: stream, destination: destination, mode: mode)
    }

    private static func s(_ seconds: TimeInterval) -> String {
        String(format: "%.1f s", seconds)
    }
}

/// A `Sendable` wrapper for values that only ever travel on the main actor (like `MKMapItem`).
final class SendableBox<Wrapped>: @unchecked Sendable {
    let value: Wrapped
    init(_ value: Wrapped) { self.value = value }
}

/// Runs `work` with a deadline; throws `ToolError(message)` after `seconds` (the work task is
/// cancelled then). MapKit's search and directions calls have no timeout of their own.
@MainActor
func withDeadline<T: Sendable>(_ seconds: Double, _ message: String, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ToolError(message)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw ToolError(message) }
        return first
    }
}
