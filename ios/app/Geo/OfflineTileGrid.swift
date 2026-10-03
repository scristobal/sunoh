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

    /// The fewest tiles that cover the world outside the given tiles at one zoom without overlapping each other or them.
    static func complement(of covered: Set<OfflineTile>, zoom: Int = coverageIndexZoom) -> [OfflineTile] {
        let covered = covered.filter { $0.zoom == zoom }
        let ancestors = Set(covered.flatMap { tile in (0..<zoom).compactMap { tile.parent(atZoom: $0) } })
        var tiles: [OfflineTile] = []
        func cover(_ tile: OfflineTile) {
            guard !covered.contains(tile) else { return }
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

    /// A corner of the tile grid at one zoom. The tile at x and y has its north-west corner at the same x and y.
    struct Corner: Hashable, Sendable {
        let x: Int
        let y: Int
        var zoom = OfflineTileGrid.coverageIndexZoom
        var coordinate: CLLocationCoordinate2D { OfflineTile.coordinate(x: x, y: y, zoom: zoom) }
    }

    /// The closed rings that outline the area the tiles at one zoom cover, including the edges of holes,
    /// with each straight run of tile sides merged into one edge.
    static func outline(of tiles: Set<OfflineTile>, zoom: Int = coverageIndexZoom) -> [[Corner]] {
        func corner(_ x: Int, _ y: Int) -> Corner { Corner(x: x, y: y, zoom: zoom) }
        let covered = Set(tiles.filter { $0.zoom == zoom }.map { corner($0.x, $0.y) })
        // Every tile side that faces an uncovered neighbor is part of the outline. The sides run clockwise
        // around their tile, so the covered area is on the right of each ring.
        var edges: [Edge] = []
        for tile in covered.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            let (x, y) = (tile.x, tile.y)
            if !covered.contains(corner(x, y - 1)) { edges.append(Edge(corner(x, y), corner(x + 1, y))) }
            if !covered.contains(corner(x + 1, y)) { edges.append(Edge(corner(x + 1, y), corner(x + 1, y + 1))) }
            if !covered.contains(corner(x, y + 1)) { edges.append(Edge(corner(x + 1, y + 1), corner(x, y + 1))) }
            if !covered.contains(corner(x - 1, y)) { edges.append(Edge(corner(x, y + 1), corner(x, y))) }
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
                // Where two tiles touch only at a corner, turning right keeps each ring around its own tile.
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

    /// The tiles at a zoom that overlap the polygons formed by the rings, by the even-odd rule.
    /// Tiles that a ring only touches along a side or at a corner may be included.
    static func tiles(covering rings: [[CLLocationCoordinate2D]], zoom: Int) -> Set<OfflineTile> {
        let scale = Double(1 << zoom)
        let projected = rings.compactMap { ring -> [Point]? in
            var points = ring.map { coordinate -> Point in
                let latitude = min(85.05112878, max(-85.05112878, coordinate.latitude)) * .pi / 180
                return Point(x: (coordinate.longitude + 180) / 360 * scale, y: (1 - asinh(tan(latitude)) / .pi) / 2 * scale)
            }
            guard let first = points.first, points.count > 1 else { return nil }
            if points.last != first { points.append(first) }
            return points
        }
        var cells = Set<Cell>()
        // Tiles that a ring passes through, found by stepping across the grid lines along each edge.
        for ring in projected {
            for (start, end) in zip(ring, ring.dropFirst()) {
                var (x, y) = (Int(start.x.rounded(.down)), Int(start.y.rounded(.down)))
                let (endX, endY) = (Int(end.x.rounded(.down)), Int(end.y.rounded(.down)))
                let (stepX, stepY) = (end.x > start.x ? 1 : -1, end.y > start.y ? 1 : -1)
                let (width, height) = (abs(end.x - start.x), abs(end.y - start.y))
                // The share of the edge travelled when it crosses the next vertical and horizontal grid line.
                var nextX = width == 0 ? .infinity : (stepX > 0 ? Double(x + 1) - start.x : start.x - Double(x)) / width
                var nextY = height == 0 ? .infinity : (stepY > 0 ? Double(y + 1) - start.y : start.y - Double(y)) / height
                cells.insert(Cell(x: x, y: y))
                for _ in 0..<(abs(endX - x) + abs(endY - y)) {
                    if y == endY || (x != endX && nextX < nextY) {
                        x += stepX
                        nextX += 1 / width
                    } else {
                        y += stepY
                        nextY += 1 / height
                    }
                    cells.insert(Cell(x: x, y: y))
                }
            }
        }
        // Tiles whose center lies inside, row by row.
        let rows = projected.flatMap { $0.map(\.y) }
        if let top = rows.min(), let bottom = rows.max() {
            for row in Int(top.rounded(.down))...Int(bottom.rounded(.down)) {
                let center = Double(row) + 0.5
                var crossings: [Double] = []
                for ring in projected {
                    for (start, end) in zip(ring, ring.dropFirst()) where (start.y <= center) != (end.y <= center) {
                        crossings.append(start.x + (center - start.y) / (end.y - start.y) * (end.x - start.x))
                    }
                }
                crossings.sort()
                for index in stride(from: 0, to: crossings.count - 1, by: 2) {
                    let (first, last) = (Int((crossings[index] - 0.5).rounded(.up)), Int((crossings[index + 1] - 0.5).rounded(.down)))
                    if first <= last { for column in first...last { cells.insert(Cell(x: column, y: row)) } }
                }
            }
        }
        return Set(cells.compactMap { OfflineTile(zoom: zoom, x: $0.x, y: $0.y) })
    }

    private struct Point: Equatable {
        let x: Double
        let y: Double
    }

    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }
}
