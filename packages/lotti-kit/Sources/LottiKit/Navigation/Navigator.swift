import CoreLocation
import Foundation
import MapKit

/// How Lotti navigates: walking and cycling only, matching the firmware's nav screen
/// (the Even app supports driving, the G2 screen doesn't).
public enum NavigationMode: String, Equatable, Sendable, CaseIterable {
    case walking, cycling

    public var transportType: MKDirectionsTransportType {
        self == .walking ? .walking : .cycling
    }

    /// navigateWorkMethod on the glasses' nav service.
    public var method: UInt64 {
        self == .walking ? G2Navigation.methodWalking : G2Navigation.methodCycling
    }

    public var spoken: String {
        self == .walking ? "on foot" : "by bike"
    }
}

/// What happens at a step, worked out from the route geometry (MapKit gives no maneuver type).
public enum Maneuver: Equatable, Sendable {
    case departure, straight, turnLeft, turnRight, slightLeft, slightRight, sharpLeft, sharpRight, uTurn, arrive

    /// The arrow the firmware draws (roundabout arrows stay unused until exit info is known).
    public var directionSign: NavigateDirectionSign {
        switch self {
        case .departure: .departure
        case .straight, .arrive: .straight
        case .turnLeft: .turnLeft
        case .turnRight: .turnRight
        case .slightLeft: .slightLeft
        case .slightRight: .slightRight
        case .sharpLeft: .sharpLeft
        case .sharpRight: .sharpRight
        case .uTurn: .uTurnCounterclockwise
        }
    }
}

/// One leg of a route, with its geometry.
public struct RouteStep: Equatable, Sendable {
    public var instruction: String
    public var maneuver: Maneuver
    /// Best effort: the road the step leads onto, from the instruction text; nil when unknown.
    public var roadName: String?
    public var distance: CLLocationDistance
    public var points: [CLLocationCoordinate2D]

    public init(
        instruction: String, maneuver: Maneuver, roadName: String?, distance: CLLocationDistance,
        points: [CLLocationCoordinate2D]
    ) {
        self.instruction = instruction
        self.maneuver = maneuver
        self.roadName = roadName
        self.distance = distance
        self.points = points
    }

    public static func == (lhs: RouteStep, rhs: RouteStep) -> Bool {
        lhs.instruction == rhs.instruction && lhs.maneuver == rhs.maneuver && lhs.roadName == rhs.roadName
            && lhs.distance == rhs.distance && lhs.points.count == rhs.points.count
            && zip(lhs.points, rhs.points).allSatisfy { $0.0 == $0.1 }
    }
}

/// A planned route: steps from here to the destination.
public struct Route: Equatable, Sendable {
    public var mode: NavigationMode
    /// Destination name for the display ("Mauerpark").
    public var destination: String
    public var destinationCoordinate: CLLocationCoordinate2D
    public var steps: [RouteStep]
    public var totalDistance: CLLocationDistance
    public var expectedTravelTime: TimeInterval

    public init(
        mode: NavigationMode, destination: String, destinationCoordinate: CLLocationCoordinate2D,
        steps: [RouteStep], totalDistance: CLLocationDistance, expectedTravelTime: TimeInterval
    ) {
        self.mode = mode
        self.destination = destination
        self.destinationCoordinate = destinationCoordinate
        self.steps = steps
        self.totalDistance = totalDistance
        self.expectedTravelTime = expectedTravelTime
    }

    public var summary: String {
        "\(destination): \(NavFormat.distance(totalDistance)), about \(NavFormat.minutes(expectedTravelTime)) \(mode.spoken)."
    }

    public static func == (lhs: Route, rhs: Route) -> Bool {
        lhs.mode == rhs.mode && lhs.destination == rhs.destination
            && lhs.destinationCoordinate == rhs.destinationCoordinate && lhs.steps == rhs.steps
            && lhs.totalDistance == rhs.totalDistance && lhs.expectedTravelTime == rhs.expectedTravelTime
    }
}

public enum RouteError: Error, LocalizedError, Equatable {
    case noRoute

    public var errorDescription: String? {
        switch self {
        case .noRoute: "MapKit found no route."
        }
    }
}

/// Routing on the phone with Apple MapKit. Free, on-device, no account, no third-party SDK:
/// the no-HereMaps path for both the route and (later) the map snapshots.
public struct RoutePlanner: Sendable {
    public init() {}

