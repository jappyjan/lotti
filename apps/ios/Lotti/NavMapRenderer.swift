import CoreLocation
import Foundation
import LottiKit
import MapKit
import UIKit

/// Renders the navigation screen's map bitmaps from Apple Maps (`MKMapSnapshotter`): north-up
/// snapshots converted to the lens' 4 bpp grayscale. No HERE, no Mapbox.
///
/// Best-effort guesses, to be confirmed on the glasses: the bitmaps are 4 bpp row-major
/// (g2-kit `images.md`), `compressMode` 0 = raw, the mini map is 144 × 144 and the full map
/// 576 × 288. `MKMapSnapshotter` is throttled by Apple, so the session refreshes slowly.
@MainActor
final class NavMapRenderer: NavMapProviding {
    func bitmap(for request: NavMapRequest) async -> NavMapBitmap? {
        let size: CGSize = request.kind == .mini ? CGSize(width: 144, height: 144) : CGSize(width: 576, height: 288)
        let options = MKMapSnapshotter.Options()
        options.size = size
        options.mapType = .standard
        if request.kind == .mini {
            options.camera = MKMapCamera(lookingAtCenter: request.coordinate, fromDistance: 600, pitch: 0, heading: 0)
        } else {
            options.region = Self.region(around: request.coordinate, route: request.route)
        }
        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot = try? await snapshotter.start()
        guard let image = snapshot?.image.cgImage else {
            print("[Nav] map snapshot failed")
            return nil
        }
        return Self.fourBitGray(image, width: Int(size.width), height: Int(size.height))
    }

    /// A region covering Jan and the whole route, with a little breathing room.
    static func region(around coordinate: CLLocationCoordinate2D, route: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        var points = route
        points.append(coordinate)
        guard !points.isEmpty else {
            return MKCoordinateRegion(center: coordinate, latitudinalMeters: 2000, longitudinalMeters: 2000)
        }
        var minLat = points[0].latitude, maxLat = points[0].latitude
        var minLon = points[0].longitude, maxLon = points[0].longitude
        for point in points {
            minLat = min(minLat, point.latitude)
            maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude)
            maxLon = max(maxLon, point.longitude)
        }
        let pad = 0.25
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * (1 + pad * 2), 0.004),
            longitudeDelta: max((maxLon - minLon) * (1 + pad * 2), 0.004))
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                                                 longitude: (minLon + maxLon) / 2), span: span)
    }

    /// RGBA → 4 bpp grayscale, row-major, two pixels per byte (high nibble first), top row first.
    static func fourBitGray(_ image: CGImage, width: Int, height: Int) -> NavMapBitmap? {
        guard width > 0, height > 0, width.isMultiple(of: 2) else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // CGContext draws bottom-up; flip so row 0 is the top of the map.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height / 2)
        for index in 0..<(width * height) {
            let r = Int(rgba[index * 4]), g = Int(rgba[index * 4 + 1]), b = Int(rgba[index * 4 + 2])
            let luminance = (299 * r + 587 * g + 114 * b) / 1000
            let value = UInt8(min(15, luminance * 16 / 256))
            if index.isMultiple(of: 2) {
                pixels[index / 2] = value << 4
            } else {
                pixels[index / 2] |= value
            }
        }
        return NavMapBitmap(width: width, height: height, pixels: pixels)
    }
}
