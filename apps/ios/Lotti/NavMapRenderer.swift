import CoreLocation
import Foundation
import LottiKit
import UIKit

/// Renders the navigation screen's maps as RGBA drawings that `NavMapBmp` reduces to the lens'
/// 3-color palette: the active route in red, Jan and the destination in green, on a transparent
/// (black) background.
///
/// The Even app also draws the road network in green from HERE/Mapbox vectors; Lotti has no
/// road source yet, so only the route shows for now — enough for the map view to come up. A
/// road tile source (e.g. OSM vector tiles) would fill the rest in later.
@MainActor
final class NavMapRenderer: NavMapProviding {
    func bitmap(for request: NavMapRequest) async -> NavMapBitmap? {
        let width = request.kind == .mini ? NavMapBmp.Size.mini.width : NavMapBmp.Size.full.width
        let height = request.kind == .mini ? NavMapBmp.Size.mini.height : NavMapBmp.Size.full.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let projection = Self.projection(request: request, width: width, height: height)
        func point(_ coordinate: CLLocationCoordinate2D) -> CGPoint { projection(coordinate) }

        // The route, red.
        let route = request.route.map(point)
        if route.count >= 2 {
            context.setStrokeColor(Self.color(NavMapBmp.route).cgColor)
            context.setLineWidth(request.kind == .mini ? 2.5 : 4)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.beginPath()
            context.move(to: route[0])
            for vertex in route.dropFirst() { context.addLine(to: vertex) }
            context.strokePath()
        }

        // The destination, green.
        if let destination = route.last {
            let radius = request.kind == .mini ? 4.0 : 5.0
            context.setFillColor(Self.color(NavMapBmp.road).cgColor)
            context.fillEllipse(
                in: CGRect(x: destination.x - radius, y: destination.y - radius,
                           width: radius * 2, height: radius * 2))
        }

        // Jan, green.
        let here = point(request.coordinate)
        let radius = request.kind == .mini ? 5.0 : 6.0
        context.setStrokeColor(Self.color(NavMapBmp.road).cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(
            in: CGRect(x: here.x - radius, y: here.y - radius, width: radius * 2, height: radius * 2))

        guard let image = context.makeImage(),
              let bytes = image.dataProvider?.data as Data? else { return nil }
        return NavMapBitmap(width: width, height: height, rgba: [UInt8](bytes))
    }

    /// Lat/lon → pixel. The mini map centers on Jan with a fixed ~500 m span; the full map fits
    /// Jan and the route with padding. North is up in both.
    static func projection(
        request: NavMapRequest, width: Int, height: Int
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
        if request.kind == .mini {
            let span = 0.005  // ≈ 550 m of latitude; the mini map shows what's directly ahead
            minLat = request.coordinate.latitude - span
            maxLat = request.coordinate.latitude + span
            minLon = request.coordinate.longitude - span
            maxLon = request.coordinate.longitude + span
        }
        let latSpan = max(maxLat - minLat, 0.0001)
        let lonSpan = max(maxLon - minLon, 0.0001)
        return { coordinate in
            let x = (coordinate.longitude - minLon) / lonSpan * Double(width)
            let y = (1 - (coordinate.latitude - minLat) / latSpan) * Double(height)
            return CGPoint(x: x, y: y)
        }
    }

    private static func color(_ rgb: (r: UInt8, g: UInt8, b: UInt8)) -> UIColor {
        UIColor(
            red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255,
            alpha: 1)
    }
}