    /// MapKit's best match within ~30 km of `here`. A name speech-to-text got wrong
    /// ("Media Markt Altenach") is retried without its last words. Without the area limit
    /// MapKit found a store 530 km away. `MKMapItem` stays on the main actor.
    @MainActor
    public static func findPlace(_ query: String, near here: CLLocationCoordinate2D) async -> MKMapItem? {
        var words = query.split(separator: " ").map(String.init)
        while !words.isEmpty {
            let search = MKLocalSearch.Request()
            search.naturalLanguageQuery = words.joined(separator: " ")
            search.region = MKCoordinateRegion(center: here, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
            search.regionPriority = .required
            if let place = try? await MKLocalSearch(request: search).start().mapItems.first { return place }
            words.removeLast()
        }
        return nil
    }

    /// Plans the route and classifies each step's maneuver from the geometry.
    @MainActor
    public func route(from origin: CLLocationCoordinate2D, to place: MKMapItem, mode: NavigationMode) async throws -> Route {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = place
        request.transportType = mode.transportType
        let response = try await MKDirections(request: request).calculate()
        guard let mapRoute = response.routes.first else { throw RouteError.noRoute }

        var steps: [RouteStep] = []
        var previous: MKRoute.Step?
        for (index, step) in mapRoute.steps.enumerated() {
            let maneuver: Maneuver
            if index == 0 {
                maneuver = .departure
            } else if index == mapRoute.steps.count - 1 {
                maneuver = .arrive
            } else if let previous {
                maneuver = Self.classify(from: previous.polyline.coordinates, to: step.polyline.coordinates)
            } else {
                maneuver = .straight
            }
            steps.append(RouteStep(
                instruction: step.instructions,
                maneuver: maneuver,
                roadName: Self.roadName(from: step.instructions),
                distance: step.distance,
                points: step.polyline.coordinates
            ))
            previous = step
        }
        return Route(
            mode: mode,
            destination: place.name ?? "the destination",
            destinationCoordinate: place.placemark.coordinate,
            steps: steps,
            totalDistance: mapRoute.distance,
            expectedTravelTime: mapRoute.expectedTravelTime
        )
    }

    /// Turn direction from the bearing change between the previous step's last segment and this
    /// step's first segment. |delta|: < 30° straight, < 55° slight, < 125° turn, < 170° sharp,
    /// else U-turn; positive is a right turn.
    static func classify(from incoming: [CLLocationCoordinate2D], to outgoing: [CLLocationCoordinate2D]) -> Maneuver {
        guard let before = incoming.dropLast().last,
              let from = incoming.last,
              let after = outgoing.dropFirst().first
        else { return .straight }
        let delta = Self.normalizedDelta(from: Self.bearing(before, from), to: Self.bearing(from, after))
        let magnitude = abs(delta)
        switch magnitude {
        case ..<30: return .straight
        case ..<55: return delta > 0 ? .slightRight : .slightLeft
        case ..<125: return delta > 0 ? .turnRight : .turnLeft
        case ..<170: return delta > 0 ? .sharpRight : .sharpLeft
        default: return .uTurn
        }
    }

    static func normalizedDelta(from: Double, to: Double) -> Double {
        var delta = to - from
        if delta > 180 { delta -= 360 }
        if delta <= -180 { delta += 360 }
        return delta
    }

    /// Compass bearing in degrees (0 = north, clockwise) from `a` to `b`.
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The road a step leads onto, from the instruction text ("Turn right onto Torstraße" →
    /// "Torstraße"). Best effort: MapKit has no street-name field.
    static func roadName(from instruction: String) -> String? {
        let lower = instruction.lowercased()
        let prefixes = [
            "turn sharp right onto ", "turn sharp left onto ",
            "turn slight right onto ", "turn slight left onto ",
            "turn right onto ", "turn left onto ",
            "continue straight onto ", "continue onto ",
            "keep right onto ", "keep left onto ",
            "take the exit onto ", "take the ramp onto ",
            "scharf rechts abbiegen auf ", "scharf links abbiegen auf ",
            "leicht rechts abbiegen auf ", "leicht links abbiegen auf ",
            "rechts abbiegen auf ", "links abbiegen auf ",
            "rechts abbiegen, um auf der ", "links abbiegen, um auf der ",
            "rechts halten auf ", "links halten auf ",
            "geradeaus auf ", "weiter auf ",
        ]
        for prefix in prefixes where lower.hasPrefix(prefix) {
            if let name = Self.cleanRoadName(instruction.dropFirst(prefix.count)) { return name }
        }
        for marker in [" auf ", " onto ", " on "] {
            if let range = instruction.range(of: marker, options: [.backwards]) {
                let candidate = instruction[range.upperBound...]
                if let name = Self.cleanRoadName(candidate), name.count >= 3 { return name }
            }
        }
        return nil
    }

    private static func cleanRoadName(_ text: Substring) -> String? {
        var name = String(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = name.range(of: " um ") { name = String(name[..<cut.lowerBound]) }
        if let cut = name.range(of: " zu bleiben") { name = String(name[..<cut.lowerBound]) }
        if let cut = name.range(of: " to stay") { name = String(name[..<cut.lowerBound]) }
        if let cut = name.range(of: ", um auf der") { name = String(name[..<cut.lowerBound]) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ".,; "))
        guard !name.isEmpty, name.count <= 40 else { return nil }
        return name
    }
}

// MARK: - Progress tracking

/// The card the glasses show: arrow, distance to the next turn, and the remaining trip.
public struct NavProgress: Equatable, Sendable {
    /// Arrow for the next maneuver.
    public var direction: NavigateDirectionSign
    /// Distance to the next turn, pre-formatted ("200 m").
    public var distance: String
    /// Road of the next turn, or nil.
    public var road: String?
    /// "5 min", "1 h 5 min".
    public var remainingTime: String
    /// "1.2 km".
    public var remainingDistance: String
    /// "14:35".
    public var eta: String
    /// "5 km/h" while moving, nil otherwise.
    public var speed: String?
    /// Running index, +1 each time the next maneuver changes (reset on reroute).
    public var counter: Int

    public init(
        direction: NavigateDirectionSign, distance: String, road: String?, remainingTime: String,
        remainingDistance: String, eta: String, speed: String?, counter: Int
    ) {
        self.direction = direction
        self.distance = distance
        self.road = road
        self.remainingTime = remainingTime
        self.remainingDistance = remainingDistance
        self.eta = eta
        self.speed = speed
        self.counter = counter
    }
}

public enum TrackerResult: Equatable, Sendable {
    /// A fresh card for the glasses.
    case progress(NavProgress)
    /// Within `arrivalThreshold` of the destination.
    case arrived
    /// Farther than `offRouteThreshold` from the route: reroute.
    case offRoute
    /// The fix is too rough to trust (walking indoors, just after start).
    case unreliable
}

/// Formats distances, times and speeds for the glasses' nav screen.
public enum NavFormat: Sendable {
    /// "200 m" (to 10 m), "1.2 km".
    public static func distance(_ meters: Double) -> String {
        if meters < 1000 { return "\(max(10, Int((meters / 10).rounded()) * 10)) m" }
        return String(format: "%.1f km", meters / 1000)
    }

    /// "5 min", "1 h 5 min".
    public static func minutes(_ seconds: TimeInterval) -> String {
        let total = max(1, Int((seconds / 60).rounded()))
        return total < 60 ? "\(total) min" : "\(total / 60) h" + (total % 60 == 0 ? "" : " \(total % 60) min")
    }

    /// Local time, "14:35".
    public static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    /// "5 km/h"; nil when standing still.
    public static func speed(_ metersPerSecond: Double) -> String? {
        guard metersPerSecond >= 0.5 else { return nil }
        return "\(Int((metersPerSecond * 3.6).rounded())) km/h"
    }
}

/// Flattened route geometry with distances, so each location fix is one linear pass.
struct RouteGeometry: Sendable {
    let points: [CLLocationCoordinate2D]
    /// Meters from the route start to `points[i]`.
    let cumulative: [Double]
    /// Index in `points` where each route step begins.
    let stepStart: [Int]
    let total: Double

    init(route: Route) {
        var points: [CLLocationCoordinate2D] = []
        var cumulative: [Double] = []
        var stepStart: [Int] = []
        var travelled = 0.0
        for step in route.steps {
            // Where this step begins: its first point, which usually duplicates the previous
            // step's last one (then that existing point is the start).
            var start: Int?
            for point in step.points {
                let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
                if let last = points.last,
                   location.distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude)) < 0.5 {
                    if start == nil { start = points.count - 1 }
                    continue
                }
                if let last = points.last {
                    travelled += location.distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
                }
                points.append(point)
                cumulative.append(travelled)
                if start == nil { start = points.count - 1 }
            }
            stepStart.append(start ?? max(0, points.count - 1))
        }
        self.points = points
        self.cumulative = cumulative
        self.stepStart = stepStart
        self.total = travelled
    }

