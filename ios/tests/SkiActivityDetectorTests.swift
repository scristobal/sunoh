import Foundation
import Testing
@testable import Sunoh

struct SkiActivityDetectorTests {
    @Test(arguments: [Int64(1), 9_999, 10_001, 21_234, 90_000]) func evenBriefTwoPointIntervalsUseTheExactOriginalBounds(duration: Int64) throws {
        let start: Int64 = 1_234
        let points = try [start, start + duration].map {
            try TrackPoint(timestampMilliseconds: $0, latitude: 0, longitude: 0, elevationMeters: nil)
        }
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let passages = SkiActivityDetector.analyze(geometry)
        let expected = SkiActivityDetector.Passage(startedAt: Timestamp(millisecondsSince1970: start),
                                                  endedAt: Timestamp(millisecondsSince1970: start + duration))

        #expect(passages.runs == [expected])
        #expect(passages.lifts.isEmpty)
        #expect(Geo.timeline(in: geometry, passages: passages).entries.map(\.durationMilliseconds) == [duration])
        #expect(Geo.classifiedSections(in: geometry, passages: passages) == [.init(classification: .run, points: points)])
    }

    @Test func emptyAndSingletonSourceSpansProduceNoPassages() throws {
        let point = try TrackPoint(timestampMilliseconds: 0, latitude: 0, longitude: 0, elevationMeters: nil)
        let later = try TrackPoint(timestampMilliseconds: 10_000, latitude: 0, longitude: 0, elevationMeters: nil)
        for segments in [[], [GPXSegment(points: [point])], [GPXSegment(points: [point]), GPXSegment(points: [later])]] {
            let geometry = fixtureGeometry(segments)
            let passages = SkiActivityDetector.analyze(geometry)
            #expect(passages == SkiActivityDetector.Result())
            #expect(Geo.classifiedSections(in: geometry, passages: passages).isEmpty)
        }
    }

    @Test func invalidTimestampIntervalsSeparateTheComplementaryRuns() throws {
        let points = try [0, 5_000, 5_000, 4_000, 10_000].map {
            try TrackPoint(timestampMilliseconds: Int64($0), latitude: 0, longitude: 0, elevationMeters: nil)
        }
        let geometry = TrackGeometry(activityID: "timestamps", sourceRevision: 1,
                                     sections: [.init(sourceSegmentID: "source", breakBefore: nil, points: points)])
        let passages = SkiActivityDetector.analyze(geometry)

        #expect(passages.runs == [.init(startedAt: 0, endedAt: 5_000), .init(startedAt: 4_000, endedAt: 10_000)])
        #expect(passages.lifts.isEmpty)
        #expect(Geo.classifiedSections(in: geometry, passages: passages).count == 2)
        #expect(geometry.sections.first?.points == points)
    }

    @Test(arguments: [true, false]) func countsADownhillAtEitherEndOfTheSession(downhillFirst: Bool) {
        var track = SyntheticTrack()
        if downhillFirst { track.travel(seconds: 120, speed: 8, climbRate: -1) }
        track.travel(seconds: 120, speed: 3, climbRate: 1)
        if !downhillFirst { track.travel(seconds: 120, speed: 8, climbRate: -1) }

        let result = SkiActivityDetector.analyze(fixtureGeometry([track.segment]))
        #expect(result.runCount == 1)
        #expect(result.liftCount == 1)
        if let run = result.runs.first, let lift = result.lifts.first {
            #expect(downhillFirst ? run.endedAt <= lift.startedAt : run.startedAt >= lift.endedAt)
        }
    }

    @Test func successiveLiftsSeparateRunsIncludingTheFirstAndLastDescent() {
        var track = SyntheticTrack()
        track.travel(seconds: 120, speed: 8, climbRate: -1)
        track.travel(seconds: 120, speed: 3, climbRate: 1)
        track.travel(seconds: 120, speed: 8, climbRate: -1)
        track.travel(seconds: 120, speed: 3, climbRate: 1)
        track.travel(seconds: 120, speed: 8, climbRate: -1)

        let result = SkiActivityDetector.analyze(fixtureGeometry([track.segment]))
        #expect(result.runCount == 3)
        #expect(result.liftCount == 2)
    }

    @Test func stopsAndShortUphillSectionsStayWithinOneRun() {
        var track = SyntheticTrack()
        track.travel(seconds: 90, speed: 7, climbRate: -1)
        track.travel(seconds: 180, speed: 0, climbRate: 0)
        track.travel(seconds: 20, speed: 2, climbRate: 0.5)
        track.travel(seconds: 90, speed: 7, climbRate: -1)

        let result = SkiActivityDetector.analyze(fixtureGeometry([track.segment]))
        #expect(result.runCount == 1)
        #expect(result.liftCount == 0)
        #expect(result.runs.first?.startedAt == track.points.first?.recordedAt)
        #expect(result.runs.first?.endedAt == track.points.last?.recordedAt)
    }

