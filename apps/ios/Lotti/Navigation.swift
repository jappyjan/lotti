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
    private var session: NavigationSession?
    private var locationTask: Task<Void, Never>?
    private var planningTask: Task<Void, Never>?
    private var destination: MKMapItem?

    init(link: any GlassesLink, today: DeviceToday) {
        self.link = link
        self.today = today
    }

    /// The `start_navigation` tool body: opens the trip on the glasses and plans the route in
    /// the background. Returns the sentence Lotti says when the action runs.
    func start(destination name: String, mode: NavigationMode) async throws -> String {
        stop()
        // Plan from the last known fix (instant); if the route starts a little off, the
        // session's own stream snaps and reroutes within seconds.
        var here = await today.lastKnownLocation()
        if here == nil { here = await today.freshLocation() }
        guard let here else {
            throw ToolError("Lotti doesn't know where Jan is.")
        }
        let session = NavigationSession(link: link, mapProvider: NavMapRenderer()) { [weak self] location, mode in
            guard let self, let place = self.destination else { return nil }
            return try? await self.planner.route(from: location.coordinate, to: place, mode: mode)
        }
        session.onEnd = { [weak self] phase in
            print("[Nav] session ended: \(phase)")
            self?.session = nil
            self?.destination = nil
        }
        self.session = session
        locationTask = Task { [weak self] in await self?.run(session, destination: name, mode: mode) }
        planningTask = Task { [weak self, weak session] in
            await self?.plan(session: session, name: name, mode: mode, from: here)
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
    /// of their own and can hang for minutes.
    private func plan(session: NavigationSession?, name: String, mode: NavigationMode, from here: CLLocationCoordinate2D) async {
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
    private func run(_ session: NavigationSession, destination: String, mode: NavigationMode) async {
        let (stream, continuation) = AsyncStream<CLLocation>.makeStream(bufferingPolicy: .bufferingNewest(10))
        let updates = Task { [continuation] in
            let service = CLServiceSession(authorization: .whenInUse)
            defer {
                service.invalidate()
                continuation.finish()
            }
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    if let location = update.location { continuation.yield(location) }
                    if update.authorizationDenied || Task.isCancelled { return }
                }
            } catch {
                print("[Nav] location stream ended: \(error.localizedDescription)")
            }
        }
        await session.start(locations: stream, destination: destination, mode: mode)
        updates.cancel()
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
