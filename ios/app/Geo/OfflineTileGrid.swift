import CoreLocation
import Foundation
import Turf

struct OfflineTile: Hashable, Codable, Identifiable, Sendable {
    let zoom: Int
    let x: Int
    let y: Int
    var id: String { "\(zoom)/\(x)/\(y)" }

    init?(zoom: Int, x: Int, y: Int) {
        guard (0...22).contains(zoom), (0..<(1 << zoom)).contains(x), (0..<(1 << zoom)).contains(y) else { return nil }
        self.zoom = zoom
        self.x = x
        self.y = y
    }

    init?(id: String) {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, let zoom = Int(parts[0]), let x = Int(parts[1]), let y = Int(parts[2]) else { return nil }
        self.init(zoom: zoom, x: x, y: y)
        guard self.id == id else { return nil }
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let zoom = try values.decode(Int.self, forKey: .zoom)
        let x = try values.decode(Int.self, forKey: .x)
        let y = try values.decode(Int.self, forKey: .y)
        guard let tile = Self(zoom: zoom, x: x, y: y) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid offline tile coordinate"))
        }
        self = tile
    }

    var coordinates: [CLLocationCoordinate2D] {
        [(x, y + 1), (x + 1, y + 1), (x + 1, y), (x, y), (x, y + 1)]
            .map { Self.coordinate(x: $0.0, y: $0.1, zoom: zoom) }
    }
    var geometry: Geometry { .polygon(Polygon([coordinates])) }

    func parent(atZoom parentZoom: Int) -> OfflineTile? {
        guard (0...zoom).contains(parentZoom) else { return nil }
        let shift = zoom - parentZoom
        return OfflineTile(zoom: parentZoom, x: x >> shift, y: y >> shift)
    }

    static func coordinate(x: Int, y: Int, zoom: Int) -> CLLocationCoordinate2D {
        let count = Double(1 << zoom)
        return CLLocationCoordinate2D(
            latitude: atan(sinh(.pi * (1 - 2 * Double(y) / count))) * 180 / .pi,
            longitude: Double(x) / count * 360 - 180)
    }
}

enum OfflineTileGrid {
    // Blue Snow 3D uses the default vector pack scheme and the published DEM scheme,
    // which adds an index-10 pack for terrain at zooms 10 through 12.
    static let indexZooms = [0, 6, 10, 11, 12]
    static let coverageZoom = 14
    // The finest pack footprint required for Blue Snow 3D's offline zoom range 0...16.
    static let coverageIndexZoom = 12

    static func coverageTiles(for pack: OfflineTile) -> [OfflineTile] {
        guard pack.zoom == coverageIndexZoom else { return [] }
        let factor = 1 << (coverageZoom - coverageIndexZoom)
        return (pack.x * factor..<((pack.x + 1) * factor)).flatMap { x in
            (pack.y * factor..<((pack.y + 1) * factor)).compactMap { y in
                OfflineTile(zoom: coverageZoom, x: x, y: y)
            }
        }
    }
}