    @Test(arguments: [0.0, 0.1]) func traversesAndUphillRipplesStayInTheNonLiftRun(climbRate: Double) {
        var track = SyntheticTrack()
        for _ in 0..<10 {
            track.travel(seconds: 10, speed: 8, climbRate: -1.5)
            track.travel(seconds: 10, speed: 8, climbRate: climbRate)
        }
        let geometry = fixtureGeometry([track.segment])
        let result = SkiActivityDetector.analyze(geometry)

        #expect(result.runs == [.init(startedAt: 0, endedAt: 200_000)])
        #expect(result.liftCount == 0)
        #expect(Geo.timeline(in: geometry, passages: result).entries.map(\.kind) == [.run])
    }

    @Test func approachesQueuesAndTerminalWaitsBelongToComplementaryRuns() {
        var track = SyntheticTrack()
        track.travel(seconds: 20, speed: 0, climbRate: 0)
        track.travel(seconds: 20, speed: 2, climbRate: 0)
        track.travel(seconds: 60, speed: 8, climbRate: -1)
        track.travel(seconds: 20, speed: 8, climbRate: 0)
        track.travel(seconds: 10, speed: 8, climbRate: -1.5)
        track.travel(seconds: 20, speed: 0, climbRate: 0)
        track.travel(seconds: 30, speed: 2, climbRate: 0)
        track.travel(seconds: 120, speed: 3, climbRate: 1)
        track.travel(seconds: 60, speed: 0, climbRate: 0)
        let geometry = fixtureGeometry([track.segment])
        let result = SkiActivityDetector.analyze(geometry)
        let timeline = Geo.timeline(in: geometry, passages: result)

        #expect(result.runs == [.init(startedAt: 0, endedAt: 180_000), .init(startedAt: 300_000, endedAt: 360_000)])
        #expect(result.lifts == [.init(startedAt: 180_000, endedAt: 300_000)])
        #expect(timeline.entries.map(\.kind) == [.run, .lift, .run])
        #expect(timeline.entries.map(\.endedAt) == [180_000, 300_000, 360_000])
        #expect(Geo.classifiedSections(in: geometry, passages: result).map(\.classification) == [.run, .lift, .run])
        #expect(track.points == geometry.sections.first?.points)
    }

    @Test func smoothingPreservesTheLastSupportedLiftInterval() {
        var track = SyntheticTrack()
        track.travel(seconds: 180, speed: 3, climbRate: 250.0 / 180)
        track.travel(seconds: 120, speed: 7.5, climbRate: -250.0 / 120)
        let geometry = fixtureGeometry([track.segment])
        let result = SkiActivityDetector.analyze(geometry)

        #expect(result.lifts == [.init(startedAt: 0, endedAt: 180_000)])
        #expect(result.runs == [.init(startedAt: 180_000, endedAt: 300_000)])
        #expect(Geo.timeline(in: geometry, passages: result).entries.map(\.kind) == [.lift, .run])
        #expect(abs((Geo.timeline(in: geometry, passages: result).entries.first { $0.kind == .lift }?.elevationGainMeters ?? 0) - 250) < 0.000001)
    }

    @Test(arguments: [60, 180, 600]) func aLiftThatTemporarilyStopsRemainsOneLift(stopSeconds: Int) {
        var track = SyntheticTrack()
        track.travel(seconds: 120, speed: 3, climbRate: 0.8)
        track.travel(seconds: stopSeconds, speed: 0, climbRate: 0)
        track.travel(seconds: 120, speed: 3, climbRate: 0.8)
        track.travel(seconds: 120, speed: 8, climbRate: -1)

        let geometry = fixtureGeometry([track.segment])
        let result = SkiActivityDetector.analyze(geometry)
        #expect(result.runCount == 1)
        #expect(result.liftCount == 1)
        if let lift = result.lifts.first {
            #expect(lift.startedAt < 120_000)
            #expect(lift.endedAt.millisecondsSince1970 > Int64(120 + stopSeconds) * 1_000)
        }
        #expect(Geo.timeline(in: geometry, passages: result).entries.map(\.kind) == [.lift, .run])
        #expect(Geo.classifiedSections(in: geometry, passages: result).map(\.classification) == [.lift, .run])
        #expect(Geo.timeline(in: geometry, passages: result).entries.first { $0.kind == .lift }?.durationMilliseconds == Int64(240 + stopSeconds) * 1_000)
    }

