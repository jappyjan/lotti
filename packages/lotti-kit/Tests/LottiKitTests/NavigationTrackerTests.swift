import CoreLocation
import Foundation
import Testing
@testable import LottiKit

/// The tracker is pure geometry: a hand-built route (north 100 m, right turn, east ~100 m, then
/// east ~35 m to the destination) and synthetic fixes. 1° lat = 111.3 km, 1° lon at 52.5° N
/// ≈ 67.8 km.
struct NavigationTrackerTests {
    private let start = CLLocationCoordinate2D(latitude: 52.52, longitude: 13.40)
    private let corner = CLLocationCoordinate2D(latitude: 52.5209, longitude: 13.40)
    private let mid = CLLocationCoordinate2D(latitude: 52.5209, longitude: 13.4015)
    private let end = CLLocationCoordinate2D(latitude: 52.5209, longitude: 13.4020)

    private func route() -> Route {
        Route(
            mode: .walking,
            destination: "Mauerpark",
            destinationCoordinate: end,
            steps: [
                RouteStep(instruction: "Head north", maneuver: .departure, roadName: nil, distance: 100,
                          points: [start, corner]),
                RouteStep(instruction: "Turn right onto Torstraße", maneuver: .turnRight, roadName: "Torstraße",
                          distance: 102, points: [corner, mid]),
                RouteStep(instruction: "Arrive at the destination", maneuver: .arrive, roadName: nil,
                          distance: 34, points: [mid, end]),
            ],
            totalDistance: 236,
            expectedTravelTime: 300)
    }

