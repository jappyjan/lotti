import CoreLocation
import Foundation
import Testing
@testable import LottiKit

@MainActor
struct NavigationSessionTests {
    private let start = CLLocationCoordinate2D(latitude: 52.52, longitude: 13.40)
    private let corner = CLLocationCoordinate2D(latitude: 52.5209, longitude: 13.40)
    private let end = CLLocationCoordinate2D(latitude: 52.5209, longitude: 13.4020)

    private func route(from: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 52.52, longitude: 13.40)) -> Route {
        Route(
            mode: .walking,
            destination: "Mauerpark",
            destinationCoordinate: end,
            steps: [
                RouteStep(instruction: "Head north", maneuver: .departure, roadName: nil, distance: 100,
                          points: [from, corner]),
                RouteStep(instruction: "Turn right onto Torstraße", maneuver: .turnRight, roadName: "Torstraße",
                          distance: 102, points: [corner, CLLocationCoordinate2D(latitude: 52.5209, longitude: 13.4015)]),
                RouteStep(instruction: "Arrive at the destination", maneuver: .arrive, roadName: nil,
                          distance: 34,
                          points: [CLLocationCoordinate2D(latitude: 52.5209, longitude: 13.4015), end]),
            ],
            totalDistance: 236,
            expectedTravelTime: 300)
    }

    private func fix(_ latitude: Double, _ longitude: Double) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 1, timestamp: Date())
    }

    private func commands(_ link: FakeGlassesLink) -> [UInt64] {
        link.navigationPayloads.map { ProtoReader.varintFields($0)[1] ?? 0 }
    }

    private func makeSession(_ link: FakeGlassesLink, map: (any NavMapProviding)? = nil) -> NavigationSession {
        NavigationSession(link: link, mapProvider: map) { _, _ in nil }
    }

    @Test func startOpensTheScreenAndSendsAPlaceholder() async {
        let link = FakeGlassesLink()
        let (stream, feed) = AsyncStream<CLLocation>.makeStream()
        let session = makeSession(link)
        let task = Task { await session.start(locations: stream, destination: "Mauerpark", mode: .walking) }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(commands(link).contains(G2Navigation.cmdStart))
        #expect(commands(link).contains(G2Navigation.cmdBasicInfo))  // the placeholder card
        #expect(link.displaySuspended)
        feed.finish()
        await task.value
        #expect(session.phase == .stopped)
        #expect(!link.displaySuspended)
    }

    @Test func heartbeatsKeepTheScreenAlive() async {
        let link = FakeGlassesLink()
        let (stream, feed) = AsyncStream<CLLocation>.makeStream()
        let session = makeSession(link)
        session.heartbeatInterval = .milliseconds(30)
        let task = Task { await session.start(locations: stream, destination: "Mauerpark", mode: .walking) }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(commands(link).filter { $0 == G2Navigation.cmdHeartbeat }.count >= 2)
        feed.finish()
        await task.value
    }

    @Test func theRouteArrivesLaterAndDrivesTheScreen() async {
        let link = FakeGlassesLink()
        let (stream, feed) = AsyncStream<CLLocation>.makeStream()
        var ended: NavigationSession.Phase?
        let session = makeSession(link)
        session.onEnd = { ended = $0 }
        let task = Task { await session.start(locations: stream, destination: "Mauerpark", mode: .walking) }
        try? await Task.sleep(for: .milliseconds(50))
        session.setRoute(route())
        feed.yield(fix(52.5209, 13.4023))  // near the destination
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ended == .arrived)
        #expect(commands(link).contains(G2Navigation.cmdArrive))
        #expect(!link.displaySuspended)
        feed.finish()
        await task.value
    }

    @Test func theUserLeavingTheScreenStopsTheSession() async {
        let link = FakeGlassesLink()
        let (stream, feed) = AsyncStream<CLLocation>.makeStream()
        var ended: NavigationSession.Phase?
        let session = makeSession(link)
        session.onEnd = { ended = $0 }
        let task = Task { await session.start(locations: stream, destination: "Mauerpark", mode: .walking) }
        try? await Task.sleep(for: .milliseconds(50))
        link.sendNavEvent(.notifyExit)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ended == .stopped)
        #expect(!link.displaySuspended)
        feed.finish()
        await task.value
    }

    @Test func goingOffRouteRecalculatesFromTheCurrentLocation() async {
        let link = FakeGlassesLink()
        let (stream, feed) = AsyncStream<CLLocation>.makeStream()
        var replanned: (location: CLLocation, mode: NavigationMode)?
        let session = NavigationSession(link: link) { location, mode in
            replanned = (location, mode)
            return route(from: location.coordinate)
        }
        let task = Task { await session.start(locations: stream, destination: "Mauerpark", mode: .walking) }
        try? await Task.sleep(for: .milliseconds(50))
        session.setRoute(route())
        feed.yield(fix(52.53, 13.40))  // ~1 km off route
        try? await Task.sleep(for: .milliseconds(100))
        #expect(replanned?.mode == .walking)
        #expect(commands(link).contains(G2Navigation.cmdRecalculating))
        #expect(session.phase == .navigating)
        feed.finish()
        await task.value
    }

    @Test func aFailedPlanningClosesTheScreenWithAnError() async {
        let link = FakeGlassesLink()
        let (stream, feed) = AsyncStream<CLLocation>.makeStream()
        var ended: NavigationSession.Phase?
        let session = makeSession(link)
        session.onEnd = { ended = $0 }
        let task = Task { await session.start(locations: stream, destination: "Mauerpark", mode: .walking) }
        try? await Task.sleep(for: .milliseconds(50))
        session.failPlanning("No place called Mauerpark found near Jan.")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ended == .stopped)
        #expect(commands(link).contains(G2Navigation.cmdErrorInfo))
        #expect(!link.displaySuspended)
        feed.finish()
        await task.value
    }

    @Test func stopClosesTheScreenAndSuspendsNothing() async {
        let link = FakeGlassesLink()
        let (stream, feed) = AsyncStream<CLLocation>.makeStream()
        let session = makeSession(link)
        let task = Task { await session.start(locations: stream, destination: "Mauerpark", mode: .walking) }
        try? await Task.sleep(for: .milliseconds(50))
        session.stop()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(commands(link).contains(G2Navigation.cmdStop))
        #expect(session.phase == .stopped)
        #expect(!link.displaySuspended)
        feed.finish()
        await task.value
    }

    @Test func aRefusedStartEndsRightAway() async {
        let link = FakeGlassesLink()
        link.navigationReply = G2Navigation.errorInfo(magic: 1, message: "nope")
        let (stream, feed) = AsyncStream<CLLocation>.makeStream()
        var ended: NavigationSession.Phase?
        let session = makeSession(link)
        session.onEnd = { ended = $0 }
        let task = Task { await session.start(locations: stream, destination: "Mauerpark", mode: .walking) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ended == .stopped)
        #expect(!link.displaySuspended)
        feed.finish()
        await task.value
    }

    // MARK: Map views

    struct FakeMapProvider: NavMapProviding {
        func bitmap(for request: NavMapRequest) async -> NavMapBitmap? {
            NavMapBitmap(width: 4, height: 4, rgba: [UInt8](repeating: 0, count: 64))
        }
    }

    @Test func switchingToAMapViewStreamsTheMap() async {
        let link = FakeGlassesLink()
        let (stream, feed) = AsyncStream<CLLocation>.makeStream()
        let session = makeSession(link, map: FakeMapProvider())
        let task = Task { await session.start(locations: stream, destination: "Mauerpark", mode: .walking) }
        try? await Task.sleep(for: .milliseconds(50))
        session.setRoute(route())
        feed.yield(fix(52.5203, 13.40))  // a location fix, so there's something to map
        try? await Task.sleep(for: .milliseconds(50))

        // View 2 is the full map.
        link.sendNavEvent(.viewChanged(view: 2))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(commands(link).contains(G2Navigation.cmdMaxMap))

        // View 1 is the arrow view with the small map next to it.
        link.sendNavEvent(.viewChanged(view: 1))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(commands(link).contains(G2Navigation.cmdMiniMap))

        feed.finish()
        await task.value
    }
}