    /// The point on the route nearest to `coordinate`: how far along the route it is (meters
    /// from the start, projected onto the nearest segment) and the distance from the route.
    func nearest(to coordinate: CLLocationCoordinate2D) -> (along: Double, distance: Double) {
        guard points.count > 1 else { return (0, 0) }
        // Flat projection in meters is plenty for a route: the error stays far below the
        // off-route threshold at city scale.
        let latitudeScale = cos(coordinate.latitude * .pi / 180)
        let target = (x: coordinate.longitude * 111_320 * latitudeScale, y: coordinate.latitude * 111_320)
        var best = (along: 0.0, distance: Double.greatestFiniteMagnitude)
        for index in 0..<(points.count - 1) {
            let a = (x: points[index].longitude * 111_320 * latitudeScale, y: points[index].latitude * 111_320)
            let b = (x: points[index + 1].longitude * 111_320 * latitudeScale, y: points[index + 1].latitude * 111_320)
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared == 0 ? 0 : min(1, max(0, ((target.x - a.x) * dx + (target.y - a.y) * dy) / lengthSquared))
            let distance = hypot(target.x - (a.x + t * dx), target.y - (a.y + t * dy))
            let along = cumulative[index] + t * (cumulative[index + 1] - cumulative[index])
            if distance < best.distance { best = (along, distance) }
        }
        return best
    }
}

