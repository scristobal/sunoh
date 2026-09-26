import Foundation
import Testing
@testable import Sunoh

struct SkiFeatureMatcherTests {
    @Test func liftPassageCanTraverseMultipleFeaturesAndResorts() throws {
        let umbrella = SkiResort(id: "region", name: "Connected region", sources: [])
        let west = SkiResort(id: "west", name: "West resort", sources: [])
        let east = SkiResort(id: "east", name: "East resort", sources: [])
        let a = try feature("a", from: (0, 0), to: (100, 0), resorts: [west, umbrella])
        let b = try feature("b", from: (100, 0), to: (200, 0), resorts: [east, umbrella])
        let points = try (0...10).map { try point($0 * 2, x: Double($0) * 20) }
        let result = match(points: points, features: [b, a])

        #expect(result.datasetVersion == "fixture-v1")
        #expect(result.entries.count == 1)
        #expect(result.entries[0].map(\.feature.id) == ["a", "b"])
        #expect(result.entries[0].map(\.startedAt) == [0, 10_000])
        #expect(result.entries[0].map(\.endedAt) == [10_000, 20_000])
        #expect(result.entries[0].allSatisfy { $0.confidence > 0.99 && $0.confidence <= 1 })
        #expect(result.resorts.map(\.id) == ["west", "region", "east"])
        #expect(result.entries[0][0].feature == a.identity)
    }

    @Test func multipleLiftsCanAppearWithinOneLiftEntry() throws {
        let first = try feature("lower", kind: .lift, from: (0, 0), to: (100, 0))
        let second = try feature("upper", kind: .lift, from: (100, 0), to: (200, 0))
        let points = try (0...10).map { try point($0 * 5, x: Double($0) * 20) }
        let result = match(points: points, kind: .lift, features: [first, second])

        #expect(result.entries[0].map(\.feature.id) == ["lower", "upper"])
    }

    @Test func ambiguousParallelLiftsStayUnmatchedRegardlessOfInputOrder() throws {
        let a = try feature("a", from: (0, 0), to: (200, 0))
        let b = try feature("b", from: (0, 5), to: (200, 5))
        let points = try (0...8).map { try point($0, x: Double($0) * 20, y: 2) }
        for features in [[a, b], [b, a]] {
            let result = match(points: points, features: features)
            #expect(result.entries == [[]])
            #expect(result.resorts.isEmpty)
        }
    }

    @Test func unsupportedFarAwayAndSingleIntervalPassesDoNotAssignFeatures() throws {
        let resort = SkiResort(id: "nearby", name: "Nearby resort", sources: [])
        let a = try feature("a", from: (0, 0), to: (200, 0), resorts: [resort])
        let farPoints = try (0...8).map { try point($0, x: Double($0) * 20, y: 50) }
        let oneInterval = try [point(0, x: 0), point(1, x: 100)]
        #expect(match(points: farPoints, features: [a]).entries == [[]])
        #expect(match(points: oneInterval, features: [a]).resorts.isEmpty)
    }

    @Test func anUncontestedCandidateStillNeedsStrongAbsoluteEvidence() throws {
        let lift = try feature("distant", from: (0, 0), to: (200, 0))
        let points = try (0...8).map { try point($0, x: Double($0) * 20, y: 24) }
        #expect(match(points: points, features: [lift]).entries == [[]])
        let nearby = try (0...8).map { try point($0, x: Double($0) * 20, y: 10) }
        #expect(match(points: nearby, features: [lift]).entries[0].map(\.feature.id) == ["distant"])
    }

    @Test func longObservationGapsRemainUnmatchedWithoutChangingTheTimeline() throws {
        let lift = try feature("lift", from: (0, 0), to: (300, 0))
        let points = try [point(0, x: 0), point(1, x: 20), point(2, x: 40), point(62, x: 200), point(63, x: 220), point(64, x: 240)]
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let timeline = ActivityTimeline(entries: [entry(from: 0, to: 64_000)])
        let result = SkiFeatureMatcher.match(geometry: geometry, timeline: timeline, features: [lift], datasetVersion: "fixture-v1")
        #expect(result.entries[0].map(\.startedAt) == [0, 62_000])
        #expect(result.entries[0].map(\.endedAt) == [2_000, 64_000])
        #expect(timeline.entries.count == 1)
        #expect(timeline.breaks.isEmpty)
        #expect(geometry.sections[0].points == points)
    }