    @Test(arguments: [true, false]) func stopsBetweenRunAndLiftBelongToTheRun(downhillFirst: Bool) {
        var track = SyntheticTrack()
        track.travel(seconds: 120, speed: downhillFirst ? 8 : 3, climbRate: downhillFirst ? -1 : 1)
        track.travel(seconds: 180, speed: 0, climbRate: 0)
        track.travel(seconds: 120, speed: downhillFirst ? 3 : 8, climbRate: downhillFirst ? 1 : -1)
        let geometry = fixtureGeometry([track.segment])
        let result = SkiActivityDetector.analyze(geometry)

        #expect(result.runCount == 1)
        #expect(result.liftCount == 1)
        #expect(result.lifts.first == .init(startedAt: downhillFirst ? 300_000 : 0, endedAt: downhillFirst ? 420_000 : 120_000))
        #expect(Geo.timeline(in: geometry, passages: result).entries.count == 2)
        #expect(Geo.timeline(in: geometry, passages: result).entries.first { $0.kind == .lift }?.durationMilliseconds == 120_000)
    }

    @Test func aStationarySessionIsOneRunWithAllItsOriginalPoints() {
        var track = SyntheticTrack()
        track.travel(seconds: 180, speed: 0, climbRate: 0)
        let geometry = fixtureGeometry([track.segment])
        let passages = SkiActivityDetector.analyze(geometry)
        let timeline = Geo.timeline(in: geometry, passages: passages)

        #expect(passages.runCount == 1)
        #expect(passages.liftCount == 0)
        #expect(timeline.entries.map(\.kind) == [.run])
        #expect(timeline.entries.first?.pointCount == track.points.count)
        #expect(timeline.entries.first?.durationMilliseconds == 180_000)
        #expect(timeline.entries.first?.distanceMeters == 0)
    }

    @Test func stopsDoNotMergeLiftsAcrossExplicitSourceBoundaries() {
        var first = SyntheticTrack()
        first.travel(seconds: 120, speed: 3, climbRate: 1)
        first.travel(seconds: 60, speed: 0, climbRate: 0)
        var second = SyntheticTrack(startSeconds: 180)
        second.travel(seconds: 60, speed: 0, climbRate: 0)
        second.travel(seconds: 120, speed: 3, climbRate: 1)
        let geometry = fixtureGeometry([first.segment, second.segment])
        let passages = SkiActivityDetector.analyze(geometry)

        #expect(passages.runCount == 2)
        #expect(passages.liftCount == 2)
        #expect(passages.lifts.map(\.endedAt) == [120_000, 360_000])
        #expect(Geo.timeline(in: geometry, passages: passages).entries.map(\.kind) == [.lift, .run, .run, .lift])
    }

    @Test func stationaryCandidatesCannotBridgeTimestampReversals() throws {
        let points = try [0, 5, 0, 5].map {
            try TrackPoint(timestampMilliseconds: Int64($0) * 1_000, latitude: 0, longitude: 0, elevationMeters: 1_000)
        }
        #expect(Geo.stationarySpans(in: points).isEmpty)
    }