/// Turns location fixes into nav-screen cards: which step you're on, how far to the next turn,
/// what's left of the trip, and when to arrive / reroute.
public struct StepTracker: Sendable {
    public let route: Route
    public let offRouteThreshold: CLLocationDistance
    public let arrivalThreshold: CLLocationDistance

    private let geometry: RouteGeometry
    private var counter = 0
    /// Index of the route step whose start is the next instruction (changes → new card).
    private var nextStep = -1
    /// The last card's arrow and road, kept while in the final stretch (no next turn left).
    private var lastDirection = NavigateDirectionSign.departure
    private var lastRoad: String?

    public init(
        route: Route, offRouteThreshold: CLLocationDistance = 40, arrivalThreshold: CLLocationDistance = 25
    ) {
        self.route = route
        self.offRouteThreshold = offRouteThreshold
        self.arrivalThreshold = arrivalThreshold
        self.geometry = RouteGeometry(route: route)
    }

    public mutating func update(_ location: CLLocation, now: Date = Date()) -> TrackerResult {
        if location.horizontalAccuracy > 50 { return .unreliable }
        let snapped = geometry.nearest(to: location.coordinate)
        guard snapped.distance <= offRouteThreshold else { return .offRoute }

        let remaining = geometry.total - snapped.along
        if remaining <= arrivalThreshold { return .arrived }

        // The step you're on; the next instruction is the first step boundary ahead.
        let stepStartAlong = geometry.stepStart.map { geometry.cumulative[$0] }
        let currentStep = stepStartAlong.lastIndex(where: { $0 <= snapped.along }) ?? 0
        let next: Int
        let distanceToNext: Double
        if let boundary = stepStartAlong.firstIndex(where: { $0 > snapped.along }), boundary > currentStep {
            next = boundary
            distanceToNext = stepStartAlong[boundary] - snapped.along
        } else {
            // Final stretch: no turn left, keep the last arrow and count down to the destination.
            next = currentStep
            distanceToNext = remaining
        }

        if next != nextStep {
            nextStep = next
            counter += 1
            let step = route.steps[next]
            lastDirection = step.maneuver.directionSign
            lastRoad = step.roadName
        }

        let remainingTime = route.expectedTravelTime * remaining / max(geometry.total, 1)
        return .progress(NavProgress(
            direction: lastDirection,
            distance: NavFormat.distance(distanceToNext),
            road: lastRoad,
            remainingTime: NavFormat.minutes(remainingTime),
            remainingDistance: NavFormat.distance(remaining),
            eta: NavFormat.time(now.addingTimeInterval(remainingTime)),
            speed: NavFormat.speed(location.speed),
            counter: counter
        ))
    }
}

// MARK: - Helpers

extension MKPolyline {
    /// The polyline's vertices as coordinates (MapKit's own API needs a pointer walk).
    var coordinates: [CLLocationCoordinate2D] {
        let count = pointCount
        guard count > 0 else { return [] }
        let points = points()
        return (0..<count).map { points[$0].coordinate }
    }
}

func == (_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Bool {
    lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
}