    @Test func impossibleTravelCannotMatchEvenAlongAnExactReferenceLine() throws {
        let lift = try feature("lift", from: (0, 0), to: (300, 0))
        let points = try [point(0, x: 0), point(1, x: 20), point(2, x: 40), point(3, x: 200), point(4, x: 220), point(5, x: 240)]
        let matches = match(points: points, features: [lift]).entries[0]
        #expect(matches.map(\.startedAt) == [0, 3_000])
        #expect(matches.map(\.endedAt) == [2_000, 5_000])
    }

    @Test func matcherUsesOriginalSampleIntervalsAcrossClippedTimelineBoundaries() throws {
        let lift = try feature("lift", from: (0, 0), to: (300, 0))
        let points = try [point(0, x: 0), point(40, x: 100), point(80, x: 200)]
        let timeline = ActivityTimeline(entries: [entry(from: 20_000, to: 60_000)])
        let result = SkiFeatureMatcher.match(geometry: fixtureGeometry([GPXSegment(points: points)]), timeline: timeline, features: [lift], datasetVersion: "fixture-v1")
        #expect(result.entries == [[]])

        let supported = try [point(0, x: 0), point(30, x: 100), point(60, x: 200)]
        #expect(match(points: supported, features: [lift]).entries[0].map(\.feature.id) == ["lift"])
    }

    @Test func runEntriesAndRunFeaturesCannotMatchOrContributeResorts() throws {
        let runResort = SkiResort(id: "run-area", name: "Run-only area", sources: [])
        let liftResort = SkiResort(id: "lift-area", name: "Lift area", sources: [])
        let run = try feature("run", kind: .run, from: (0, 0), to: (200, 0), resorts: [runResort])
        let lift = try feature("lift", from: (0, 0), to: (200, 0), resorts: [liftResort])
        let points = try (0...8).map { try point($0, x: Double($0) * 20) }
        let ignoredRun = match(points: points, kind: .run, features: [run, lift])
        #expect(ignoredRun.entries == [[]])
        #expect(ignoredRun.resorts.isEmpty)

        let matchedLift = match(points: points, features: [run, lift])
        #expect(matchedLift.entries[0].map(\.feature.id) == ["lift"])
        #expect(matchedLift.resorts == [liftResort])
        let noLiftCandidates = match(points: points, features: [run])
        #expect(noLiftCandidates.entries == [[]])
        #expect(noLiftCandidates.resorts.isEmpty)
    }

    @Test func perpendicularCrossingDoesNotBecomeAPassage() throws {
        let crossing = try feature("crossing", from: (100, -100), to: (100, 100))
        let points = try (0...10).map { try point($0, x: Double($0) * 20) }
        #expect(match(points: points, features: [crossing]).entries == [[]])
    }

    @Test func reenteringAFeatureAfterAnUnmatchedPortionPreservesBothSpans() throws {
        let lift = try feature("repeated", from: (0, 0), to: (200, 0))
        let points = try [point(0, x: 0), point(1, x: 20), point(2, x: 40), point(3, x: 60, y: 60),
                          point(4, x: 80, y: 60), point(5, x: 100), point(6, x: 120), point(7, x: 140)]
        let spans = match(points: points, features: [lift]).entries[0]
        #expect(spans.map(\.feature.id) == ["repeated", "repeated"])
        #expect(spans.map(\.startedAt) == [0, 5_000])
        #expect(spans.map(\.endedAt) == [2_000, 7_000])
    }

