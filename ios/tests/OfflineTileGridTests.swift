import CoreLocation
import Foundation
import Testing
@testable import Sunoh

struct OfflineTileGridTests {
    @Test func tileIDsValidateZoomAndCoordinates() throws {
        let tile = try #require(OfflineTile(id: "12/2000/1400"))
        #expect(tile.zoom == 12 && tile.x == 2000 && tile.y == 1400)
        for zoom in OfflineTileGrid.indexZooms {
            #expect(OfflineTile(id: "\(zoom)/0/0") != nil)
        }
        for id in ["23/0/0", "-1/0/0", "12/4096/1400", "12/2000/-1", "12/02000/1400", "12/2000/1400/", "0/1/0"] {
            #expect(OfflineTile(id: id) == nil)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(OfflineTile.self, from: Data(#"{"zoom":12,"x":-1,"y":1400}"#.utf8))
        }
        #expect(try JSONDecoder().decode(OfflineTile.self, from: JSONEncoder().encode(tile)) == tile)
    }

    @Test func neighboringTilesHaveCoincidentEdgesAndValidWorldBounds() throws {
        let first = try #require(OfflineTile(zoom: 12, x: 2000, y: 1400))
        let east = try #require(OfflineTile(zoom: 12, x: 2001, y: 1400))
        let south = try #require(OfflineTile(zoom: 12, x: 2000, y: 1401))
        #expect(first.coordinates[1].longitude == east.coordinates[0].longitude)
        #expect(first.coordinates[1].latitude == east.coordinates[0].latitude)
        #expect(first.coordinates[0].latitude == south.coordinates[3].latitude)
        #expect(first.coordinates.first?.latitude == first.coordinates.last?.latitude)
        #expect(first.coordinates.first?.longitude == first.coordinates.last?.longitude)
        let northWest = OfflineTile.coordinate(x: 0, y: 0, zoom: 12)
        let southEast = OfflineTile.coordinate(x: 4096, y: 4096, zoom: 12)
        #expect(abs(northWest.latitude - 85.0511287798) < 1e-9)
        #expect(northWest.longitude == -180 && southEast.longitude == 180)
        #expect(abs(northWest.latitude + southEast.latitude) < 1e-9)
    }

    @Test func displayTilesInheritTheirPackFootprintWithoutChangingTheGridZoom() throws {
        let first = try #require(OfflineTile(zoom: 14, x: 8000, y: 5600))
        let last = try #require(OfflineTile(zoom: 14, x: 8003, y: 5603))
        let next = try #require(OfflineTile(zoom: 14, x: 8004, y: 5600))
        let pack = try #require(OfflineTile(zoom: 12, x: 2000, y: 1400))
        #expect(first.parent(atZoom: 12) == pack)
        #expect(last.parent(atZoom: 12) == pack)
        #expect(next.parent(atZoom: 12) != pack)
        #expect(first.parent(atZoom: 14) == first)
        #expect(first.parent(atZoom: -1) == nil)
        #expect(first.parent(atZoom: 15) == nil)
    }

    @Test func nestedTilesShareTheSameParentFootprint() throws {
        let parent = try #require(OfflineTile(zoom: 11, x: 1000, y: 700))
        let northWest = try #require(OfflineTile(zoom: 12, x: 2000, y: 1400))
        let southEast = try #require(OfflineTile(zoom: 12, x: 2001, y: 1401))
        #expect(parent.coordinates[3].latitude == northWest.coordinates[3].latitude)
        #expect(parent.coordinates[3].longitude == northWest.coordinates[3].longitude)
        #expect(parent.coordinates[1].latitude == southEast.coordinates[1].latitude)
        #expect(parent.coordinates[1].longitude == southEast.coordinates[1].longitude)
    }

    @Test func complementWithoutPacksIsTheWholeWorld() throws {
        let world = try #require(OfflineTile(zoom: 0, x: 0, y: 0))
        #expect(OfflineTileGrid.complement(of: []) == [world])
        #expect(OfflineTileGrid.complement(of: [try #require(OfflineTile(zoom: 11, x: 1000, y: 700))]) == [world])
    }

    @Test func complementSurroundsOnePackWithThreeTilesAtEveryZoom() throws {
        let pack = try #require(OfflineTile(zoom: 12, x: 2000, y: 1400))
        let tiles = OfflineTileGrid.complement(of: [pack])
        #expect(tiles.count == 36)
        #expect(Set(tiles.map(\.zoom)) == Set(1...12))
        #expect(tiles.allSatisfy { pack.parent(atZoom: $0.zoom) != $0 })
    }

