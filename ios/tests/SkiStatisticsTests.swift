import Foundation
import Testing
@testable import Sunoh

struct SkiStatisticsTests {
    @Test func detectedLiftsAndOutsideRunsAccountForEveryRecordedInterval() throws {
        var points: [TrackPoint] = []
        for seconds in stride(from: 0, through: 280, by: 5) {
            let distance: Double
            let elevation: Double
            switch seconds {
            case 0...20:
                distance = 0
                elevation = 1_500
            case 21...60:
                distance = Double(seconds - 20) * 2
                elevation = 1_500
            case 61...180:
                distance = 80 + Double(seconds - 60) * 3
                elevation = 1_500 + Double(seconds - 60)
            case 181...210:
                distance = 440
                elevation = 1_620
            case 211...250:
                distance = 440 + Double(seconds - 210) * 8
                elevation = 1_620 - Double(seconds - 210) * 2.5
            default:
                distance = 760 + Double(seconds - 250) * 2
                elevation = 1_520
            }
            points.append(try point(seconds, distance: distance, elevation: elevation))
        }
        let geometry = try fixtureGeometry([
            GPXSegment(points: points),
            GPXSegment(points: [point(400, distance: 1_000, elevation: nil), point(420, distance: 1_080, elevation: nil)]),
            GPXSegment(points: [point(600, distance: 2_000, elevation: nil)])
        ])
        let passages = SkiActivityDetector.analyze(geometry)
        let statistics = Geo.skiStatistics(in: geometry, passages: passages)

        #expect(passages.liftCount == 1)
        #expect(passages.runCount == 3)
        #expect(statistics.runDurationMilliseconds == 180_000)
        #expect(abs(statistics.runDistanceMeters - 540) < 0.000001)
        #expect(abs(try #require(statistics.averageDownhillSpeedMetersPerSecond) - 540.0 / 130) < 0.000001)
    }

