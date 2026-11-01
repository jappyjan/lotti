import CoreLocation
import Foundation

/// What the navigation screen wants to draw right now.
public struct NavMapRequest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The small map next to the arrow.
        case mini
        /// The full-screen map.
        case full
    }

    public var kind: Kind
    /// Where Jan is: the map centers on him.
    public var coordinate: CLLocationCoordinate2D
    /// His heading in degrees (0 = north); nil when unknown (then the map stays north-up).
    public var heading: Double?
    /// The route's geometry, for the full map's region.
    public var route: [CLLocationCoordinate2D]

    public init(
        kind: Kind, coordinate: CLLocationCoordinate2D, heading: Double?,
        route: [CLLocationCoordinate2D]
    ) {
        self.kind = kind
        self.coordinate = coordinate
        self.heading = heading
        self.route = route
    }

    public static func == (lhs: NavMapRequest, rhs: NavMapRequest) -> Bool {
        lhs.kind == rhs.kind && lhs.coordinate == rhs.coordinate && lhs.heading == rhs.heading
            && lhs.route.count == rhs.route.count
            && zip(lhs.route, rhs.route).allSatisfy { $0.0 == $0.1 }
    }
}

/// A map rendered for the navigation screen, as RGBA (`width * height * 4` bytes, row-major,
/// top row first). `NavMapBmp.encode` turns it into the lens' native format: a 4 bpp BMP of the
/// road network — green roads, the active route red, everything else transparent (the Even
/// app's `encodeRoadNetworkBmp4`).
public struct NavMapBitmap: Sendable {
    public var width: Int
    public var height: Int
    /// `width * height * 4` bytes, RGBA, row-major, top row first.
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

/// Renders map bitmaps for the session. The app implements it with `MKMapSnapshotter`
/// (Apple Maps: no HERE, no Mapbox).
public protocol NavMapProviding: Sendable {
    func bitmap(for request: NavMapRequest) async -> NavMapBitmap?
}
