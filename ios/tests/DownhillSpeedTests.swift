import Foundation
import Testing
@testable import Sunoh

struct DownhillSpeedTests {
    @Test func weightsRunsByMovingTime() throws {
        let geometry = try fixtureGeometry([
            GPXSegment(points: [point(0, distance: 0), point(30, distance: 150)]),
            GPXSegment(points: [point(40, distance: 200), point(50, distance: 350)])
        ])
        let speed = try #require(averageSpeed(in: geometry, runs: [passage(0, 30), passage(40, 50)]))
        #expect(abs(speed - 7.5) < 0.000001)
    }

    @Test func excludesLiftsStopsAndSlowCoordinateDrift() throws {
        let points = try [
            point(0, distance: 0), point(30, distance: 90), point(60, distance: 180),
            point(70, distance: 260), point(80, distance: 340), point(110, distance: 340),
            point(140, distance: 355), point(150, distance: 435), point(180, distance: 525)
        ]
        let speed = try #require(averageSpeed(in: fixtureGeometry([GPXSegment(points: points)]), runs: [passage(60, 150)]))
        #expect(abs(speed - 8) < 0.000001)
    }

    @Test func includesShortUphillAndFlatMovementWithinADetectedRun() throws {
        var points = [try point(0, distance: 0)]
        var distance = 0.0, elevation = 1_000.0
        for index in 1...22 {
            let isMiddle = (10...13).contains(index)
            distance += isMiddle ? 20 : 70
            elevation += isMiddle ? (index < 12 ? 5 : 0) : -10
            points.append(try point(index * 10, distance: distance, elevation: elevation))
        }
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let passages = SkiActivityDetector.analyze(geometry)
        #expect(passages.runCount == 1)
        #expect(passages.liftCount == 0)
        let speed = try #require(averageSpeed(in: geometry, runs: passages.runs))
        #expect(abs(speed - 1_340.0 / 220) < 0.000001)
    }

    @Test func clipsObservationIntervalsAtRunBoundaries() throws {
        let points = try [point(0, distance: 0), point(20, distance: 200), point(30, distance: 400)]
        let speed = try #require(averageSpeed(in: fixtureGeometry([GPXSegment(points: points)]), runs: [passage(10, 25)]))
        #expect(abs(speed - 200.0 / 15) < 0.000001)
    }

    @Test func includesLongSampleIntervalsWithoutBridgingSourceBoundaries() throws {
        let geometry = try fixtureGeometry([
            GPXSegment(points: [point(0, distance: 0), point(30, distance: 240), point(70, distance: 1_240), point(80, distance: 1_340)]),
            GPXSegment(points: [point(90, distance: 1_540), point(100, distance: 1_640)])
        ])
        let speed = try #require(averageSpeed(in: geometry, runs: [passage(0, 100)]))
        #expect(abs(speed - 16) < 0.000001)
    }

    @Test func excludesImplausibleJumpsFromDistanceAndTime() throws {
        let points = try [point(0, distance: 0), point(10, distance: 80), point(20, distance: 580), point(30, distance: 660)]
        let speed = try #require(averageSpeed(in: fixtureGeometry([GPXSegment(points: points)]), runs: [passage(0, 30)]))
        #expect(abs(speed - 8) < 0.000001)
    }

    @Test func missingElevationWithinARunKeepsObservedMovement() throws {
        let points = try [point(0, distance: 0), point(10, distance: 100, elevation: nil), point(20, distance: 200, elevation: 980)]
        let speed = try #require(averageSpeed(in: fixtureGeometry([GPXSegment(points: points)]), runs: [passage(0, 20)]))
        #expect(abs(speed - 10) < 0.000001)
    }

    @Test func noRunsOrNoUsableMovementHaveNoAverage() throws {
        let points = try [point(0, distance: 0), point(10, distance: 0), point(20, distance: 1_000)]
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        #expect(averageSpeed(in: geometry, runs: []) == nil)
        #expect(averageSpeed(in: geometry, runs: [passage(0, 20)]) == nil)
        #expect(averageSpeed(in: fixtureGeometry([]), runs: [passage(0, 20)]) == nil)
    }

    private func averageSpeed(in geometry: TrackGeometry, runs: [SkiActivityDetector.Passage]) -> Double? {
        Geo.skiStatistics(in: geometry, passages: .init(runs: runs)).averageDownhillSpeedMetersPerSecond
    }

    private func point(_ seconds: Int, distance: Double, elevation: Double? = 1_000) throws -> TrackPoint {
        try TrackPoint(timestampMilliseconds: Int64(seconds) * 1_000, latitude: 0,
                       longitude: distance * 180 / (.pi * 6_371_000), elevationMeters: elevation)
    }

    private func passage(_ startSeconds: Int, _ endSeconds: Int) -> SkiActivityDetector.Passage {
        SkiActivityDetector.Passage(startedAt: Timestamp(millisecondsSince1970: Int64(startSeconds) * 1_000),
                                    endedAt: Timestamp(millisecondsSince1970: Int64(endSeconds) * 1_000))
    }
}
