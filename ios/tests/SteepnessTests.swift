import Foundation
import Testing
@testable import Sunoh

struct SteepnessTests {
    @Test(arguments: [true, false]) func averagesByDistanceAndFindsTheSteepestWholePassage(isRun: Bool) throws {
        let direction = isRun ? -1.0 : 1.0
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(10, distance: 100, elevation: 1_000 + direction * 100),
            point(30, distance: 400, elevation: 1_000 + direction * 120), point(40, distance: 500, elevation: 1_000),
            point(50, distance: 600, elevation: 1_000 + direction * 50)
        ]
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]),
                                           passages: passages(isRun: isRun, ranges: [passage(0, 30), passage(40, 50)]))
        let average = try #require(isRun ? statistics.averageRunSteepnessPercent : statistics.averageLiftSteepnessPercent)
        let maximum = try #require(isRun ? statistics.maximumRunSteepnessPercent : statistics.maximumLiftSteepnessPercent)

        #expect(abs(average - 34) < 0.000001)
        #expect(abs(maximum - 50) < 0.000001)
        #expect((isRun ? statistics.averageLiftSteepnessPercent : statistics.averageRunSteepnessPercent) == nil)
        #expect((isRun ? statistics.maximumLiftSteepnessPercent : statistics.maximumRunSteepnessPercent) == nil)
    }

    @Test(arguments: [true, false]) func flatAndOppositeDirectionMovementStillContributeDistance(isRun: Bool) throws {
        let direction = isRun ? -1.0 : 1.0
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(10, distance: 100, elevation: 1_000 + direction * 100),
            point(20, distance: 200, elevation: 1_000 + direction * 100), point(30, distance: 300, elevation: 1_000 + direction * 70)
        ]
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]),
                                           passages: passages(isRun: isRun, ranges: [passage(0, 30)]))
        let average = try #require(isRun ? statistics.averageRunSteepnessPercent : statistics.averageLiftSteepnessPercent)
        let maximum = try #require(isRun ? statistics.maximumRunSteepnessPercent : statistics.maximumLiftSteepnessPercent)

        #expect(abs(average - 100.0 / 3) < 0.000001)
        #expect(abs(maximum - 100.0 / 3) < 0.000001)
    }

    @Test(arguments: [true, false]) func excludesStationaryNoiseFromTotalsAndSlowOrImplausibleMovementFromSteepness(isRun: Bool) throws {
        let direction = isRun ? -1.0 : 1.0
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(10, distance: 0, elevation: 1_000 + direction * 100),
            point(20, distance: 5, elevation: 1_000 + direction * 200), point(30, distance: 505, elevation: 1_000 + direction * 300),
            point(40, distance: 605, elevation: 1_000 + direction * 320)
        ]
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]),
                                           passages: passages(isRun: isRun, ranges: [passage(0, 40)]))
        let average = try #require(isRun ? statistics.averageRunSteepnessPercent : statistics.averageLiftSteepnessPercent)
        let maximum = try #require(isRun ? statistics.maximumRunSteepnessPercent : statistics.maximumLiftSteepnessPercent)

        #expect(abs(average - 20) < 0.000001)
        #expect(abs(maximum - 20) < 0.000001)
        #expect((isRun ? statistics.runElevationLossMeters : statistics.liftElevationGainMeters) == 120)
        #expect(abs((isRun ? statistics.runDistanceMeters : statistics.liftDistanceMeters) - 100) < 0.000001)
        #expect((isRun ? statistics.runDurationMilliseconds : statistics.liftDurationMilliseconds) == 40_000)
    }

    @Test(arguments: [true, false]) func includesLongIntervalsButExcludesMissingAltitudeAndSourceBoundariesFromGrade(isRun: Bool) throws {
        func elevation(_ value: Double) -> Double { isRun ? value : 2_000 - value }
        let geometry = try fixtureGeometry([
            GPXSegment(points: [
                point(0, distance: 0, elevation: elevation(1_000)), point(10, distance: 100, elevation: elevation(900)),
                point(20, distance: 300, elevation: nil), point(30, distance: 500, elevation: elevation(880)),
                point(70, distance: 600, elevation: elevation(500)), point(80, distance: 900, elevation: elevation(470))
            ]),
            GPXSegment(points: [point(90, distance: 1_000, elevation: elevation(100)), point(100, distance: 1_100, elevation: elevation(80))])
        ])
        let statistics = Geo.skiStatistics(in: geometry, passages: passages(isRun: isRun, ranges: [passage(0, 100)]))
        let average = try #require(isRun ? statistics.averageRunSteepnessPercent : statistics.averageLiftSteepnessPercent)
        let maximum = try #require(isRun ? statistics.maximumRunSteepnessPercent : statistics.maximumLiftSteepnessPercent)

        #expect(abs(average - 530.0 / 600 * 100) < 0.000001)
        #expect(abs(maximum - 530.0 / 600 * 100) < 0.000001)
        #expect(abs((isRun ? statistics.runDistanceMeters : statistics.liftDistanceMeters) - 1_000) < 0.000001)
    }

    @Test(arguments: [true, false]) func clipsElevationAndDistanceAtFractionalSecondBoundaries(isRun: Bool) throws {
        let direction = isRun ? -1.0 : 1.0
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(10, distance: 100, elevation: 1_000 + direction * 100),
            point(20, distance: 400, elevation: 1_000 + direction * 130)
        ]
        let range = SkiActivityDetector.Passage(startedAt: 2_500, endedAt: 12_500)
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]), passages: passages(isRun: isRun, ranges: [range]))
        let average = try #require(isRun ? statistics.averageRunSteepnessPercent : statistics.averageLiftSteepnessPercent)
        let maximum = try #require(isRun ? statistics.maximumRunSteepnessPercent : statistics.maximumLiftSteepnessPercent)

        #expect(abs(average - 55) < 0.000001)
        #expect(abs(maximum - 55) < 0.000001)
        #expect((isRun ? statistics.runElevationLossMeters : statistics.liftElevationGainMeters) == 82.5)
        #expect(abs((isRun ? statistics.runDistanceMeters : statistics.liftDistanceMeters) - 150) < 0.000001)
    }

    @Test(arguments: [true, false]) func unavailableGradeDiffersFromMeasuredFlatMovement(isRun: Bool) throws {
        let stationary = try [point(0, distance: 0, elevation: 1_000), point(10, distance: 0, elevation: 900)]
        let unknownAltitude = try [point(0, distance: 0, elevation: nil), point(10, distance: 100, elevation: nil)]
        for points in [[], stationary, unknownAltitude] {
            let geometry = points.isEmpty ? fixtureGeometry([]) : fixtureGeometry([GPXSegment(points: points)])
            let statistics = Geo.skiStatistics(in: geometry, passages: passages(isRun: isRun, ranges: [passage(0, 10)]))
            #expect((isRun ? statistics.averageRunSteepnessPercent : statistics.averageLiftSteepnessPercent) == nil)
            #expect((isRun ? statistics.maximumRunSteepnessPercent : statistics.maximumLiftSteepnessPercent) == nil)
        }
        let flat = try [point(0, distance: 0, elevation: 1_000), point(10, distance: 100, elevation: 1_000)]
        let geometry = fixtureGeometry([GPXSegment(points: flat)])
        let classified = isRun ? SkiActivityDetector.analyze(geometry) : passages(isRun: false, ranges: [passage(0, 10)])
        #expect(isRun ? classified.runCount == 1 : classified.liftCount == 1)
        let statistics = Geo.skiStatistics(in: geometry, passages: classified)
        #expect((isRun ? statistics.averageRunSteepnessPercent : statistics.averageLiftSteepnessPercent) == 0)
        #expect((isRun ? statistics.maximumRunSteepnessPercent : statistics.maximumLiftSteepnessPercent) == 0)
    }

    @Test(arguments: [true, false]) func percentageGradesCanExceedOneHundred(isRun: Bool) throws {
        let points = try [point(0, distance: 0, elevation: 1_000), point(10, distance: 100, elevation: isRun ? 750 : 1_250)]
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]), passages: passages(isRun: isRun, ranges: [passage(0, 10)]))
        let average = try #require(isRun ? statistics.averageRunSteepnessPercent : statistics.averageLiftSteepnessPercent)
        let maximum = try #require(isRun ? statistics.maximumRunSteepnessPercent : statistics.maximumLiftSteepnessPercent)

        #expect(abs(average - 250) < 0.000001)
        #expect(abs(maximum - 250) < 0.000001)
    }

    @Test(arguments: [true, false]) func unrepresentablePercentagesAndAggregateElevationRemainUnavailable(isRun: Bool) throws {
        let high = 1e308
        let startElevation = isRun ? high : 0
        let endElevation = isRun ? 0 : high
        let short = try [point(0, distance: 0, elevation: startElevation), point(10, distance: 20, elevation: endElevation)]
        let shortStatistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: short)]), passages: passages(isRun: isRun, ranges: [passage(0, 10)]))
        #expect((isRun ? shortStatistics.averageRunSteepnessPercent : shortStatistics.averageLiftSteepnessPercent) == nil)
        #expect((isRun ? shortStatistics.maximumRunSteepnessPercent : shortStatistics.maximumLiftSteepnessPercent) == nil)

        let repeated = try [
            point(0, distance: 0, elevation: startElevation), point(10, distance: 100, elevation: endElevation),
            point(20, distance: 200, elevation: startElevation), point(30, distance: 300, elevation: endElevation)
        ]
        let aggregate = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: repeated)]),
                                         passages: passages(isRun: isRun, ranges: [passage(0, 10), passage(20, 30)]))
        #expect((isRun ? aggregate.averageRunSteepnessPercent : aggregate.averageLiftSteepnessPercent) == nil)
        #expect(try #require(isRun ? aggregate.maximumRunSteepnessPercent : aggregate.maximumLiftSteepnessPercent).isFinite)
    }

    private func point(_ seconds: Int, distance: Double, elevation: Double?) throws -> TrackPoint {
        try TrackPoint(timestampMilliseconds: Int64(seconds) * 1_000, latitude: 0,
                       longitude: distance * 180 / (.pi * 6_371_000), elevationMeters: elevation)
    }

    private func passage(_ startSeconds: Int, _ endSeconds: Int) -> SkiActivityDetector.Passage {
        SkiActivityDetector.Passage(startedAt: Timestamp(millisecondsSince1970: Int64(startSeconds) * 1_000),
                                    endedAt: Timestamp(millisecondsSince1970: Int64(endSeconds) * 1_000))
    }

    private func passages(isRun: Bool, ranges: [SkiActivityDetector.Passage]) -> SkiActivityDetector.Result {
        isRun ? SkiActivityDetector.Result(runs: ranges) : SkiActivityDetector.Result(lifts: ranges)
    }
}