    @Test func sourceSectionsRemainSeparateEvenInsideOneTimelineEntry() throws {
        let lift = try feature("lift", from: (0, 0), to: (200, 0))
        let first = try [point(0, x: 0), point(1, x: 20), point(2, x: 40)]
        let second = try [point(10, x: 100), point(11, x: 120), point(12, x: 140)]
        let geometry = fixtureGeometry([GPXSegment(points: first), GPXSegment(points: second)])
        let timeline = ActivityTimeline(entries: [entry(from: 0, to: 12_000)])
        let result = SkiFeatureMatcher.match(geometry: geometry, timeline: timeline, features: [lift], datasetVersion: "fixture-v1")
        #expect(result.entries[0].map(\.startedAt) == [0, 10_000])
        #expect(result.entries[0].map(\.endedAt) == [2_000, 12_000])
    }

    @Test func overlappingSourceSectionsDoNotDuplicateAlreadyCoveredTime() throws {
        let lift = try feature("lift", from: (0, 0), to: (200, 0))
        let first = try (0...3).map { try point($0, x: Double($0) * 20) }
        let second = try (2...5).map { try point($0, x: Double($0) * 20) }
        let geometry = fixtureGeometry([GPXSegment(points: first), GPXSegment(points: second)])
        let timeline = ActivityTimeline(entries: [entry(from: 0, to: 5_000)])
        let result = SkiFeatureMatcher.match(geometry: geometry, timeline: timeline, features: [lift], datasetVersion: "fixture-v1")
        #expect(result.entries[0].map(\.startedAt) == [0, 3_000])
        #expect(result.entries[0].map(\.endedAt) == [3_000, 5_000])
        #expect(geometry.sections[0].points == first)
        #expect(geometry.sections[1].points == second)
    }

    @Test func explicitTimelineBreaksAreNeverMatched() throws {
        let lift = try feature("lift", from: (0, 0), to: (200, 0))
        let points = try (0...8).map { try point($0, x: Double($0) * 20) }
        let timeline = ActivityTimeline(entries: [entry(from: 0, to: 8_000)],
                                        breaks: [ActivityTimelineBreak(startedAt: 3_000, endedAt: 5_000, reason: .sourceBoundary)])
        let result = SkiFeatureMatcher.match(geometry: fixtureGeometry([GPXSegment(points: points)]), timeline: timeline, features: [lift], datasetVersion: "fixture-v1")
        #expect(result.entries[0].map(\.startedAt) == [0, 5_000])
        #expect(result.entries[0].map(\.endedAt) == [3_000, 8_000])
    }

    @Test func timelineClassificationBoundariesClipLiftMatchesWithoutChangingRunEntries() throws {
        let runResort = SkiResort(id: "run-area", name: "Run-only area", sources: [])
        let liftResort = SkiResort(id: "lift-area", name: "Lift area", sources: [])
        let run = try feature("run", kind: .run, from: (0, 0), to: (200, 0), resorts: [runResort])
        let lift = try feature("lift", from: (0, 0), to: (200, 0), resorts: [liftResort])
        let points = try (0...10).map { try point($0, x: Double($0) * 20) }
        let timeline = ActivityTimeline(entries: [entry(kind: .run, from: 500, to: 4_500), entry(from: 4_500, to: 9_500), entry(kind: .run, from: 9_500, to: 10_000)])
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let result = SkiFeatureMatcher.match(geometry: geometry, timeline: timeline, features: [run, lift], datasetVersion: "fixture-v1")
        #expect(result.entries.map { $0.map(\.feature.id) } == [[], ["lift"], []])
        #expect(result.entries[1][0].startedAt == 4_500)
        #expect(result.entries[1][0].endedAt == 9_500)
        #expect(result.resorts == [liftResort])
        #expect(timeline.entries.map(\.kind) == [.run, .lift, .run])
        #expect(geometry.sections[0].points == points)
    }

    @Test func stationaryJitterCannotAccumulateIntoAFeatureTraversal() throws {
        let lift = try feature("lift", from: (0, 0), to: (200, 0))
        let points = try (0...100).map { try point($0, x: $0.isMultiple(of: 2) ? 100 : 103) }
        #expect(match(points: points, features: [lift]).entries == [[]])
    }

