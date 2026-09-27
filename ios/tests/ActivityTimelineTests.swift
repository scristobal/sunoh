import Foundation
import Testing
@testable import Sunoh

struct ActivityTimelineTests {
    @Test func allIntervalsOutsideLiftsAreRunRegardlessOfSlopeOrMovement() throws {
        let points = try [point(0, distance: 0), point(10, distance: 100), point(20, distance: 200),
                          point(30, distance: 300, elevation: 900), point(40, distance: 400, elevation: 1_100),
                          point(50, distance: 500), point(60, distance: 600)]
        let passages = SkiActivityDetector.Result(runs: [passage(10, 20)], lifts: [passage(40, 50)])
        let timeline = Geo.timeline(in: fixtureGeometry([GPXSegment(points: points)]), passages: passages)

        #expect(timeline.entries.map(\.kind) == [.run, .lift, .run])
        #expect(timeline.entries.map(\.endedAt) == [40_000, 50_000, 60_000])
        #expect(timeline.entries[0].elevationLossMeters == 100)
        #expect(timeline.entries[0].elevationGainMeters == 200)
        #expect(timeline.entries[0].pointCount == 5)
        #expect(timeline.entries[2].elevationLossMeters == 0)
        #expect(timeline.entries[2].elevationLossMeters?.sign == .plus)
        #expect(timeline.entries[2].elevationGainMeters?.sign == .plus)
        expectCoverage(timeline, from: 0, to: 60_000)
    }

