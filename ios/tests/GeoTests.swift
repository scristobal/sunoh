import Foundation
import Testing
@testable import Sunoh

struct GeoTests {
    @Test func greatCircleDistanceUsesTheShortPathAcrossTheAntimeridian() throws {
        let west = try Coordinate(latitude: 0, longitude: 179.99)
        let east = try Coordinate(latitude: 0, longitude: -179.99)
        let distance = Geo.distanceMeters(from: west, to: east)
        #expect(abs(distance - 2_223.8985) < 0.01)
        #expect(Geo.distanceMeters(from: east, to: west) == distance)
        #expect(Geo.distanceMeters(from: west, to: west) == 0)
    }

    @Test func greatCircleDistanceRemainsFiniteForAntipodesAndPoles() throws {
        let origin = try Coordinate(latitude: 0, longitude: 0)
        let quarter = try Coordinate(latitude: 0, longitude: 90)
        let antipode = try Coordinate(latitude: 0, longitude: 180)
        let north = try Coordinate(latitude: 90, longitude: 0)
        let south = try Coordinate(latitude: -90, longitude: 0)
        let halfCircumference = Double.pi * 6_371_000
        #expect(abs(Geo.distanceMeters(from: origin, to: quarter) - halfCircumference / 2) < 0.001)
        #expect(abs(Geo.distanceMeters(from: origin, to: antipode) - halfCircumference) < 0.001)
        #expect(abs(Geo.distanceMeters(from: north, to: south) - halfCircumference) < 0.001)
    }

    @Test func statisticsIncludeLongIntervalsAndPreserveSourceBoundariesMissingElevationAndElapsedTime() throws {
        let points = try [
            point(1_000, longitude: 0, elevation: 100),
            point(2_000, longitude: 1, elevation: 120),
            point(3_000, longitude: 2, elevation: nil),
            point(4_000, longitude: 3, elevation: 90),
            point(5_000, longitude: 4, elevation: 80),
            point(40_000, longitude: 80, elevation: 200)
        ]
        let geometry = fixtureGeometry([
            GPXSegment(points: points),
            GPXSegment(points: [try point(41_000, longitude: 90, elevation: 1_000)])
        ])
        let summary = ActivitySummary(id: "stats", startedAt: 1_000, lastPointAt: 41_000, pointCount: 7)
        let statistics = ActivityStatistics(activity: summary, geometry: geometry)
        #expect(abs(statistics.distanceMeters - 8_895_594.1316) < 0.01)
        #expect(statistics.elevationGainMeters == 140)
        #expect(statistics.elevationLossMeters == 10)
        #expect(statistics.minimumElevationMeters == 80)
        #expect(statistics.maximumElevationMeters == 1_000)
        #expect(statistics.elapsedDurationMilliseconds == 40_000)
    }

    @Test func emptyStatisticsHaveNoElevationRangeOrNegativeDuration() {
        let empty = ActivitySummary(id: "empty", startedAt: 1_000, lastPointAt: nil, pointCount: 0)
        #expect(ActivityStatistics(activity: empty, geometry: fixtureGeometry([])) == ActivityStatistics())
        let earlierEnd = ActivitySummary(id: "earlier", startedAt: 1_000, lastPointAt: 0, pointCount: 0)
        #expect(Geo.statistics(activity: earlierEnd, geometry: fixtureGeometry([])).elapsedDurationMilliseconds == 0)
    }

    @Test func mercatorProjectionWrapsLongitudeAndClampsPoles() throws {
        let origin = try Coordinate(latitude: 0, longitude: 179.99)
        let across = Geo.mercatorProjection(of: try Coordinate(latitude: 1, longitude: -179.99), relativeTo: origin)
        #expect(abs(across.x - 0.02) < 0.000001)
        #expect(across.y < 0)
        let north = Geo.mercatorProjection(of: try Coordinate(latitude: 90, longitude: 179.99), relativeTo: origin)
        let south = Geo.mercatorProjection(of: try Coordinate(latitude: -90, longitude: 179.99), relativeTo: origin)
        #expect(north.x == 0)
        #expect(north.y.isFinite && south.y.isFinite)
        #expect(abs(north.y + south.y) < 0.000001)
    }

    private func point(_ timestamp: Int64, longitude: Double, elevation: Double?) throws -> TrackPoint {
        try TrackPoint(timestampMilliseconds: timestamp, latitude: 0, longitude: longitude, elevationMeters: elevation)
    }
}