    @Test func totalsRunsAndLiftsAndFindsIndependentRunRecords() throws {
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(10, distance: 100, elevation: 1_020),
            point(20, distance: 200, elevation: 750), point(30, distance: 300, elevation: 800),
            point(40, distance: 600, elevation: 900), point(50, distance: 900, elevation: 1_000),
            point(60, distance: 1_100, elevation: 990), point(90, distance: 1_400, elevation: 950),
            point(100, distance: 1_430, elevation: 1_000), point(110, distance: 1_460, elevation: 1_050),
            point(120, distance: 1_500, elevation: 1_050)
        ]
        let passages = SkiActivityDetector.Result(runs: [passage(0, 30), passage(50, 90)], lifts: [passage(30, 50), passage(90, 110)])
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]), passages: passages)

        #expect(abs(statistics.runDistanceMeters - 800) < 0.000001)
        #expect(statistics.runDurationMilliseconds == 70_000)
        #expect(abs(try #require(statistics.averageDownhillSpeedMetersPerSecond) - 800.0 / 70) < 0.000001)
        #expect(abs(try #require(statistics.maximumRunSpeedMetersPerSecond) - 20) < 0.000001)
        #expect(statistics.tallestRunHeightMeters == 270)
        #expect(abs(try #require(statistics.longestRunDistanceMeters) - 500) < 0.000001)
    }

    @Test func clipsDistanceTimeAndElevationAtPassageBoundaries() throws {
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(20, distance: 200, elevation: 800),
            point(30, distance: 400, elevation: 600)
        ]
        let passages = SkiActivityDetector.Result(runs: [passage(10, 25)], lifts: [passage(0, 10), passage(25, 30)])
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]), passages: passages)

        #expect(abs(statistics.runDistanceMeters - 200) < 0.000001)
        #expect(statistics.runDurationMilliseconds == 15_000)
        #expect(abs(try #require(statistics.averageDownhillSpeedMetersPerSecond) - 200.0 / 15) < 0.000001)
        #expect(abs(try #require(statistics.maximumRunSpeedMetersPerSecond) - 20) < 0.000001)
        #expect(statistics.tallestRunHeightMeters == 200)
        #expect(abs(try #require(statistics.longestRunDistanceMeters) - 200) < 0.000001)
    }

    @Test func countsStopTimeWithoutDriftAndIncludesLongIntervalsWithoutBridgingSourceBoundaries() throws {
        let geometry = try fixtureGeometry([
            GPXSegment(points: [
                point(0, distance: 0), point(10, distance: 80), point(20, distance: 80),
                point(30, distance: 85), point(60, distance: 325), point(100, distance: 725),
                point(110, distance: 805)
            ]),
            GPXSegment(points: [point(120, distance: 1_005), point(130, distance: 1_085)])
        ])
        let statistics = Geo.skiStatistics(in: geometry, passages: SkiActivityDetector.Result(runs: [passage(0, 130)]))

        #expect(abs(statistics.runDistanceMeters - 880) < 0.000001)
        #expect(statistics.runDurationMilliseconds == 120_000)
        #expect(abs(try #require(statistics.averageDownhillSpeedMetersPerSecond) - 8.8) < 0.000001)
        #expect(abs(try #require(statistics.maximumRunSpeedMetersPerSecond) - 10) < 0.000001)
        #expect(abs(try #require(statistics.longestRunDistanceMeters) - 880) < 0.000001)
    }

    @Test func rejectsJumpDistancesAndSpeedsWhileKeepingObservedDuration() throws {
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(10, distance: 80, elevation: 990),
            point(20, distance: 580, elevation: 900), point(30, distance: 660, elevation: 890),
            point(40, distance: 1_160, elevation: 990), point(50, distance: 1_190, elevation: 1_000)
        ]
        let passages = SkiActivityDetector.Result(runs: [passage(0, 30)], lifts: [passage(30, 50)])
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]), passages: passages)

        #expect(abs(statistics.runDistanceMeters - 160) < 0.000001)
        #expect(statistics.runDurationMilliseconds == 30_000)
        #expect(abs(try #require(statistics.averageDownhillSpeedMetersPerSecond) - 8) < 0.000001)
        #expect(abs(try #require(statistics.maximumRunSpeedMetersPerSecond) - 8) < 0.000001)
        #expect(abs(try #require(statistics.longestRunDistanceMeters) - 160) < 0.000001)
    }

    @Test func missingElevationDoesNotInventABoundaryHeightOrDiscardMovement() throws {
        let points = try [
            point(0, distance: 0, elevation: 2_000), point(10, distance: 100, elevation: nil),
            point(20, distance: 200, elevation: 900), point(30, distance: 300, elevation: 800),
            point(40, distance: 400, elevation: 1_000)
        ]
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]), passages: SkiActivityDetector.Result(runs: [passage(5, 35)]))

        #expect(abs(statistics.runDistanceMeters - 300) < 0.000001)
        #expect(statistics.runDurationMilliseconds == 30_000)
        #expect(statistics.tallestRunHeightMeters == 100)
        #expect(abs(try #require(statistics.averageDownhillSpeedMetersPerSecond) - 10) < 0.000001)
        #expect(abs(try #require(statistics.maximumRunSpeedMetersPerSecond) - 10) < 0.000001)
    }

    @Test func observationsWithoutElevationAreARunWithSpeedButNoHeightOrGrade() throws {
        let points = try [point(0, distance: 0, elevation: nil), point(10, distance: 100, elevation: nil)]
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let passages = SkiActivityDetector.analyze(geometry)
        let statistics = Geo.skiStatistics(in: geometry, passages: passages)

        #expect(passages.runCount == 1)
        #expect(passages.liftCount == 0)
        #expect(statistics.runDurationMilliseconds == 10_000)
        #expect(statistics.tallestRunHeightMeters == nil)
        #expect(statistics.averageRunSteepnessPercent == nil)
        #expect(statistics.maximumRunSteepnessPercent == nil)
        #expect(abs(try #require(statistics.longestRunDistanceMeters) - 100) < 0.000001)
        #expect(abs(try #require(statistics.averageDownhillSpeedMetersPerSecond) - 10) < 0.000001)
    }

    @Test func runAverageExcludesLiftIntervals() throws {
        let points = try [
            point(0, distance: 0), point(10, distance: 200), point(40, distance: 260),
            point(50, distance: 380), point(60, distance: 440), point(70, distance: 640)
        ]
        let passages = SkiActivityDetector.Result(runs: [passage(0, 10), passage(40, 50), passage(60, 70)], lifts: [passage(10, 40), passage(50, 60)])
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]), passages: passages)

        #expect(abs(try #require(statistics.averageDownhillSpeedMetersPerSecond) - 520.0 / 30) < 0.000001)
    }

    @Test func ignoresIntervalsWithNonpositiveDuration() throws {
        let points = try [
            point(0, distance: 0, elevation: 1_500), point(0, distance: 100, elevation: 1_000),
            point(10, distance: 180, elevation: 990), point(5, distance: 200, elevation: 500),
            point(15, distance: 280, elevation: 480)
        ]
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]), passages: SkiActivityDetector.Result(runs: [passage(0, 20)]))

        #expect(abs(statistics.runDistanceMeters - 160) < 0.000001)
        #expect(statistics.runDurationMilliseconds == 20_000)
        #expect(abs(try #require(statistics.averageDownhillSpeedMetersPerSecond) - 8) < 0.000001)
    }

    @Test(arguments: [true, false]) func noDetectedPassagesHaveNoTotalsOrRunRecords(emptyTrack: Bool) throws {
        let segments = emptyTrack ? [] : [GPXSegment(points: try [point(0, distance: 0), point(10, distance: 100)])]
        let statistics = Geo.skiStatistics(in: fixtureGeometry(segments), passages: SkiActivityDetector.Result())

        #expect(statistics.runDistanceMeters == 0)
        #expect(statistics.runDurationMilliseconds == 0)
        #expect(statistics.averageDownhillSpeedMetersPerSecond == nil)
        #expect(statistics.maximumRunSpeedMetersPerSecond == nil)
        #expect(statistics.tallestRunHeightMeters == nil)
        #expect(statistics.longestRunDistanceMeters == nil)
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