    @Test func stationaryCoordinateAndElevationNoiseDoesNotCreateLifts() throws {
        let points = try (0...120).map { index in
            try TrackPoint(timestampMilliseconds: Int64(index * 5_000), latitude: 0,
                           longitude: sin(Double(index)) * 2 / SyntheticTrack.metersPerDegree,
                           elevationMeters: 1_000 + cos(Double(index)) * 2)
        }
        let result = SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: points)]))
        #expect(result.runCount == 1)
        #expect(result.liftCount == 0)
    }

    @Test func slowUphillClimbingDoesNotCountAsALift() {
        var track = SyntheticTrack()
        track.travel(seconds: 300, speed: 0.5, climbRate: 0.3)

        let result = SkiActivityDetector.analyze(fixtureGeometry([track.segment]))
        #expect(result.runCount == 1)
        #expect(result.liftCount == 0)
    }

    @Test func stronglyVariableUphillSpeedDoesNotCountAsALift() {
        var track = SyntheticTrack()
        for index in 0..<24 {
            track.travel(seconds: 10, speed: index.isMultiple(of: 2) ? 2 : 9, climbRate: 0.6)
        }

        let result = SkiActivityDetector.analyze(fixtureGeometry([track.segment]))
        #expect(result.runCount == 1)
        #expect(result.liftCount == 0)
    }

    @Test func missingElevationStaysOneRunWithoutInventingLifts() throws {
        var track = SyntheticTrack()
        track.travel(seconds: 120, speed: 3, climbRate: 1)
        track.travel(seconds: 120, speed: 8, climbRate: -1)
        let points = try track.points.map {
            try TrackPoint(recordedAt: $0.recordedAt, coordinate: $0.coordinate, elevationMeters: nil)
        }

        let result = SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: points)]))
        #expect(result.runCount == 1)
        #expect(result.liftCount == 0)
    }

    @Test func oneMissingElevationSampleDoesNotSplitALift() throws {
        var track = SyntheticTrack()
        track.travel(seconds: 400, speed: 3, climbRate: 1)
        let points = try track.points.map {
            try TrackPoint(recordedAt: $0.recordedAt, coordinate: $0.coordinate,
                           elevationMeters: $0.timestampMilliseconds == 200_000 ? nil : $0.elevationMeters)
        }

        let result = SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: points)]))
        #expect(result.runCount == 0)
        #expect(result.liftCount == 1)
        #expect(result.lifts.first?.startedAt == track.points.first?.recordedAt)
        #expect(result.lifts.first?.endedAt == track.points.last?.recordedAt)
    }

    @Test func extendedMissingElevationKeepsSeparatelyObservedAscentsApart() throws {
        var track = SyntheticTrack()
        track.travel(seconds: 400, speed: 3, climbRate: 1)
        let points = try track.points.map {
            try TrackPoint(recordedAt: $0.recordedAt, coordinate: $0.coordinate,
                           elevationMeters: (120_000...280_000).contains($0.timestampMilliseconds) ? nil : $0.elevationMeters)
        }

        let result = SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: points)]))
        #expect(result.runCount == 1)
        #expect(result.liftCount == 2)
        if let first = result.lifts.first, let second = result.lifts.last {
            #expect(first.endedAt < 120_000)
            #expect(second.startedAt > 280_000)
        }
    }

    @Test func samplingGapsPreserveTheIdentityOfAnObservedRun() {
        var track = SyntheticTrack()
        track.travel(seconds: 90, speed: 8, climbRate: -1)
        track.gap(seconds: 300, distanceMeters: 0, elevationChange: 0)
        track.travel(seconds: 90, speed: 8, climbRate: -1)
        let geometry = fixtureGeometry([track.segment])
        #expect(geometry.sections.count == 1)

        let result = SkiActivityDetector.analyze(geometry)
        #expect(result.runCount == 1)
        #expect(result.liftCount == 0)
    }

    @Test func aLongSampleIntervalStillBelongsToItsNonLiftRun() {
        var track = SyntheticTrack()
        track.travel(seconds: 90, speed: 0, climbRate: 0)
        track.gap(seconds: 300, distanceMeters: 5_000, elevationChange: -500)
        track.travel(seconds: 90, speed: 0, climbRate: 0)

        let result = SkiActivityDetector.analyze(fixtureGeometry([track.segment]))
        #expect(result.runCount == 1)
        #expect(result.liftCount == 0)
    }

    @Test func explicitSourceBoundariesKeepDownhillRunsSeparate() {
        var first = SyntheticTrack()
        first.travel(seconds: 120, speed: 8, climbRate: -1)
        var second = SyntheticTrack(startSeconds: 130)
        second.travel(seconds: 120, speed: 8, climbRate: -1)
        let geometry = fixtureGeometry([first.segment, second.segment])
        #expect(geometry.sections.last?.breakBefore == .sourceBoundary)

        let result = SkiActivityDetector.analyze(geometry)
        #expect(result.runCount == 2)
        #expect(result.liftCount == 0)
    }

    @Test func shortAscentDoesNotCountAsALiftDespiteSubstantialElevationGain() {
        var track = SyntheticTrack()
        track.travel(seconds: 30, speed: 3, climbRate: 2)

        let result = SkiActivityDetector.analyze(fixtureGeometry([track.segment]))
        #expect(result.runCount == 1)
        #expect(result.liftCount == 0)
    }

    private struct SyntheticTrack {
        static let metersPerDegree = Double.pi * 6_371_000 / 180
        private var seconds: Int
        private var distanceMeters = 0.0
        private var elevation = 1_000.0
        private(set) var points: [TrackPoint] = []
        var segment: GPXSegment { GPXSegment(points: points) }

        init(startSeconds: Int = 0) {
            seconds = startSeconds
            appendPoint()
        }

        mutating func travel(seconds duration: Int, speed: Double, climbRate: Double) {
            precondition(duration > 0 && duration.isMultiple(of: 10))
            for _ in stride(from: 0, to: duration, by: 10) {
                seconds += 10
                distanceMeters += speed * 10
                elevation += climbRate * 10
                appendPoint()
            }
        }

        mutating func gap(seconds duration: Int, distanceMeters distance: Double, elevationChange: Double) {
            seconds += duration
            distanceMeters += distance
            elevation += elevationChange
            appendPoint()
        }

        private mutating func appendPoint() {
            points.append(try! TrackPoint(timestampMilliseconds: Int64(seconds) * 1_000, latitude: 0,
                                          longitude: distanceMeters / Self.metersPerDegree, elevationMeters: elevation))
        }
    }
}