    private func fix(_ latitude: Double, _ longitude: Double, speed: Double = 1, accuracy: Double = 5) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5, course: 0,
            speed: speed, timestamp: Date())
    }

    @Test func firstCardShowsTheFirstTurn() {
        var tracker = StepTracker(route: route())
        guard case .progress(let card) = tracker.update(fix(52.52, 13.40)) else {
            Issue.record("expected a progress card")
            return
        }
        #expect(card.direction == .turnRight)
        #expect(card.distance == "100 m")
        #expect(card.road == "Torstraße")
        #expect(card.remainingDistance == "240 m")
        #expect(card.counter == 1)
    }

    @Test func sameStepKeepsTheCardButCountsDown() {
        var tracker = StepTracker(route: route())
        _ = tracker.update(fix(52.52, 13.40))
        guard case .progress(let card) = tracker.update(fix(52.5203, 13.40)) else {
            Issue.record("expected a progress card")
            return
        }
        #expect(card.direction == .turnRight)
        #expect(card.distance == "70 m")
        #expect(card.counter == 1)
        #expect(card.remainingDistance == "200 m")
    }

    @Test func passingTheCornerShowsTheNextStep() {
        var tracker = StepTracker(route: route())
        _ = tracker.update(fix(52.52, 13.40))
        guard case .progress(let card) = tracker.update(fix(52.5209, 13.401)) else {
            Issue.record("expected a progress card")
            return
        }
        #expect(card.direction == .straight)  // the arrive step's arrow
        #expect(card.counter == 2)
        #expect(card.distance == "30 m")
    }

    @Test func etaCountsFromRemainingTime() {
        var tracker = StepTracker(route: route())
        let now = Date(timeIntervalSince1970: 1_000_000)
        guard case .progress(let card) = tracker.update(fix(52.52, 13.40), now: now) else {
            Issue.record("expected a progress card")
            return
        }
        #expect(card.remainingTime == "5 min")
        #expect(card.eta == NavFormat.time(now.addingTimeInterval(300)))
    }

    @Test func speedOnlyWhileMoving() {
        var tracker = StepTracker(route: route())
        guard case .progress(let moving) = tracker.update(fix(52.52, 13.40, speed: 1.4)) else {
            Issue.record("expected a progress card")
            return
        }
        #expect(moving.speed == "5 km/h")
        guard case .progress(let still) = tracker.update(fix(52.52, 13.40, speed: 0)) else {
            Issue.record("expected a progress card")
            return
        }
        #expect(still.speed == nil)
    }

    @Test func closeToTheDestinationIsArrived() {
        var tracker = StepTracker(route: route())
        #expect(tracker.update(fix(52.5209, 13.4023)) == .arrived)
    }

    @Test func farFromTheRouteIsOffRoute() {
        var tracker = StepTracker(route: route())
        #expect(tracker.update(fix(52.53, 13.40)) == .offRoute)
    }

    @Test func aPoorFixIsUnreliable() {
        var tracker = StepTracker(route: route())
        #expect(tracker.update(fix(52.52, 13.40, accuracy: 200)) == .unreliable)
    }

    // MARK: Maneuver classification

    @Test func classifiesTurnsFromGeometry() {
        let corner = CLLocationCoordinate2D(latitude: 52.5209, longitude: 13.40)
        let north = CLLocationCoordinate2D(latitude: 52.5228, longitude: 13.40)
        let south = CLLocationCoordinate2D(latitude: 52.5190, longitude: 13.40)
        let east = CLLocationCoordinate2D(latitude: 52.5209, longitude: 13.4018)
        let west = CLLocationCoordinate2D(latitude: 52.5209, longitude: 13.3982)
        let northEast = CLLocationCoordinate2D(latitude: 52.5219, longitude: 13.4018)
        let northWest = CLLocationCoordinate2D(latitude: 52.5219, longitude: 13.3990)
        let southWest = CLLocationCoordinate2D(latitude: 52.5204, longitude: 13.3992)
        let southEast = CLLocationCoordinate2D(latitude: 52.5204, longitude: 13.4008)

        // Arriving from the south, heading north (bearing 0).
        #expect(RoutePlanner.classify(from: [south, corner], to: [corner, east]) == .turnRight)
        #expect(RoutePlanner.classify(from: [south, corner], to: [corner, west]) == .turnLeft)
        #expect(RoutePlanner.classify(from: [south, corner], to: [corner, north]) == .straight)
        #expect(RoutePlanner.classify(from: [south, corner], to: [corner, northEast]) == .slightRight)
        #expect(RoutePlanner.classify(from: [south, corner], to: [corner, northWest]) == .slightLeft)
        #expect(RoutePlanner.classify(from: [south, corner], to: [corner, southWest]) == .sharpLeft)
        #expect(RoutePlanner.classify(from: [south, corner], to: [corner, southEast]) == .sharpRight)
        #expect(RoutePlanner.classify(from: [south, corner], to: [corner, south]) == .uTurn)
        #expect(RoutePlanner.classify(from: [], to: [corner, east]) == .straight)
    }

    @Test func bearingsAreCompassDegrees() {
        let a = CLLocationCoordinate2D(latitude: 52.52, longitude: 13.40)
        let north = CLLocationCoordinate2D(latitude: 52.53, longitude: 13.40)
        let east = CLLocationCoordinate2D(latitude: 52.52, longitude: 13.41)
        #expect(abs(RoutePlanner.bearing(a, north) - 0) < 0.1)
        #expect(abs(RoutePlanner.bearing(a, east) - 90) < 0.1)
    }

    @Test func roadNamesComeOutOfInstructions() {
        #expect(RoutePlanner.roadName(from: "Turn right onto Torstraße") == "Torstraße")
        #expect(RoutePlanner.roadName(from: "Rechts abbiegen auf Torstraße") == "Torstraße")
        #expect(RoutePlanner.roadName(from: "Continue onto Oranienburger Straße") == "Oranienburger Straße")
        #expect(RoutePlanner.roadName(from: "Rechts abbiegen, um auf der Torstraße zu bleiben") == "Torstraße")
        #expect(RoutePlanner.roadName(from: "Take the exit onto A 100") == "A 100")
        #expect(RoutePlanner.roadName(from: "Arrive at the destination") == nil)
        #expect(RoutePlanner.roadName(from: "Head north") == nil)
    }

    @Test func formatsDistancesTimesAndSpeeds() {
        #expect(NavFormat.distance(100) == "100 m")
        #expect(NavFormat.distance(968) == "970 m")
        #expect(NavFormat.distance(1234) == "1.2 km")
        #expect(NavFormat.minutes(300) == "5 min")
        #expect(NavFormat.minutes(3900) == "1 h 5 min")
        #expect(NavFormat.minutes(10) == "1 min")
        #expect(NavFormat.speed(0) == nil)
        #expect(NavFormat.speed(0.4) == nil)
        #expect(NavFormat.speed(1.4) == "5 km/h")
    }
}
