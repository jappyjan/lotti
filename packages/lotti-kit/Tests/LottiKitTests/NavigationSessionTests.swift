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
        // Poll instead of one fixed sleep: a loaded CI runner can starve the session's timer task.
        try? await eventually(timeout: 5) { commands(link).filter { $0 == G2Navigation.cmdHeartbeat }.count >= 2 }
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
        try? await eventually(timeout: 5) { session.phase == .navigating }
        session.setRoute(route())
        feed.yield(fix(52.5209, 13.4023))  // near the destination
        try? await eventually(timeout: 5) {
            ended == .arrived && commands(link).contains(G2Navigation.cmdArrive) && !link.displaySuspended
        }
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
        try? await eventually(timeout: 5) { session.phase == .navigating }  // subscribed to the glasses' events by then
        link.sendNavEvent(.notifyExit)
        try? await eventually(timeout: 5) { ended == .stopped }
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

    /// The navigation messages after START, as (cmd, sub-message) pairs.
    private func frames(_ link: FakeGlassesLink) -> [(cmd: UInt64, sub: [UInt8])] {
        link.navigationPayloads.compactMap { payload in
            let cmd = ProtoReader.varintFields(payload)[1] ?? 0
            let field: Int? = switch cmd {
            case G2Navigation.cmdBasicInfo: 5
            case G2Navigation.cmdMiniMap: 6
            case G2Navigation.cmdMaxMap: 7
            default: nil
            }
            guard let field else { return nil }
            return (cmd, ProtoReader.message(payload, field) ?? [])
        }
    }

    private func startRouted(_ link: FakeGlassesLink, _ session: NavigationSession) async
        -> (Task<Void, Never>, AsyncStream<CLLocation>.Continuation) {
        let (stream, feed) = AsyncStream<CLLocation>.makeStream()
        let task = Task { await session.start(locations: stream, destination: "Mauerpark", mode: .walking) }
        try? await eventually(timeout: 5) { session.phase == .navigating }
        session.setRoute(route())
        feed.yield(fix(52.5203, 13.40))  // a location fix, so there's something to map
        try? await Task.sleep(for: .milliseconds(100))
        return (task, feed)
    }

    @Test func everyMapRidesBehindACard() async {
        let link = FakeGlassesLink()
        let session = makeSession(link, map: FakeMapProvider())
        let (task, feed) = await startRouted(link, session)

        // The screen opens on the arrow view: the first frame already carries the mini map,
        // no swipe needed — and every map comes right after a card.
        let sent = frames(link)
        let firstMap = sent.firstIndex { $0.cmd == G2Navigation.cmdMiniMap }
        #expect(firstMap != nil)
        if let firstMap {
            #expect(firstMap > 0)
            #expect(sent[firstMap - 1].cmd == G2Navigation.cmdBasicInfo)
        }
        #expect(!sent.contains { $0.cmd == G2Navigation.cmdMaxMap })

        feed.finish()
        await task.value
    }

    @Test func theCardIndexCountsFrames() async {
        let link = FakeGlassesLink()
        let session = makeSession(link, map: FakeMapProvider())
        session.frameInterval = .zero
        let (task, feed) = await startRouted(link, session)
        feed.yield(fix(52.5204, 13.40))
        try? await Task.sleep(for: .milliseconds(100))
        feed.yield(fix(52.5205, 13.40))
        try? await Task.sleep(for: .milliseconds(100))

        // basicInfoIndex (field 10) runs 0, 1, 2… with each frame, even on the same step;
        // the placeholder card before the route carries none.
        let indices = frames(link).filter { $0.cmd == G2Navigation.cmdBasicInfo }.dropFirst()
            .map { ProtoReader.varintFields($0.sub)[10] ?? 0 }
        #expect(indices.count >= 3)
        #expect(Array(indices) == Array(0..<UInt64(indices.count)))

        feed.finish()
        await task.value
    }

    @Test func theFullMapViewGetsTheFullMapOnlyWhenItMovedOn() async {
        let link = FakeGlassesLink()
        let session = makeSession(link, map: FakeMapProvider())
        session.frameInterval = .zero
        let (task, feed) = await startRouted(link, session)

        // Any view but 1 is the full map.
        link.sendNavEvent(.viewChanged(view: 2))
        try? await eventually(timeout: 5) { frames(link).contains { $0.cmd == G2Navigation.cmdMaxMap } }
        #expect(frames(link).filter { $0.cmd == G2Navigation.cmdMaxMap }.count == 1)

        // Standing still: frames keep coming, the full map isn't resent.
        feed.yield(fix(52.5203, 13.40))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(frames(link).filter { $0.cmd == G2Navigation.cmdMaxMap }.count == 1)

        // Back to the arrow view: the mini map again.
        let before = frames(link).filter { $0.cmd == G2Navigation.cmdMiniMap }.count
        link.sendNavEvent(.viewChanged(view: 1))
        try? await eventually(timeout: 5) { frames(link).filter { $0.cmd == G2Navigation.cmdMiniMap }.count > before }
        #expect(frames(link).filter { $0.cmd == G2Navigation.cmdMiniMap }.count > before)

        feed.finish()
        await task.value
    }

    @Test func theMiniMapStaysUnrotatedLikeTheEvenApp() async {
        // The Even app sends rotationAngle 0 while the glasses report their compass (trace).
        let link = FakeGlassesLink()
        let session = makeSession(link, map: FakeMapProvider())
        session.frameInterval = .zero
        let (task, feed) = await startRouted(link, session)
        link.sendNavEvent(.compassChanged(value: 235))
        try? await Task.sleep(for: .milliseconds(50))
        feed.yield(fix(52.5204, 13.40))
        try? await Task.sleep(for: .milliseconds(100))

        let mini = frames(link).last { $0.cmd == G2Navigation.cmdMiniMap }
        #expect(mini.map { ProtoReader.varintFields($0.sub)[5] } == 0)
        #expect(mini.map { ProtoReader.varintFields($0.sub)[2] } == 2)  // LZ4

        feed.finish()
        await task.value
    }

    @Test func bothMapsShareOneSessionCounter() async {
        struct BigMap: NavMapProviding {
            // Noise doesn't compress: the mini map goes out fragmented, with a session id.
            func bitmap(for request: NavMapRequest) async -> NavMapBitmap? {
                let width = request.kind == .mini ? 170 : 576, height = request.kind == .mini ? 170 : 188
                var rgba = [UInt8](repeating: 255, count: width * height * 4)
                var seed: UInt32 = 1
                for pixel in 0..<(width * height) {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let off: Int = (seed >> 16) % 2 == 0 ? 0 : 1  // drop red or green
                    rgba[pixel * 4 + off] = 0
                    rgba[pixel * 4 + 2] = 0
                }
                return NavMapBitmap(width: width, height: height, rgba: rgba)
            }
        }
        let link = FakeGlassesLink()
        let session = makeSession(link, map: BigMap())
        session.frameInterval = .zero
        let (task, feed) = await startRouted(link, session)
        link.sendNavEvent(.viewChanged(view: 2))
        try? await eventually(timeout: 5) { frames(link).contains { $0.cmd == G2Navigation.cmdMaxMap } }

        let sessions = frames(link).compactMap { frame -> UInt64? in
            switch frame.cmd {
            case G2Navigation.cmdMiniMap: ProtoReader.varintFields(frame.sub)[7]
            case G2Navigation.cmdMaxMap: ProtoReader.varintFields(frame.sub)[1]
            default: nil
            }
        }
        // Mini (session 1, fragmented) then full (session 2): one counter, not one per map.
        #expect(Array(Set(sessions)).sorted() == [1, 2])

        feed.finish()
        await task.value
    }
}