    @Test func sourceBoundariesKeepNonLiftRunsSeparate() throws {
        let geometry = try fixtureGeometry([
            GPXSegment(points: [point(0, distance: 0), point(10, distance: 100)]),
            GPXSegment(points: [point(20, distance: 200), point(40, distance: 400)]),
            GPXSegment(points: [point(50, distance: 500), point(60, distance: 600)])
        ])
        let timeline = Geo.timeline(in: geometry, passages: .init(runs: [passage(20, 40)]))

        #expect(timeline.entries.map(\.kind) == [.run, .run, .run])
        #expect(timeline.breaks == [.init(startedAt: 10_000, endedAt: 20_000, reason: .sourceBoundary),
                                   .init(startedAt: 40_000, endedAt: 50_000, reason: .sourceBoundary)])
        expectCoverage(timeline, from: 0, to: 60_000)
    }

    @Test func clipsSavedPassagesAndMeasuresEveryObservedIntervalOnce() throws {
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(10, distance: 100, elevation: 900),
            point(20, distance: 400, elevation: 930), point(30, distance: 500, elevation: nil)
        ]
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let passages = SkiActivityDetector.Result(runs: [.init(startedAt: 2_500, endedAt: 12_500)], lifts: [.init(startedAt: 12_500, endedAt: 25_000)])
        let timeline = Geo.timeline(in: geometry, passages: passages)
        let entries = timeline.entries

        #expect(entries.map(\.kind) == [.run, .lift, .run])
        #expect(entries.map { [$0.startedAt.millisecondsSince1970, $0.endedAt.millisecondsSince1970] } == [[0, 12_500], [12_500, 25_000], [25_000, 30_000]])
        #expect(abs(try #require(entries[0].distanceMeters) - 175) < 0.000001)
        #expect(entries[0].elevationGainMeters == 7.5)
        #expect(entries[0].elevationLossMeters == 100)
        #expect(abs(try #require(entries[1].distanceMeters) - 275) < 0.000001)
        #expect(entries[1].elevationGainMeters == 22.5)
        #expect(entries[1].elevationLossMeters == 0)
        #expect(entries[2].elevationGainMeters == nil)
        #expect(entries[2].elevationLossMeters == nil)
        #expect(entries.allSatisfy { $0.quality?.maximumSampleIntervalMilliseconds == 10_000 })
        #expect(entries.map { $0.quality?.sampleGapHistogram } == [histogram([10: 2]), histogram([10: 2]), histogram([10: 1])])
        #expect(entries.map(\.pointCount) == [3, 3, 2])
        #expect(entries[0].durationMilliseconds == 12_500)
        #expect(entries[0].quality?.level == .fair)
        #expect(timeline.breaks.isEmpty)
        #expect(geometry.sections.first?.points == points)
        expectCoverage(timeline, from: 0, to: 30_000)
    }

    @Test func adjacentNonLiftIntervalsMergeWhileDistinctLiftsKeepTheirIdentity() throws {
        let points = try [point(0, distance: 0), point(10, distance: 100), point(20, distance: 200), point(30, distance: 300)]
        let passages = SkiActivityDetector.Result(runs: [passage(0, 10), passage(10, 20)], lifts: [passage(20, 25), passage(25, 30)])
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let timeline = Geo.timeline(in: geometry, passages: passages)
        let entries = timeline.entries

        #expect(entries.map(\.kind) == [.run, .lift, .lift])
        #expect(entries.map(\.endedAt) == [20_000, 25_000, 30_000])
        #expect(Geo.classifiedSections(in: geometry, passages: passages).count == 2)
        expectCoverage(timeline, from: 0, to: 30_000)
    }

    @Test func sparseIntervalsStayObservedWhileSourceBoundariesMergeAroundIsolatedPoints() throws {
        let geometry = try fixtureGeometry([
            GPXSegment(points: [point(0, distance: 0), point(10, distance: 100), point(50, distance: 500), point(60, distance: 600), point(100, distance: 900)]),
            GPXSegment(points: [point(110, distance: 1_000)]),
            GPXSegment(points: [point(120, distance: 1_100), point(150, distance: 1_400)])
        ])
        let timeline = Geo.timeline(in: geometry, passages: SkiActivityDetector.Result(runs: [passage(0, 150)]))
        let entries = timeline.entries

        #expect(entries.map(\.kind) == [.run, .run])
        #expect(entries.map(\.endedAt) == [100_000, 150_000])
        #expect(entries.map(\.pointCount) == [5, 2])
        #expect(entries.map { $0.quality?.level } == [.low, .low])
        #expect(entries[0].quality?.sampleGapHistogram == histogram([10: 2, 40: 2], binWidthSeconds: 2))
        #expect(timeline.breaks == [ActivityTimelineBreak(startedAt: 100_000, endedAt: 120_000, reason: .sourceBoundary)])
        #expect(timeline.breaks.map(\.durationMilliseconds) == [20_000])
        expectCoverage(timeline, from: 0, to: 150_000)
    }

    @Test func isolatedObservationsOnlyProduceMergedContinuityBreaks() throws {
        let geometry = try fixtureGeometry([
            GPXSegment(points: [point(10, distance: 0)]), GPXSegment(points: [point(20, distance: 100)]),
            GPXSegment(points: [point(40, distance: 200)])
        ])
        let passages = SkiActivityDetector.Result()
        let timeline = Geo.timeline(in: geometry, passages: passages)

        #expect(timeline.entries.isEmpty)
        #expect(timeline.breaks == [ActivityTimelineBreak(startedAt: 10_000, endedAt: 40_000, reason: .sourceBoundary)])
        expectCoverage(timeline, from: 10_000, to: 40_000)
        #expect(Geo.timeline(in: fixtureGeometry([]), passages: passages) == ActivityTimeline())
        #expect(Geo.timeline(in: fixtureGeometry([GPXSegment(points: [try point(10, distance: 0)])]), passages: passages) == ActivityTimeline())
    }

    @Test func aStationaryWindowStaysInOneRunWithoutAddingNoiseToMeasurements() throws {
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(5, distance: 50, elevation: 950),
            point(10, distance: 100, elevation: 900), point(15, distance: 100.8, elevation: 930),
            point(20, distance: 100.2, elevation: 870), point(25, distance: 150.2, elevation: 820),
            point(30, distance: 200.2, elevation: 770)
        ]
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let passages = SkiActivityDetector.Result(runs: [passage(0, 30)])
        let timeline = Geo.timeline(in: geometry, passages: passages)
        let entries = timeline.entries

        #expect(entries.map(\.kind) == [.run])
        #expect(entries.map(\.endedAt) == [30_000])
        #expect(entries.map(\.pointCount) == [7])
        #expect(abs(try #require(entries[0].distanceMeters) - 200) < 0.000001)
        #expect(entries[0].elevationGainMeters == 0)
        #expect(entries[0].elevationLossMeters == 200)
        #expect(entries[0].quality?.level == .good)
        #expect(entries[0].quality?.sampleGapHistogram == histogram([5: 6]))
        let statistics = Geo.skiStatistics(in: geometry, passages: passages)
        #expect(abs(statistics.runDistanceMeters - 200) < 0.000001)
        #expect(statistics.runDurationMilliseconds == 30_000)
        #expect(passages.runCount == 1)
        #expect(Geo.classifiedSections(in: geometry, passages: passages) == [ClassifiedTrackSection(classification: .run, points: points)])
        expectCoverage(timeline, from: 0, to: 30_000)
    }

    @Test func aStopBeforeALiftStaysInTheRunWithoutChangingQualityOrPointCounts() throws {
        let points = try [point(0, distance: 0), point(5, distance: 50), point(10, distance: 50), point(20, distance: 50), point(25, distance: 100)]
        let passages = SkiActivityDetector.Result(runs: [passage(0, 20)], lifts: [passage(20, 25)])
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let timeline = Geo.timeline(in: geometry, passages: passages)
        let entries = timeline.entries

        #expect(entries.map(\.kind) == [.run, .lift])
        #expect(entries.map(\.endedAt) == [20_000, 25_000])
        #expect(entries.map(\.pointCount) == [4, 2])
        #expect(entries[0].quality?.sampleGapHistogram == histogram([5: 2, 10: 1]))
        #expect(entries[0].quality?.level == .fair)
        #expect(Geo.classifiedSections(in: geometry, passages: passages).map(\.classification) == [.run, .lift])
        #expect(Geo.skiStatistics(in: geometry, passages: passages).runDurationMilliseconds == 20_000)
        expectCoverage(timeline, from: 0, to: 25_000)
    }

    @Test func aStopBetweenMatchingLiftMovementStaysInTheLift() throws {
        let points = try [point(0, distance: 0), point(5, distance: 50), point(10, distance: 50), point(20, distance: 50), point(25, distance: 100)]
        let lifts = Geo.liftsWithInternalStops([passage(0, 5), passage(20, 25)], stops: Geo.stationarySpans(in: points))
        let timeline = Geo.timeline(in: fixtureGeometry([GPXSegment(points: points)]), passages: .init(lifts: lifts))

        #expect(lifts == [passage(0, 25)])
        #expect(timeline.entries.map(\.kind) == [.lift])
        #expect(timeline.entries.first?.pointCount == 5)
        expectCoverage(timeline, from: 0, to: 25_000)
    }

    @Test func shortStopsAndSlowWalkingStayWithinMovement() throws {
        let shortStop = try [point(0, distance: 0), point(5, distance: 0.5), point(10, distance: 50.5)]
        let shortEntries = Geo.timeline(in: fixtureGeometry([GPXSegment(points: shortStop)]), passages: SkiActivityDetector.Result()).entries
        #expect(shortEntries.map(\.kind) == [.run])
        #expect(abs(try #require(shortEntries[0].distanceMeters) - 50.5) < 0.000001)
        #expect(shortEntries[0].elevationGainMeters == 0)
        #expect(shortEntries[0].elevationLossMeters == 0)

        let walking = try (0...5).map { try point($0 * 5, distance: Double($0) * 2) }
        let walkingEntries = Geo.timeline(in: fixtureGeometry([GPXSegment(points: walking)]), passages: SkiActivityDetector.Result()).entries
        #expect(walkingEntries.map(\.kind) == [.run])
        #expect(abs(try #require(walkingEntries[0].distanceMeters) - 10) < 0.000001)

        let nearby = try [point(0, distance: 0), point(10, distance: 4.8)]
        let nearbyEntries = Geo.timeline(in: fixtureGeometry([GPXSegment(points: nearby)]), passages: SkiActivityDetector.Result()).entries
        #expect(nearbyEntries.map(\.kind) == [.run])
    }

    @Test(arguments: [true, false]) func stationaryCandidatesRespectOnlySourceBoundaries(sourceBoundary: Bool) throws {
        let first = try [point(0, distance: 0), point(5, distance: 0)]
        let second = try [point(sourceBoundary ? 10 : 40, distance: 0), point(sourceBoundary ? 15 : 45, distance: 0)]
        let segments = sourceBoundary ? [GPXSegment(points: first), GPXSegment(points: second)] : [GPXSegment(points: first + second)]
        let timeline = Geo.timeline(in: fixtureGeometry(segments), passages: SkiActivityDetector.Result())

        if sourceBoundary {
            #expect(timeline.entries.map(\.kind) == [.run, .run])
            #expect(timeline.breaks == [ActivityTimelineBreak(startedAt: 5_000, endedAt: 10_000, reason: .sourceBoundary)])
        } else {
            #expect(timeline.entries.map(\.kind) == [.run])
            #expect(timeline.entries.first?.durationMilliseconds == 45_000)
            #expect(timeline.entries.first?.pointCount == 4)
            #expect(timeline.breaks.isEmpty)
        }
        expectCoverage(timeline, from: 0, to: sourceBoundary ? 15_000 : 45_000)
    }

    @Test(arguments: [4.99999, 5, 5.00001]) func stationarySpeedAndRadiusIncludeTheirExactThreshold(distance: Double) throws {
        let speedBoundary = try [point(0, distance: 0), point(10, distance: distance)]
        let radiusBoundary = try [point(0, distance: 0), point(10, distance: distance / 2), point(20, distance: distance)]
        for points in [speedBoundary, radiusBoundary] {
            let spans = Geo.stationarySpans(in: points)
            #expect(spans.count == (distance <= 5 ? 1 : 0))
            if let span = spans.first {
                #expect(span.startedAt == points.first?.recordedAt)
                #expect(span.endedAt == points.last?.recordedAt)
            }
        }
    }

    @Test func missingAltitudeAndRejectedDistancesKeepTheirObservedTimeAndKind() throws {
        let points = try [
            point(0, distance: 0, elevation: 1_000), point(10, distance: 100, elevation: nil),
            point(20, distance: 200, elevation: nil), point(30, distance: 300, elevation: 900),
            point(40, distance: 800, elevation: 800), point(50, distance: 900, elevation: 800)
        ]
        let timeline = Geo.timeline(in: fixtureGeometry([GPXSegment(points: points)]), passages: SkiActivityDetector.Result(runs: [passage(0, 50)]))
        let entries = timeline.entries
        #expect(entries.map(\.kind) == [.run])
        #expect(abs(try #require(entries[0].distanceMeters) - 400) < 0.000001)
        #expect(entries[0].elevationGainMeters == 0)
        #expect(entries[0].elevationLossMeters == 100)
        #expect(entries[0].quality?.level == .fair)
        expectCoverage(timeline, from: 0, to: 50_000)

        let outlier = try [point(0, distance: 0, elevation: 1_000), point(10, distance: 500, elevation: 950)]
        let outlierEntry = try #require(Geo.timeline(in: fixtureGeometry([GPXSegment(points: outlier)]), passages: SkiActivityDetector.Result()).entries.first)
        #expect(outlierEntry.kind == .run)
        #expect(outlierEntry.distanceMeters == 0)
        #expect(outlierEntry.elevationLossMeters == 50)
        #expect(outlierEntry.quality?.level == entries[0].quality?.level)
        #expect(outlierEntry.quality?.sampleGapHistogram == histogram([10: 1]))
        #expect(entries[0].quality?.sampleGapHistogram == histogram([10: 5]))

        let missing = try [point(0, distance: 0, elevation: nil), point(10, distance: 100, elevation: nil)]
        let missingEntry = try #require(Geo.timeline(in: fixtureGeometry([GPXSegment(points: missing)]), passages: SkiActivityDetector.Result()).entries.first)
        #expect(missingEntry.elevationGainMeters == nil)
        #expect(missingEntry.elevationLossMeters == nil)
        #expect(missingEntry.quality == outlierEntry.quality)
    }

    @Test func nonpositiveTimestampsCannotCreateZeroLengthOrOverlappingEntries() throws {
        let points = try [point(0, distance: 0), point(10, distance: 100), point(10, distance: 100), point(5, distance: 50), point(15, distance: 150)]
        let geometry = TrackGeometry(activityID: "repeated-time", sourceRevision: 1,
                                     sections: [TrackSection(sourceSegmentID: "source", breakBefore: nil, points: points)])
        let timeline = Geo.timeline(in: geometry, passages: SkiActivityDetector.Result())

        expectCoverage(timeline, from: 0, to: 15_000)
        #expect(abs(timeline.entries.compactMap(\.distanceMeters).reduce(0, +) - 150) < 0.000001)
    }

    @Test func uniformCadenceKeepsItsExpectedQualityLevel() throws {
        let cases: [(Int64, ActivityQualityLevel)] = [(1_000, .excellent), (2_000, .excellent),
                                                      (5_000, .good), (15_000, .fair), (20_000, .low)]
        for (interval, expected) in cases {
            let timeline = Geo.timeline(in: try samplingGeometry(Array(repeating: interval, count: 10)), passages: SkiActivityDetector.Result())
            let quality = try #require(timeline.entries.first?.quality)
            #expect(quality.level == expected)
            #expect(quality.maximumSampleIntervalMilliseconds == interval)
        }
    }

    @Test func qualityUsesInclusiveCoverageThresholds() throws {
        let cases: [([Int64], ActivityQualityLevel)] = [
            (Array(repeating: 1_000, count: 160) + [20_000], .excellent),
            (Array(repeating: 1_000, count: 159) + [20_000], .good),
            (Array(repeating: 5_000, count: 16) + [20_000], .good),
            (Array(repeating: 5_000, count: 15) + [20_000], .fair),
            (Array(repeating: 15_000, count: 3) + [30_000], .fair),
            (Array(repeating: 15_000, count: 2) + [30_000], .low)
        ]
        for (intervals, expected) in cases {
            let timeline = Geo.timeline(in: try samplingGeometry(intervals), passages: SkiActivityDetector.Result())
            #expect(timeline.entries.first?.quality?.level == expected)
        }
    }

    @Test func isolatedSparseSamplingAndNominalCadenceJitterDoNotDominateTheRating() throws {
        let isolated = Array(repeating: Int64(1_000), count: 299) + [20_000]
        let repeated = Array(repeating: Int64(1_000), count: 299) + Array(repeating: 20_000, count: 8)
        let short = Array(repeating: Int64(1_000), count: 5) + [30_000]
        let jitter = Array(repeating: [Int64(1_900), Int64(2_100)], count: 20).flatMap { $0 }
        let cases: [([Int64], ActivityQualityLevel)] = [(isolated, .excellent), (repeated, .fair), (short, .low), (jitter, .excellent)]
        for (intervals, expected) in cases {
            let timeline = Geo.timeline(in: try samplingGeometry(intervals), passages: SkiActivityDetector.Result())
            #expect(timeline.entries.first?.quality?.level == expected)
        }
    }

    @Test func qualityWeightsOnlyThePartOfAnOriginalPairInsideEachEntry() throws {
        let geometry = try samplingGeometry(Array(repeating: 1_000, count: 20) + [20_000])
        let timeline = Geo.timeline(in: geometry, passages: SkiActivityDetector.Result(runs: [passage(0, 21)], lifts: [passage(21, 40)]))

        #expect(timeline.entries.map(\.kind) == [.run, .lift])
        #expect(timeline.entries.map { $0.quality?.level } == [.excellent, .low])
        #expect(timeline.entries.map { $0.quality?.maximumSampleIntervalMilliseconds } == [20_000, 20_000])
        #expect(timeline.entries.map { $0.quality?.sampleGapHistogram } == [histogram([1: 20, 20: 1]), histogram([20: 1])])
        expectCoverage(timeline, from: 0, to: 40_000)

        let singlePair = Geo.timeline(in: try samplingGeometry([20_000]), passages: SkiActivityDetector.Result(runs: [passage(0, 1)], lifts: [passage(1, 20)]))
        #expect(singlePair.entries.map(\.durationMilliseconds) == [1_000, 19_000])
        #expect(singlePair.entries.map { $0.quality?.level } == [.low, .low])
        #expect(singlePair.entries.allSatisfy { $0.quality?.sampleGapHistogram == histogram([20: 1]) })
    }

    @Test func sampleGapHistogramUsesRightClosedOneSecondBins() throws {
        let timestamps: [Int64] = [0, 1, 1_001, 2_002, 32_002]
        let points = try timestamps.map { milliseconds in
            try TrackPoint(timestampMilliseconds: milliseconds, latitude: 0,
                           longitude: Double(milliseconds) * 0.01 * 180 / (.pi * 6_371_000), elevationMeters: 1_000)
        }
        let timeline = Geo.timeline(in: fixtureGeometry([GPXSegment(points: points)]), passages: SkiActivityDetector.Result())
        let entry = try #require(timeline.entries.first)
        let distribution = try #require(entry.quality?.sampleGapHistogram)

        #expect(timeline.entries.count == 1)
        #expect(timeline.breaks.isEmpty)
        #expect(distribution == histogram([1: 2, 2: 1, 30: 1]))
        #expect(distribution.counts.reduce(0, +) == 4)
        #expect(entry.pointCount == 5)
        #expect(entry.quality?.maximumSampleIntervalMilliseconds == 30_000)
        expectCoverage(timeline, from: 0, to: 32_002)
    }

    @Test func histogramWidensWithNiceIntervalsAndKeepsLongStationaryPeriods() throws {
        let cases: [(Int64, Int64, Int)] = [(30_000, 1_000, 29), (30_001, 2_000, 15),
                                            (60_000, 2_000, 29), (60_001, 5_000, 12),
                                            (150_000, 5_000, 29), (150_001, 10_000, 15),
                                            (3_600_000, 200_000, 17), (7_200_000, 500_000, 14)]
        for (duration, width, expectedBin) in cases {
            let points = try [point(0, distance: 0), TrackPoint(timestampMilliseconds: duration, latitude: 0, longitude: 0, elevationMeters: 1_000)]
            let timeline = Geo.timeline(in: fixtureGeometry([GPXSegment(points: points)]), passages: SkiActivityDetector.Result())
            let entry = try #require(timeline.entries.first)
            let distribution = try #require(entry.quality?.sampleGapHistogram)

            #expect(timeline.entries.count == 1)
            #expect(timeline.breaks.isEmpty)
            #expect(entry.kind == .run)
            #expect(entry.durationMilliseconds == duration)
            #expect(entry.pointCount == 2)
            #expect(entry.distanceMeters == 0)
            #expect(entry.quality?.level == .low)
            #expect(distribution.binWidthMilliseconds == width)
            #expect(distribution.counts.count == 30)
            #expect(distribution.counts.reduce(0, +) == 1)
            #expect(distribution.counts[expectedBin] == 1)
        }

        let mixed = Geo.timeline(in: try samplingGeometry([1, 2_000, 2_001, 60_000]), passages: SkiActivityDetector.Result())
        #expect(mixed.entries.first?.quality?.sampleGapHistogram == histogram([2: 2, 4: 1, 60: 1], binWidthSeconds: 2))
        expectCoverage(mixed, from: 0, to: 64_002)
    }

    @Test func longOriginalIntervalsAreMeasuredAndClippedWithoutSamplingBreaks() throws {
        let timeline = Geo.timeline(in: try samplingGeometry([60_000]), passages: SkiActivityDetector.Result(lifts: [passage(10, 20)]))

        #expect(timeline.entries.map(\.kind) == [.run, .lift, .run])
        #expect(timeline.entries.map(\.durationMilliseconds) == [10_000, 10_000, 40_000])
        #expect(timeline.entries.allSatisfy { $0.quality?.level == .low && $0.pointCount == 2 })
        #expect(timeline.entries.allSatisfy { $0.quality?.sampleGapHistogram == histogram([60: 1], binWidthSeconds: 2) })
        let distances = timeline.entries.compactMap(\.distanceMeters)
        #expect(distances.count == 3)
        #expect(abs(distances[0] - 100) < 0.000001)
        #expect(abs(distances[1] - 100) < 0.000001)
        #expect(abs(distances[2] - 400) < 0.000001)
        #expect(timeline.breaks.isEmpty)
        expectCoverage(timeline, from: 0, to: 60_000)
    }

    @Test func stationaryRunHistogramCountsEveryOriginalPairOnce() throws {
        let points = try [point(0, distance: 0), point(5, distance: 0), point(65, distance: 0)]
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let passages = SkiActivityDetector.analyze(geometry)
        let timeline = Geo.timeline(in: geometry, passages: passages)

        #expect(passages.runCount == 1)
        #expect(passages.liftCount == 0)
        #expect(timeline.entries.map(\.kind) == [.run])
        #expect(timeline.entries.first?.durationMilliseconds == 65_000)
        #expect(timeline.entries.first?.pointCount == 3)
        #expect(timeline.entries.first?.distanceMeters == 0)
        #expect(timeline.entries.first?.quality?.sampleGapHistogram == histogram([6: 1, 60: 1], binWidthSeconds: 2))
        expectCoverage(timeline, from: 0, to: 65_000)
    }

    @Test func samplingCoverageAndHistogramResetAcrossSourceBoundaries() throws {
        let points = try [point(0, distance: 0), point(1, distance: 10), point(3, distance: 30),
                          point(8, distance: 80), point(28, distance: 280), point(68, distance: 680),
                          point(69, distance: 690), point(70, distance: 700)]
        let timeline = Geo.timeline(in: fixtureGeometry([GPXSegment(points: Array(points.prefix(5))), GPXSegment(points: Array(points.suffix(3)))]), passages: SkiActivityDetector.Result(runs: [passage(0, 70)]))

        #expect(timeline.entries.map(\.kind) == [.run, .run])
        #expect(timeline.entries.map { $0.quality?.maximumSampleIntervalMilliseconds } == [20_000, 1_000])
        #expect(timeline.entries.map { $0.quality?.level } == [.fair, .excellent])
        #expect(timeline.entries.map(\.durationMilliseconds) == [28_000, 2_000])
        #expect(timeline.entries.map(\.pointCount) == [5, 3])
        #expect(timeline.entries[0].quality?.sampleGapHistogram == histogram([1: 1, 2: 1, 5: 1, 20: 1]))
        #expect(timeline.entries[1].quality?.sampleGapHistogram == histogram([1: 2]))
        #expect(timeline.breaks == [ActivityTimelineBreak(startedAt: 28_000, endedAt: 68_000, reason: .sourceBoundary)])
        expectCoverage(timeline, from: 0, to: 70_000)
    }

    @Test func sparseIntervalsAtTheStartAndEndRemainMeasured() throws {
        let points = try [point(0, distance: 0, elevation: 1_000), point(40, distance: 400, elevation: 900), point(80, distance: 800, elevation: 1_000),
                          point(81, distance: 810, elevation: 800), point(121, distance: 1_210, elevation: 700), point(161, distance: 1_610, elevation: 600)]
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let timeline = Geo.timeline(in: geometry, passages: SkiActivityDetector.Result())

        #expect(timeline.entries.map(\.kind) == [.run])
        let entry = try #require(timeline.entries.first)
        #expect(entry.quality?.level == .low)
        #expect(entry.durationMilliseconds == 161_000)
        #expect(entry.pointCount == 6)
        #expect(abs(try #require(entry.distanceMeters) - 1_610) < 0.000001)
        #expect(entry.elevationGainMeters == 100)
        #expect(entry.elevationLossMeters == 500)
        #expect(entry.quality?.sampleGapHistogram == histogram([2: 1, 40: 4], binWidthSeconds: 2))
        #expect(timeline.breaks.isEmpty)
        expectCoverage(timeline, from: 0, to: 161_000)

        let unsplit = TrackGeometry(activityID: geometry.activityID, sourceRevision: geometry.sourceRevision,
                                    sections: [TrackSection(sourceSegmentID: "source", breakBefore: nil, points: points)])
        #expect(Geo.timeline(in: unsplit, passages: SkiActivityDetector.Result()) == timeline)
    }

    @Test func supportingSamplesAndHistogramExcludeSourceBoundaryIntervals() throws {
        let geometry = try fixtureGeometry([
            GPXSegment(points: [point(0, distance: 0), point(1, distance: 10), point(3, distance: 30)]),
            GPXSegment(points: [point(23, distance: 230), point(28, distance: 280), point(43, distance: 430)])
        ])
        let timeline = Geo.timeline(in: geometry, passages: SkiActivityDetector.Result(runs: [passage(0, 43)]))

        #expect(timeline.entries.map(\.pointCount) == [3, 3])
        #expect(timeline.entries.map { $0.quality?.maximumSampleIntervalMilliseconds } == [2_000, 15_000])
        #expect(timeline.entries.map { $0.quality?.sampleGapHistogram } == [histogram([1: 1, 2: 1]), histogram([5: 1, 15: 1])])
        #expect(timeline.breaks == [ActivityTimelineBreak(startedAt: 3_000, endedAt: 23_000, reason: .sourceBoundary)])
        expectCoverage(timeline, from: 0, to: 43_000)
    }

    @Test func codingPreservesActivityAndContinuityWithExactDurationsAndQuality() throws {
        let entries = ActivityTimelineKind.allCases.enumerated().map { index, kind in
            ActivityTimelineEntry(kind: kind, startedAt: Timestamp(millisecondsSince1970: Int64(index) * 2_345 + 1_234),
                                  endedAt: Timestamp(millisecondsSince1970: Int64(index + 1) * 2_345 + 1_234),
                                  distanceMeters: 12.5,
                                  elevationGainMeters: 0,
                                  elevationLossMeters: nil,
                                  quality: ActivityTimelineQuality(level: ActivityQualityLevel.allCases[index % ActivityQualityLevel.allCases.count], maximumSampleIntervalMilliseconds: Int64(index + 1) * 1_000,
                                                                   sampleGapHistogram: histogram([index + 1: index + 1])),
                                  pointCount: index + 2)
        }
        let breaks = [ActivityTimelineBreak(startedAt: 20_123, endedAt: 60_456, reason: .sourceBoundary)]
        let timeline = ActivityTimeline(entries: entries, breaks: breaks)
        let encoded = try JSONEncoder().encode(timeline)
        let decoded = try JSONDecoder().decode(ActivityTimeline.self, from: encoded)
        #expect(decoded == timeline)
        #expect(decoded.entries.allSatisfy { $0.durationMilliseconds == 2_345 })
        #expect(decoded.breaks.first?.durationMilliseconds == 40_333)
        #expect(ActivityTimelineKind(rawValue: "gap") == nil)
        #expect(ActivityTimelineKind(rawValue: "pause") == nil)

        let legacyEntry = ActivityTimelineEntry(kind: .run, startedAt: 0, endedAt: 1_000,
                                                distanceMeters: 12, elevationGainMeters: nil, elevationLossMeters: nil)
        let legacyData = try JSONEncoder().encode(legacyEntry)
        let decodedLegacy = try JSONDecoder().decode(ActivityTimelineEntry.self, from: legacyData)
        #expect(decodedLegacy.quality == nil)
        #expect(decodedLegacy.pointCount == nil)
        let legacyQuality = ActivityTimelineQuality(level: .good, maximumSampleIntervalMilliseconds: 5_000)
        let qualityData = try JSONEncoder().encode(legacyQuality)
        #expect(try JSONDecoder().decode(ActivityTimelineQuality.self, from: qualityData).sampleGapHistogram == nil)
    }

    private func expectCoverage(_ timeline: ActivityTimeline, from start: Timestamp, to end: Timestamp) {
        let intervals = (timeline.entries.map { ($0.startedAt, $0.endedAt) } + timeline.breaks.map { ($0.startedAt, $0.endedAt) }).sorted { $0.0 < $1.0 }
        #expect(intervals.first?.0 == start)
        #expect(intervals.last?.1 == end)
        #expect(intervals.allSatisfy { $0.0 < $0.1 })
        #expect(timeline.entries.allSatisfy { $0.quality != nil })
        #expect(timeline.entries.allSatisfy { ($0.pointCount ?? 0) >= 2 && $0.quality?.sampleGapHistogram != nil })
        for entry in timeline.entries {
            #expect(entry.quality?.sampleGapHistogram?.counts.reduce(0, +) == (entry.pointCount ?? 0) - 1)
        }
        for (left, right) in zip(intervals, intervals.dropFirst()) { #expect(left.1 == right.0) }
    }

    private func histogram(_ countsByUpperSecond: [Int: Int], binWidthSeconds: Int = 1) -> SampleGapHistogram {
        var counts = Array(repeating: 0, count: 30)
        for (upperSecond, count) in countsByUpperSecond { counts[upperSecond / binWidthSeconds - 1] = count }
        return SampleGapHistogram(binWidthMilliseconds: Int64(binWidthSeconds) * 1_000, counts: counts)
    }

    private func samplingGeometry(_ intervals: [Int64]) throws -> TrackGeometry {
        var milliseconds: Int64 = 0
        var points = [try point(0, distance: 0)]
        for interval in intervals {
            milliseconds += interval
            points.append(try TrackPoint(timestampMilliseconds: milliseconds, latitude: 0,
                                          longitude: Double(milliseconds) * 0.01 * 180 / (.pi * 6_371_000), elevationMeters: 1_000))
        }
        return fixtureGeometry([GPXSegment(points: points)])
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
