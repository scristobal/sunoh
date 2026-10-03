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

    @Test func coverageSubdividesTheWholePackIntoAlignedZoomFourteenTiles() throws {
        let pack = try #require(OfflineTile(zoom: 12, x: 2000, y: 1400))
        let tiles = OfflineTileGrid.coverageTiles(for: pack)
        #expect(Set(tiles).count == 16)
        #expect(tiles.allSatisfy { $0.zoom == 14 && $0.parent(atZoom: 12) == pack })
        let southWest = try #require(tiles.first { $0.x == 8000 && $0.y == 5603 })
        let northEast = try #require(tiles.first { $0.x == 8003 && $0.y == 5600 })
        #expect(southWest.coordinates[0].latitude == pack.coordinates[0].latitude)
        #expect(southWest.coordinates[0].longitude == pack.coordinates[0].longitude)
        #expect(northEast.coordinates[2].latitude == pack.coordinates[2].latitude)
        #expect(northEast.coordinates[2].longitude == pack.coordinates[2].longitude)
    }

    @Test func coverageRemainsWithinTheWorldAndRejectsOtherPackZooms() throws {
        let edge = try #require(OfflineTile(zoom: 12, x: 4095, y: 0))
        let tiles = OfflineTileGrid.coverageTiles(for: edge)
        #expect(tiles.count == 16)
        #expect(tiles.allSatisfy { (16380...16383).contains($0.x) && (0...3).contains($0.y) })
        #expect(tiles.flatMap(\.coordinates).allSatisfy { $0.longitude <= 180 && $0.latitude <= 85.05112877981 })
        #expect(OfflineTileGrid.coverageTiles(for: try #require(OfflineTile(zoom: 11, x: 2000, y: 1400))).isEmpty)
    }
}
