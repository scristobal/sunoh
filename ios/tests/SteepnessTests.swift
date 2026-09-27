import Foundation
import Testing
@testable import Sunoh

struct SteepnessTests {
    @Test func averagesByDistanceAndFindsTheSteepestWholePassage() throws {
        let direction = -1.0
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(10, distance: 100, elevation: 1_000 + direction * 100),
            point(30, distance: 400, elevation: 1_000 + direction * 120), point(40, distance: 500, elevation: 1_000),
            point(50, distance: 600, elevation: 1_000 + direction * 50)
        ]
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]),
                                           passages: SkiActivityDetector.Result(runs: [passage(0, 30), passage(40, 50)]))
        let average = try #require(statistics.averageRunSteepnessPercent)
        let maximum = try #require(statistics.maximumRunSteepnessPercent)

        #expect(abs(average - 34) < 0.000001)
        #expect(abs(maximum - 50) < 0.000001)
    }

    @Test func flatAndOppositeDirectionMovementStillContributeDistance() throws {
        let direction = -1.0
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(10, distance: 100, elevation: 1_000 + direction * 100),
            point(20, distance: 200, elevation: 1_000 + direction * 100), point(30, distance: 300, elevation: 1_000 + direction * 70)
        ]
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]),
                                           passages: SkiActivityDetector.Result(runs: [passage(0, 30)]))
        let average = try #require(statistics.averageRunSteepnessPercent)
        let maximum = try #require(statistics.maximumRunSteepnessPercent)

        #expect(abs(average - 100.0 / 3) < 0.000001)
        #expect(abs(maximum - 100.0 / 3) < 0.000001)
    }

    @Test func excludesStationaryNoiseFromTotalsAndSlowOrImplausibleMovementFromSteepness() throws {
        let direction = -1.0
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(10, distance: 0, elevation: 1_000 + direction * 100),
            point(20, distance: 5, elevation: 1_000 + direction * 200), point(30, distance: 505, elevation: 1_000 + direction * 300),
            point(40, distance: 605, elevation: 1_000 + direction * 320)
        ]
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]),
                                           passages: SkiActivityDetector.Result(runs: [passage(0, 40)]))
        let average = try #require(statistics.averageRunSteepnessPercent)
        let maximum = try #require(statistics.maximumRunSteepnessPercent)

        #expect(abs(average - 20) < 0.000001)
        #expect(abs(maximum - 20) < 0.000001)
        #expect(abs(statistics.runDistanceMeters - 100) < 0.000001)
        #expect(statistics.runDurationMilliseconds == 40_000)
    }

    @Test func includesLongIntervalsButExcludesMissingAltitudeAndSourceBoundariesFromGrade() throws {
        let geometry = try fixtureGeometry([
            GPXSegment(points: [
                point(0, distance: 0, elevation: 1_000), point(10, distance: 100, elevation: 900),
                point(20, distance: 300, elevation: nil), point(30, distance: 500, elevation: 880),
                point(70, distance: 600, elevation: 500), point(80, distance: 900, elevation: 470)
            ]),
            GPXSegment(points: [point(90, distance: 1_000, elevation: 100), point(100, distance: 1_100, elevation: 80)])
        ])
        let statistics = Geo.skiStatistics(in: geometry, passages: SkiActivityDetector.Result(runs: [passage(0, 100)]))
        let average = try #require(statistics.averageRunSteepnessPercent)
        let maximum = try #require(statistics.maximumRunSteepnessPercent)

        #expect(abs(average - 530.0 / 600 * 100) < 0.000001)
        #expect(abs(maximum - 530.0 / 600 * 100) < 0.000001)
        #expect(abs(statistics.runDistanceMeters - 1_000) < 0.000001)
    }

    @Test func clipsElevationAndDistanceAtFractionalSecondBoundaries() throws {
        let direction = -1.0
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(10, distance: 100, elevation: 1_000 + direction * 100),
            point(20, distance: 400, elevation: 1_000 + direction * 130)
        ]
        let range = SkiActivityDetector.Passage(startedAt: 2_500, endedAt: 12_500)
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]), passages: SkiActivityDetector.Result(runs: [range]))
        let average = try #require(statistics.averageRunSteepnessPercent)
        let maximum = try #require(statistics.maximumRunSteepnessPercent)

        #expect(abs(average - 55) < 0.000001)
        #expect(abs(maximum - 55) < 0.000001)
        #expect(abs(statistics.runDistanceMeters - 150) < 0.000001)
    }

    @Test func unavailableGradeDiffersFromMeasuredFlatMovement() throws {
        let stationary = try [point(0, distance: 0, elevation: 1_000), point(10, distance: 0, elevation: 900)]
        let unknownAltitude = try [point(0, distance: 0, elevation: nil), point(10, distance: 100, elevation: nil)]
        for points in [[], stationary, unknownAltitude] {
            let geometry = points.isEmpty ? fixtureGeometry([]) : fixtureGeometry([GPXSegment(points: points)])
            let statistics = Geo.skiStatistics(in: geometry, passages: SkiActivityDetector.Result(runs: [passage(0, 10)]))
            #expect(statistics.averageRunSteepnessPercent == nil)
            #expect(statistics.maximumRunSteepnessPercent == nil)
        }
        let flat = try [point(0, distance: 0, elevation: 1_000), point(10, distance: 100, elevation: 1_000)]
        let geometry = fixtureGeometry([GPXSegment(points: flat)])
        let classified = SkiActivityDetector.analyze(geometry)
        #expect(classified.runCount == 1)
        let statistics = Geo.skiStatistics(in: geometry, passages: classified)
        #expect(statistics.averageRunSteepnessPercent == 0)
        #expect(statistics.maximumRunSteepnessPercent == 0)
    }

    @Test func percentageGradesCanExceedOneHundred() throws {
        let points = try [point(0, distance: 0, elevation: 1_000), point(10, distance: 100, elevation: 750)]
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]), passages: SkiActivityDetector.Result(runs: [passage(0, 10)]))
        let average = try #require(statistics.averageRunSteepnessPercent)
        let maximum = try #require(statistics.maximumRunSteepnessPercent)

        #expect(abs(average - 250) < 0.000001)
        #expect(abs(maximum - 250) < 0.000001)
    }

    @Test func unrepresentablePercentagesAndAggregateElevationRemainUnavailable() throws {
        let high = 1e308
        let startElevation = high
        let endElevation = 0.0
        let short = try [point(0, distance: 0, elevation: startElevation), point(10, distance: 20, elevation: endElevation)]
        let shortStatistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: short)]), passages: SkiActivityDetector.Result(runs: [passage(0, 10)]))
        #expect(shortStatistics.averageRunSteepnessPercent == nil)
        #expect(shortStatistics.maximumRunSteepnessPercent == nil)

        let repeated = try [
            point(0, distance: 0, elevation: startElevation), point(10, distance: 100, elevation: endElevation),
            point(20, distance: 200, elevation: startElevation), point(30, distance: 300, elevation: endElevation)
        ]
        let aggregate = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: repeated)]),
                                         passages: SkiActivityDetector.Result(runs: [passage(0, 10), passage(20, 30)]))
        #expect(aggregate.averageRunSteepnessPercent == nil)
        #expect(try #require(aggregate.maximumRunSteepnessPercent).isFinite)
    }

    private func point(_ seconds: Int, distance: Double, elevation: Double?) throws -> TrackPoint {
        try TrackPoint(timestampMilliseconds: Int64(seconds) * 1_000, latitude: 0,
                       longitude: distance * 180 / (.pi * 6_371_000), elevationMeters: elevation)
    }

    private func passage(_ startSeconds: Int, _ endSeconds: Int) -> SkiActivityDetector.Passage {
        SkiActivityDetector.Passage(startedAt: Timestamp(millisecondsSince1970: Int64(startSeconds) * 1_000),
                                    endedAt: Timestamp(millisecondsSince1970: Int64(endSeconds) * 1_000))
    }

}