    @Test func slowLiftAndIntermediateStationarySamplesKeepTheirAssociation() throws {
        let lift = try feature("lift", kind: .lift, from: (0, 0), to: (100, 0))
        let positions = Array(stride(from: 0.0, through: 40.0, by: 2)) + Array(repeating: 40.0, count: 5) + Array(stride(from: 42.0, through: 80.0, by: 2))
        let points = try positions.enumerated().map { try point($0.offset, x: $0.element) }
        let result = match(points: points, kind: .lift, features: [lift])
        #expect(result.entries[0].count == 1)
        #expect(result.entries[0].first?.startedAt == points.first?.recordedAt)
        #expect(result.entries[0].first?.endedAt == points.last?.recordedAt)
    }

    @Test func referenceGeometryOrientationDoesNotImplyTravelDirection() throws {
        let lift = try feature("lift", from: (200, 0), to: (0, 0))
        let points = try (0...8).map { try point($0, x: Double($0) * 20) }
        #expect(match(points: points, features: [lift]).entries[0].map(\.feature.id) == ["lift"])
    }

    @Test func unknownResortLinksAndEmptyInputsRemainEmpty() throws {
        let lift = try feature("lift", from: (0, 0), to: (200, 0))
        let points = try (0...8).map { try point($0, x: Double($0) * 20) }
        #expect(match(points: points, features: [lift]).resorts.isEmpty)
        #expect(match(points: points, features: []).entries == [[]])
        let empty = SkiFeatureMatcher.match(geometry: fixtureGeometry([]), timeline: ActivityTimeline(), features: [lift], datasetVersion: "fixture-v1")
        #expect(empty.entries.isEmpty)
        #expect(empty.resorts.isEmpty)
    }

    @Test func spatialIndexFindsAnEdgeAcrossTheAntimeridian() throws {
        let start = try Coordinate(latitude: 45, longitude: 179.999)
        let end = try Coordinate(latitude: 45, longitude: -179.999)
        let identity = SkiFeatureIdentity(id: "dateline", kind: .lift, sources: [], resorts: [])
        let feature = SkiFeature(identity: identity, coordinates: [start, end])
        let points = try (0...8).map { index in
            let longitude = 179.999 + Double(index) * 0.00025
            return try TrackPoint(timestampMilliseconds: Int64(index) * 1_000, latitude: 45, longitude: longitude > 180 ? longitude - 360 : longitude, elevationMeters: nil)
        }
        #expect(match(points: points, features: [feature]).entries[0].map(\.feature.id) == ["dateline"])
    }

    private func match(points: [TrackPoint], kind: ActivityTimelineKind = .lift, features: [SkiFeature]) -> SkiTimelineMatches {
        let timeline = ActivityTimeline(entries: [entry(kind: kind, from: points.first!.recordedAt, to: points.last!.recordedAt)])
        return SkiFeatureMatcher.match(geometry: fixtureGeometry([GPXSegment(points: points)]), timeline: timeline, features: features, datasetVersion: "fixture-v1")
    }

    private func entry(kind: ActivityTimelineKind = .lift, from start: Timestamp, to end: Timestamp) -> ActivityTimelineEntry {
        ActivityTimelineEntry(kind: kind, startedAt: start, endedAt: end, distanceMeters: nil, elevationGainMeters: nil, elevationLossMeters: nil)
    }

    private func feature(_ id: String, kind: ActivityTimelineKind = .lift, from start: (Double, Double), to end: (Double, Double), resorts: [SkiResort] = []) throws -> SkiFeature {
        SkiFeature(identity: SkiFeatureIdentity(id: id, kind: kind,
                                               sources: [SkiFeatureSource(type: "way", id: "source-\(id)")], resorts: resorts),
                   coordinates: [try coordinate(x: start.0, y: start.1), try coordinate(x: end.0, y: end.1)])
    }

    private func coordinate(x: Double, y: Double) throws -> Coordinate {
        let degreesPerMeter = 180 / (Double.pi * 6_371_000)
        return try Coordinate(latitude: y * degreesPerMeter, longitude: x * degreesPerMeter)
    }

    private func point(_ seconds: Int, x: Double, y: Double = 0) throws -> TrackPoint {
        try TrackPoint(recordedAt: Timestamp(millisecondsSince1970: Int64(seconds) * 1_000), coordinate: coordinate(x: x, y: y), elevationMeters: nil)
    }
}
