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

    private func packs(_ cells: [(Int, Int)]) -> Set<OfflineTile> {
        Set(cells.compactMap { OfflineTile(zoom: 12, x: $0.0, y: $0.1) })
    }

    private func corners(_ points: [(Int, Int)]) -> Set<OfflineTileGrid.Corner> {
        Set(points.map { OfflineTileGrid.Corner(x: $0.0, y: $0.1) })
    }
}
