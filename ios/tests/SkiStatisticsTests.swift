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
        #expect(statistics.liftDurationMilliseconds == 120_000)
        #expect(statistics.runDurationMilliseconds + statistics.liftDurationMilliseconds == 300_000)
        #expect(abs(statistics.runDistanceMeters - 540) < 0.000001)
        #expect(abs(statistics.liftDistanceMeters - 360) < 0.000001)
        #expect(abs(statistics.runDistanceMeters + statistics.liftDistanceMeters - 900) < 0.000001)
        #expect(abs(try #require(statistics.averageDownhillSpeedMetersPerSecond) - 540.0 / 130) < 0.000001)
        #expect(abs(try #require(statistics.averageLiftSpeedMetersPerSecond) - 3) < 0.000001)
        #expect(statistics.runElevationLossMeters == 100)
        #expect(statistics.liftElevationGainMeters == 120)
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
        #expect(abs(statistics.liftDistanceMeters - 660) < 0.000001)
        #expect(statistics.runDurationMilliseconds == 70_000)
        #expect(statistics.liftDurationMilliseconds == 40_000)
        #expect(statistics.runElevationLossMeters == 320)
        #expect(statistics.liftElevationGainMeters == 300)
        #expect(abs(try #require(statistics.averageDownhillSpeedMetersPerSecond) - 800.0 / 70) < 0.000001)
        #expect(abs(try #require(statistics.averageLiftSpeedMetersPerSecond) - 16.5) < 0.000001)
        #expect(abs(try #require(statistics.maximumRunSpeedMetersPerSecond) - 20) < 0.000001)
        #expect(statistics.tallestRunHeightMeters == 270)
        #expect(abs(try #require(statistics.longestRunDistanceMeters) - 500) < 0.000001)
        #expect(statistics.tallestLiftHeightMeters == 200)
        #expect(abs(try #require(statistics.longestLiftDistanceMeters) - 600) < 0.000001)
    }

    @Test func clipsDistanceTimeAndElevationAtPassageBoundaries() throws {
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(20, distance: 200, elevation: 800),
            point(30, distance: 400, elevation: 600)
        ]
        let passages = SkiActivityDetector.Result(runs: [passage(10, 25)], lifts: [passage(0, 10), passage(25, 30)])
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]), passages: passages)

        #expect(abs(statistics.runDistanceMeters - 200) < 0.000001)
        #expect(abs(statistics.liftDistanceMeters - 200) < 0.000001)
        #expect(statistics.runDurationMilliseconds == 15_000)
        #expect(statistics.liftDurationMilliseconds == 15_000)
        #expect(abs(try #require(statistics.averageDownhillSpeedMetersPerSecond) - 200.0 / 15) < 0.000001)
        #expect(abs(try #require(statistics.averageLiftSpeedMetersPerSecond) - 200.0 / 15) < 0.000001)
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
        #expect(abs(statistics.liftDistanceMeters - 30) < 0.000001)
        #expect(statistics.runDurationMilliseconds == 30_000)
        #expect(statistics.liftDurationMilliseconds == 20_000)
        #expect(statistics.runElevationLossMeters == 110)
        #expect(statistics.liftElevationGainMeters == 110)
        #expect(abs(try #require(statistics.averageDownhillSpeedMetersPerSecond) - 8) < 0.000001)
        #expect(abs(try #require(statistics.averageLiftSpeedMetersPerSecond) - 3) < 0.000001)
        #expect(abs(try #require(statistics.maximumRunSpeedMetersPerSecond) - 8) < 0.000001)
        #expect(abs(try #require(statistics.longestRunDistanceMeters) - 160) < 0.000001)
        #expect(statistics.tallestLiftHeightMeters == 110)
        #expect(abs(try #require(statistics.longestLiftDistanceMeters) - 30) < 0.000001)
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
        #expect(statistics.runElevationLossMeters == 100)
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
        #expect(statistics.averageLiftSpeedMetersPerSecond == nil)
        #expect(statistics.runElevationLossMeters == 0)
        #expect(statistics.liftElevationGainMeters == 0)
        #expect(statistics.tallestLiftHeightMeters == nil)
        #expect(statistics.longestLiftDistanceMeters == nil)
    }

    @Test func liftAscentAccumulatesReversalsAndTallestAndLongestCanBeDifferentLifts() throws {
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(10, distance: 30, elevation: 1_100),
            point(20, distance: 60, elevation: 1_080), point(30, distance: 90, elevation: 1_200),
            point(40, distance: 200, elevation: 800), point(50, distance: 300, elevation: 820),
            point(60, distance: 400, elevation: 815), point(70, distance: 500, elevation: 850)
        ]
        let passages = SkiActivityDetector.Result(lifts: [passage(0, 30), passage(40, 70)])
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]), passages: passages)

        #expect(statistics.liftElevationGainMeters == 275)
        #expect(statistics.tallestLiftHeightMeters == 200)
        #expect(abs(try #require(statistics.longestLiftDistanceMeters) - 300) < 0.000001)
        #expect(statistics.runElevationLossMeters == 0)
        #expect(statistics.tallestRunHeightMeters == nil)
        #expect(statistics.longestRunDistanceMeters == nil)
    }

    @Test func clipsRunDescentAndLiftAscentToTheirPassages() throws {
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(20, distance: 200, elevation: 800),
            point(40, distance: 400, elevation: 1_200), point(60, distance: 600, elevation: 1_400)
        ]
        let passages = SkiActivityDetector.Result(runs: [passage(5, 15)], lifts: [passage(25, 45)])
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]), passages: passages)

        #expect(statistics.runElevationLossMeters == 100)
        #expect(statistics.liftElevationGainMeters == 350)
        #expect(statistics.tallestLiftHeightMeters == 350)
        #expect(abs(try #require(statistics.longestLiftDistanceMeters) - 200) < 0.000001)
    }

    @Test(arguments: [true, false]) func elevationTotalsIncludeLongIntervalsButDoNotBridgeMissingAltitudeOrSourceBoundaries(isRun: Bool) throws {
        func elevation(_ value: Double) -> Double { isRun ? value : 2_000 - value }
        let geometry = try fixtureGeometry([
            GPXSegment(points: [
                point(0, distance: 0, elevation: elevation(1_000)), point(10, distance: 30, elevation: elevation(990)),
                point(20, distance: 60, elevation: nil), point(30, distance: 90, elevation: elevation(970)),
                point(70, distance: 210, elevation: elevation(500)), point(80, distance: 240, elevation: elevation(490))
            ]),
            GPXSegment(points: [point(90, distance: 270, elevation: elevation(100)), point(100, distance: 300, elevation: elevation(90))])
        ])
        let passages = isRun ? SkiActivityDetector.Result(runs: [passage(0, 100)]) : SkiActivityDetector.Result(lifts: [passage(0, 100)])
        let statistics = Geo.skiStatistics(in: geometry, passages: passages)

        #expect(statistics.runElevationLossMeters == (isRun ? 500 : 0))
        #expect(statistics.liftElevationGainMeters == (isRun ? 0 : 500))
    }

    @Test(arguments: [true, false]) func liftRecordsDoNotInventMovementBetweenIsolatedObservations(hasElevation: Bool) throws {
        let geometry = try fixtureGeometry([
            GPXSegment(points: [point(0, distance: 0, elevation: hasElevation ? 1_000 : nil)]),
            GPXSegment(points: [point(20, distance: 100, elevation: hasElevation ? 1_050 : nil)])
        ])
        let statistics = Geo.skiStatistics(in: geometry, passages: SkiActivityDetector.Result(lifts: [passage(0, 20)]))

        #expect(statistics.liftElevationGainMeters == 0)
        #expect(statistics.tallestLiftHeightMeters == (hasElevation ? 50 : nil))
        #expect(statistics.longestLiftDistanceMeters == nil)
    }

    @Test func weightsLiftSpeedByMovingTimeAndKeepsRunSpeedSeparate() throws {
        let points = try [
            point(0, distance: 0), point(10, distance: 200), point(40, distance: 260),
            point(50, distance: 380), point(60, distance: 440), point(70, distance: 640)
        ]
        let passages = SkiActivityDetector.Result(runs: [passage(0, 10), passage(40, 50), passage(60, 70)], lifts: [passage(10, 40), passage(50, 60)])
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]), passages: passages)

        #expect(abs(try #require(statistics.averageLiftSpeedMetersPerSecond) - 3) < 0.000001)
        #expect(abs(try #require(statistics.averageDownhillSpeedMetersPerSecond) - 520.0 / 30) < 0.000001)
    }

    @Test func liftSpeedIncludesLongIntervalsButExcludesStopsDriftJumpsAndSourceBoundaries() throws {
        let geometry = try fixtureGeometry([
            GPXSegment(points: [
                point(0, distance: 0), point(10, distance: 30), point(20, distance: 30),
                point(30, distance: 35), point(40, distance: 535), point(80, distance: 935),
                point(90, distance: 965)
            ]),
            GPXSegment(points: [point(100, distance: 1_065), point(110, distance: 1_095)])
        ])
        let statistics = Geo.skiStatistics(in: geometry, passages: SkiActivityDetector.Result(lifts: [passage(0, 110)]))

        #expect(abs(try #require(statistics.averageLiftSpeedMetersPerSecond) - 7) < 0.000001)
        #expect(statistics.averageDownhillSpeedMetersPerSecond == nil)
    }

    @Test func aLiftWithoutUsableMovementHasNoAverageSpeed() throws {
        let points = try [point(0, distance: 0), point(10, distance: 0), point(20, distance: 5), point(30, distance: 505)]
        let statistics = Geo.skiStatistics(in: fixtureGeometry([GPXSegment(points: points)]), passages: SkiActivityDetector.Result(lifts: [passage(0, 30)]))

        #expect(statistics.averageLiftSpeedMetersPerSecond == nil)
        #expect(statistics.averageDownhillSpeedMetersPerSecond == nil)
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
        #expect(statistics.runElevationLossMeters == 30)
        #expect(abs(try #require(statistics.averageDownhillSpeedMetersPerSecond) - 8) < 0.000001)
    }

    @Test(arguments: [true, false]) func noDetectedPassagesHaveNoTotalsOrRunRecords(emptyTrack: Bool) throws {
        let segments = emptyTrack ? [] : [GPXSegment(points: try [point(0, distance: 0), point(10, distance: 100)])]
        let statistics = Geo.skiStatistics(in: fixtureGeometry(segments), passages: SkiActivityDetector.Result())

        #expect(statistics.runDistanceMeters == 0)
        #expect(statistics.liftDistanceMeters == 0)
        #expect(statistics.runDurationMilliseconds == 0)
        #expect(statistics.liftDurationMilliseconds == 0)
        #expect(statistics.runElevationLossMeters == 0)
        #expect(statistics.liftElevationGainMeters == 0)
        #expect(statistics.averageDownhillSpeedMetersPerSecond == nil)
        #expect(statistics.averageLiftSpeedMetersPerSecond == nil)
        #expect(statistics.maximumRunSpeedMetersPerSecond == nil)
        #expect(statistics.tallestRunHeightMeters == nil)
        #expect(statistics.longestRunDistanceMeters == nil)
        #expect(statistics.tallestLiftHeightMeters == nil)
        #expect(statistics.longestLiftDistanceMeters == nil)
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