    @Test func complementAndPacksPartitionTheWorld() {
        let packs = Set([(2000, 1400), (2001, 1400), (2000, 1401), (2100, 1450), (0, 0), (4095, 4095)]
            .compactMap { OfflineTile(zoom: 12, x: $0.0, y: $0.1) })
        #expect(packs.count == 6)
        let tiles = OfflineTileGrid.complement(of: packs)
        #expect(Set(tiles).count == tiles.count)
        #expect(tiles.allSatisfy { tile in packs.allSatisfy { $0.parent(atZoom: tile.zoom) != tile } })
        #expect(tiles.allSatisfy { tile in
            tiles.allSatisfy { other in other.zoom <= tile.zoom || other.parent(atZoom: tile.zoom) != tile }
        })
        let packUnits = tiles.reduce(packs.count) { $0 + (1 << (2 * (12 - $1.zoom))) }
        #expect(packUnits == 1 << 24)
    }

    @Test func outlineOfOnePackFollowsItsFourCorners() throws {
        let pack = try #require(OfflineTile(zoom: 12, x: 2000, y: 1400))
        let rings = OfflineTileGrid.outline(of: [pack])
        #expect(rings.count == 1)
        let ring = try #require(rings.first)
        #expect(ring.count == 5 && ring.first == ring.last)
        #expect(Set(ring) == corners([(2000, 1400), (2001, 1400), (2001, 1401), (2000, 1401)]))
        #expect(ring[0].coordinate.latitude == pack.coordinates[3].latitude)
        #expect(ring[0].coordinate.longitude == pack.coordinates[3].longitude)
        #expect(OfflineTileGrid.outline(of: []).isEmpty)
        #expect(OfflineTileGrid.outline(of: [try #require(OfflineTile(zoom: 11, x: 1000, y: 700))]).isEmpty)
    }

    @Test func outlineMergesStraightRunsAroundJoinedPacks() {
        let pair = OfflineTileGrid.outline(of: packs([(2000, 1400), (2001, 1400)]))
        #expect(pair.count == 1 && pair.first?.count == 5)
        #expect(Set(pair.first ?? []) == corners([(2000, 1400), (2002, 1400), (2002, 1401), (2000, 1401)]))
        let bend = OfflineTileGrid.outline(of: packs([(2166, 1448), (2167, 1448), (2167, 1449)]))
        #expect(bend.count == 1 && bend.first?.count == 7)
        #expect(Set(bend.first ?? []) == corners([(2166, 1448), (2168, 1448), (2168, 1450), (2167, 1450), (2167, 1449), (2166, 1449)]))
    }

    @Test func outlineSeparatesHolesAndPacksThatTouchOnlyAtACorner() {
        var block: [(Int, Int)] = []
        for y in 0..<3 {
            for x in 0..<3 where !(x == 1 && y == 1) { block.append((2000 + x, 1400 + y)) }
        }
        let rings = OfflineTileGrid.outline(of: packs(block))
        #expect(rings.count == 2 && rings.allSatisfy { $0.count == 5 })
        #expect(Set(rings.map { Set($0) }) == [
            corners([(2000, 1400), (2003, 1400), (2003, 1403), (2000, 1403)]),
            corners([(2001, 1401), (2002, 1401), (2002, 1402), (2001, 1402)]),
        ])
        let diagonal = OfflineTileGrid.outline(of: packs([(2000, 1400), (2001, 1401)]))
        #expect(diagonal.count == 2 && diagonal.allSatisfy { $0.count == 5 })
        #expect(Set(diagonal.map { Set($0) }) == [
            corners([(2000, 1400), (2001, 1400), (2001, 1401), (2000, 1401)]),
            corners([(2001, 1401), (2002, 1401), (2002, 1402), (2001, 1402)]),
        ])
    }

    @Test func outlineTracesEveryUncoveredSideExactlyOnce() {
        // A diagonal pattern where many packs touch only at their corners.
        var cells: [(Int, Int)] = []
        for y in 0..<8 {
            for x in 0..<8 where (2 * x + 3 * y) % 5 < 2 { cells.append((2000 + x, 1400 + y)) }
        }
        let covered = packs(cells)
        let rings = OfflineTileGrid.outline(of: covered)
        var length = 0
        var axisAligned = true
        for ring in rings {
            for (from, to) in zip(ring, ring.dropFirst()) {
                length += abs(to.x - from.x) + abs(to.y - from.y)
                axisAligned = axisAligned && (from.x == to.x || from.y == to.y)
            }
        }
        let offsets: [(Int, Int)] = [(0, -1), (1, 0), (0, 1), (-1, 0)]
        var sides = 0
        for pack in covered {
            for (dx, dy) in offsets {
                if let neighbor = OfflineTile(zoom: 12, x: pack.x + dx, y: pack.y + dy), covered.contains(neighbor) { continue }
                sides += 1
            }
        }
        #expect(sides > 0 && length == sides && axisAligned)
        #expect(rings.allSatisfy { $0.count >= 5 && $0.first == $0.last })
    }

    @Test func complementAndOutlineWorkAtFinerZooms() throws {
        let cells = packs([(34000, 23000), (34001, 23000), (34001, 23001)], zoom: 16)
        let tiles = OfflineTileGrid.complement(of: cells, zoom: 16)
        let units = tiles.reduce(cells.count) { $0 + (1 << (2 * (16 - $1.zoom))) }
        #expect(Set(tiles).count == tiles.count)
        #expect(units == 1 << 32)
        #expect(OfflineTileGrid.complement(of: cells).count == 1)
        let rings = OfflineTileGrid.outline(of: cells, zoom: 16)
        #expect(rings.count == 1 && rings.first?.count == 7)
        let corner = try #require(rings.first?.first)
        let tile = try #require(OfflineTile(zoom: 16, x: corner.x, y: corner.y))
        #expect(corner.zoom == 16)
        #expect(corner.coordinate.latitude == tile.coordinates[3].latitude)
        #expect(corner.coordinate.longitude == tile.coordinates[3].longitude)
    }

    @Test func tilesCoveringARectangleIncludeEveryTileItOverlaps() {
        let rectangle = ring([(34000.25, 23000.25), (34002.75, 23000.25), (34002.75, 23001.75), (34000.25, 23001.75)])
        var expected: [(Int, Int)] = []
        for y in 23000...23001 {
            for x in 34000...34002 { expected.append((x, y)) }
        }
        #expect(OfflineTileGrid.tiles(covering: [rectangle], zoom: 16) == packs(expected, zoom: 16))
    }

    @Test func tilesCoveringSkipTilesInsideAHole() {
        let outer = ring([(34000.25, 23000.25), (34005.75, 23000.25), (34005.75, 23005.75), (34000.25, 23005.75)])
        let hole = ring([(34001.5, 23001.5), (34004.5, 23001.5), (34004.5, 23004.5), (34001.5, 23004.5)])
        var expected: [(Int, Int)] = []
        for y in 23000...23005 {
            for x in 34000...34005 where !((34002...34003).contains(x) && (23002...23003).contains(y)) { expected.append((x, y)) }
        }
        #expect(expected.count == 32)
        #expect(OfflineTileGrid.tiles(covering: [outer, hole], zoom: 16) == packs(expected, zoom: 16))
    }

    @Test func tilesCoveringMatchACheckOfEveryTileAgainstTheShape() {
        let points: [(Double, Double)] = [(34000.23, 23000.61), (34007.87, 23001.29), (34009.41, 23006.73), (34003.17, 23009.38), (33998.66, 23005.12)]
        let edges = Array(zip(points, points.dropFirst() + [points[0]]))
        var expected: [(Int, Int)] = []
        for y in 22998...23011 {
            for x in 33996...34012 {
                let centerX = Double(x) + 0.5
                let centerY = Double(y) + 0.5
                var inside = false
                var touched = false
                for (start, end) in edges {
                    if (start.1 <= centerY) != (end.1 <= centerY) {
                        let crossing = start.0 + (centerY - start.1) / (end.1 - start.1) * (end.0 - start.0)
                        if centerX < crossing { inside.toggle() }
                    }
                    if segment(from: start, to: end, meetsTileAt: x, y) { touched = true }
                }
                if inside || touched { expected.append((x, y)) }
            }
        }
        #expect(expected.count > 40)
        #expect(OfflineTileGrid.tiles(covering: [ring(points)], zoom: 16) == packs(expected, zoom: 16))
    }

    private func packs(_ cells: [(Int, Int)], zoom: Int = 12) -> Set<OfflineTile> {
        Set(cells.compactMap { OfflineTile(zoom: zoom, x: $0.0, y: $0.1) })
    }

    /// Converts points in zoom-16 tile units to an open ring of coordinates.
    private func ring(_ points: [(Double, Double)]) -> [CLLocationCoordinate2D] {
        let scale = Double(1 << 16)
        return points.map { point in
            let latitude = atan(sinh(.pi * (1 - 2 * point.1 / scale))) * 180 / .pi
            return CLLocationCoordinate2D(latitude: latitude, longitude: point.0 / scale * 360 - 180)
        }
    }

    /// Whether a segment in tile units meets the closed square of a tile, by Liang-Barsky clipping.
    private func segment(from start: (Double, Double), to end: (Double, Double), meetsTileAt x: Int, _ y: Int) -> Bool {
        let dx = end.0 - start.0
        let dy = end.1 - start.1
        let limits: [(Double, Double)] = [
            (-dx, start.0 - Double(x)), (dx, Double(x + 1) - start.0),
            (-dy, start.1 - Double(y)), (dy, Double(y + 1) - start.1),
        ]
        var enter = 0.0
        var exit = 1.0
        for (direction, distance) in limits {
            if direction == 0 {
                if distance < 0 { return false }
            } else if direction < 0 {
                enter = max(enter, distance / direction)
            } else {
                exit = min(exit, distance / direction)
            }
        }
        return enter <= exit
    }

    private func corners(_ points: [(Int, Int)]) -> Set<OfflineTileGrid.Corner> {
        Set(points.map { OfflineTileGrid.Corner(x: $0.0, y: $0.1) })
    }
}
