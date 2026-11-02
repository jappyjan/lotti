import CoreLocation
import Foundation
import LottiKit
import MapKit
import Observation
import UIKit

/// Renders the navigation screen's maps: an Apple Maps snapshot with the road network lifted
/// into green (the light style's cool-gray streets and yellow main roads), the active route in
/// red, Jan and the
/// destination in green — an RGBA bitmap that `NavMapBmp` reduces to the lens' 3-color palette
/// (green roads, red route, everything else off). The last bitmaps are kept for the debug
/// section, so what the glasses receive can be checked on the phone.
@MainActor
@Observable
final class NavMapRenderer: NavMapProviding {
    /// The last bitmaps handed to the session, for the Debug section.
    private(set) var lastMini: UIImage?
    private(set) var lastFull: UIImage?

    func bitmap(for request: NavMapRequest) async -> NavMapBitmap? {
        let width = request.kind == .mini ? NavMapBmp.Size.mini.width : NavMapBmp.Size.full.width
        let height = request.kind == .mini ? NavMapBmp.Size.mini.height : NavMapBmp.Size.full.height

        let options = MKMapSnapshotter.Options()
        options.size = CGSize(width: width, height: height)
        options.mapType = .standard
        options.showsBuildings = false
        options.pointOfInterestFilter = .excludingAll
        options.region = Self.region(for: request)
        // Always the light style: in dark mode the streets are dark and nothing gets lifted.
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)
        let snapshot = try? await MKMapSnapshotter(options: options).start()
        if snapshot == nil { print("[Nav] map snapshot failed") }

        // Draw into our own buffer (CG lays rows top-down in memory; flip the drawing so
        // north is up) — the exact bytes that become the BMP.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let image: UIImage? = rgba.withUnsafeMutableBytes { buffer -> UIImage? in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            if let cg = snapshot?.image.cgImage {
                context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            }

            // Lift the roads: streets are light neutral-to-cool gray (the blocks around them are
            // warm beige, parks green, labels dark), main roads yellow in some regions. Those
            // become green; everything else drops out as the palette's off color.
            for pixel in 0..<(width * height) {
                let r = buffer[pixel * 4], g = buffer[pixel * 4 + 1], b = buffer[pixel * 4 + 2]
                let road = Self.isRoad(r: Int(r), g: Int(g), b: Int(b))
                buffer[pixel * 4] = road ? NavMapBmp.road.r : 0
                buffer[pixel * 4 + 1] = road ? NavMapBmp.road.g : 0
                buffer[pixel * 4 + 2] = road ? NavMapBmp.road.b : 0
                buffer[pixel * 4 + 3] = 255
            }

            // Route (red), destination and Jan (green), in the snapshot's projection.
            let point = snapshot.map { snap in
                { (coordinate: CLLocationCoordinate2D) in snap.point(for: coordinate) }
            } ?? Self.pixelProjection(for: request, width: width, height: height)
            let route = request.route.map(point)
            if route.count >= 2 {
                context.setStrokeColor(UIColor(red: 1, green: 0, blue: 0, alpha: 1).cgColor)
                context.setLineWidth(request.kind == .mini ? 2.5 : 4)
                context.setLineJoin(.round)
                context.setLineCap(.round)
                context.beginPath()
                context.move(to: route[0])
                for vertex in route.dropFirst() { context.addLine(to: vertex) }
                context.strokePath()
            }
            context.setFillColor(UIColor(red: 0, green: 1, blue: 0, alpha: 1).cgColor)
            if let destination = route.last {
                let radius = request.kind == .mini ? 4.0 : 5.0
                context.fillEllipse(
                    in: CGRect(x: destination.x - radius, y: destination.y - radius,
                               width: radius * 2, height: radius * 2))
            }
            let here = point(request.coordinate)
            let radius = request.kind == .mini ? 5.0 : 6.0
            context.setStrokeColor(UIColor(red: 0, green: 1, blue: 0, alpha: 1).cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(
                in: CGRect(x: here.x - radius, y: here.y - radius, width: radius * 2, height: radius * 2))

            return context.makeImage().map(UIImage.init(cgImage:))
        }

        if request.kind == .mini { lastMini = image } else { lastFull = image }
        return NavMapBitmap(width: width, height: height, rgba: rgba)
    }

    /// Street pixels of the light map style: light gray, not warmer than neutral
    /// (b, g ≥ r − 4, spread ≤ 24, value 150…250), or yellow main roads.
    static func isRoad(r: Int, g: Int, b: Int) -> Bool {
        let high = max(r, g, b), low = min(r, g, b)
        let gray = b >= r - 4 && g >= r - 4 && high - low <= 24 && (150...250).contains(high)
        let yellow = r >= 240 && g >= 190 && b <= 130
        return gray || yellow
    }

    /// The region the bitmap covers: ~550 m around Jan for the mini map, Jan + the route for
    /// the full map.
    static func region(for request: NavMapRequest) -> MKCoordinateRegion {
        if request.kind == .mini {
            return MKCoordinateRegion(
                center: request.coordinate, latitudinalMeters: 556, longitudinalMeters: 556)
        }
        let coordinates = request.route + [request.coordinate]
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion(
                center: request.coordinate, latitudinalMeters: 2000, longitudinalMeters: 2000)
        }
        var minLat = coordinates[0].latitude, maxLat = coordinates[0].latitude
        var minLon = coordinates[0].longitude, maxLon = coordinates[0].longitude
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }
        let pad = 0.25
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * (1 + pad * 2), 0.004),
            longitudeDelta: max((maxLon - minLon) * (1 + pad * 2), 0.004))
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: span)
    }

    /// Lat/lon → pixel for when the snapshot fails: the same bbox, equirectangular, north up.
    static func pixelProjection(
        for request: NavMapRequest, width: Int, height: Int
    ) -> (CLLocationCoordinate2D) -> CGPoint {
        let coordinates = request.route + [request.coordinate]
        guard !coordinates.isEmpty else {
            return { _ in CGPoint(x: width / 2, y: height / 2) }
        }
        var minLat = coordinates[0].latitude, maxLat = coordinates[0].latitude
        var minLon = coordinates[0].longitude, maxLon = coordinates[0].longitude
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }
        let latSpan = max(maxLat - minLat, 0.0001)
        let lonSpan = max(maxLon - minLon, 0.0001)
        return { coordinate in
            let x = (coordinate.longitude - minLon) / lonSpan * Double(width)
            let y = (1 - (coordinate.latitude - minLat) / latSpan) * Double(height)
            return CGPoint(x: x, y: y)
        }
    }
}
