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
    // The finest pack footprint required for Blue Snow 3D's offline zoom range 0...16.
    static let coverageIndexZoom = 12

    /// The fewest tiles that cover the world outside the given packs without overlapping each other or the packs.
    static func complement(of packs: Set<OfflineTile>) -> [OfflineTile] {
        let packs = packs.filter { $0.zoom == coverageIndexZoom }
        let ancestors = Set(packs.flatMap { pack in (0..<coverageIndexZoom).compactMap { pack.parent(atZoom: $0) } })
        var tiles: [OfflineTile] = []
        func cover(_ tile: OfflineTile) {
            guard !packs.contains(tile) else { return }
            guard ancestors.contains(tile) else {
                tiles.append(tile)
                return
            }
            for y in tile.y * 2...tile.y * 2 + 1 {
                for x in tile.x * 2...tile.x * 2 + 1 {
                    if let child = OfflineTile(zoom: tile.zoom + 1, x: x, y: y) { cover(child) }
                }
            }
        }
        if let world = OfflineTile(zoom: 0, x: 0, y: 0) { cover(world) }
        return tiles
    }

    /// A corner of the pack grid. The pack at x and y has its north-west corner at the same x and y.
    struct Corner: Hashable, Sendable {
        let x: Int
        let y: Int
        var coordinate: CLLocationCoordinate2D { OfflineTile.coordinate(x: x, y: y, zoom: coverageIndexZoom) }
    }

    /// The closed rings that outline the area the packs cover, including the edges of holes,
    /// with each straight run of pack sides merged into one edge.
    static func outline(of packs: Set<OfflineTile>) -> [[Corner]] {
        let covered = Set(packs.filter { $0.zoom == coverageIndexZoom }.map { Corner(x: $0.x, y: $0.y) })
        // Every pack side that faces an uncovered neighbor is part of the outline. The sides run clockwise
        // around their pack, so the covered area is on the right of each ring.
        var edges: [Edge] = []
        for pack in covered.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            let (x, y) = (pack.x, pack.y)
            if !covered.contains(Corner(x: x, y: y - 1)) { edges.append(Edge(Corner(x: x, y: y), Corner(x: x + 1, y: y))) }
            if !covered.contains(Corner(x: x + 1, y: y)) { edges.append(Edge(Corner(x: x + 1, y: y), Corner(x: x + 1, y: y + 1))) }
            if !covered.contains(Corner(x: x, y: y + 1)) { edges.append(Edge(Corner(x: x + 1, y: y + 1), Corner(x: x, y: y + 1))) }
            if !covered.contains(Corner(x: x - 1, y: y)) { edges.append(Edge(Corner(x: x, y: y + 1), Corner(x: x, y: y))) }
        }
        var outgoing: [Corner: [Int]] = [:]
        for (index, edge) in edges.enumerated() { outgoing[edge.start, default: []].append(index) }
        var used = Array(repeating: false, count: edges.count)
        var rings: [[Corner]] = []
        for first in edges.indices where !used[first] {
            var ring = [edges[first].start]
            var current = first
            while true {
                used[current] = true
                let edge = edges[current]
                ring.append(edge.end)
                // Where two packs touch only at a corner, turning right keeps each ring around its own pack.
                guard edge.end != edges[first].start,
                      let next = outgoing[edge.end]?.filter({ !used[$0] })
                          .max(by: { edge.turn(to: edges[$0]) < edge.turn(to: edges[$1]) }) else { break }
                current = next
            }
            rings.append(merged(ring))
        }
        return rings
    }

    private struct Edge {
        let start: Corner
        let end: Corner

        init(_ start: Corner, _ end: Corner) {
            self.start = start
            self.end = end
        }

        /// 1 for a right turn on screen, where y grows southward, 0 for straight ahead and -1 for a left turn.
        func turn(to next: Edge) -> Int {
            let (dx, dy) = (end.x - start.x, end.y - start.y)
            let (nx, ny) = (next.end.x - next.start.x, next.end.y - next.start.y)
            return (dx * ny - dy * nx).signum()
        }
    }

    private static func merged(_ ring: [Corner]) -> [Corner] {
        let corners = Array(ring.dropLast())
        func direction(_ from: Corner, _ to: Corner) -> Corner { Corner(x: (to.x - from.x).signum(), y: (to.y - from.y).signum()) }
        let turns = corners.indices.filter { index in
            let previous = corners[(index + corners.count - 1) % corners.count]
            let next = corners[(index + 1) % corners.count]
            return direction(previous, corners[index]) != direction(corners[index], next)
        }.map { corners[$0] }
        return turns.isEmpty ? ring : turns + [turns[0]]
    }
}
