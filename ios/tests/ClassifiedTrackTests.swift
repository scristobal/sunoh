import Foundation
import Testing
@testable import Sunoh

struct ClassifiedTrackTests {
    @Test func splitsBetweenObservationsAndSharesExactBoundaryPoints() throws {
        let original = try [point(0), point(20), point(40)]
        let geometry = fixtureGeometry([GPXSegment(points: original)])
        let passages = SkiActivityDetector.Result(runs: [passage(5, 15), passage(25, 35)], lifts: [passage(15, 25)])
        let sections = Geo.classifiedSections(in: geometry, passages: passages)

        #expect(sections.map(\.classification) == [.run, .lift, .run])
        #expect(sections.map { $0.points.map(\.timestampMilliseconds) } == [
            [0, 5_000, 15_000], [15_000, 20_000, 25_000], [25_000, 35_000, 40_000]
        ])
        for (left, right) in zip(sections, sections.dropFirst()) {
            #expect(left.points.last == right.points.first)
        }
        #expect(sections[1].points.first?.elevationMeters == 850)
        #expect(sections[1].points.last?.elevationMeters == 750)
        #expect(sections[1].points[1] == original[1])
        #expect(sections.first?.points.first == original.first)
        #expect(sections.last?.points.last == original.last)
        let coveredMilliseconds = sections.reduce(Int64(0)) { total, section in
            total + zip(section.points, section.points.dropFirst()).reduce(0) { $0 + $1.1.timestampMilliseconds - $1.0.timestampMilliseconds }
        }
        #expect(coveredMilliseconds == 40_000)
        #expect(geometry.sections.first?.points == original)
    }

    @Test func mergesAdjacentIntervalsWithTheSameClassification() throws {
        let points = try [point(0), point(5), point(15), point(20)]
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let passages = SkiActivityDetector.Result(runs: [passage(0, 10), passage(10, 20)])
        let sections = Geo.classifiedSections(in: geometry, passages: passages)

        #expect(sections.count == 1)
        #expect(sections.first?.classification == .run)
        #expect(sections.first?.points.map(\.timestampMilliseconds) == [0, 5_000, 10_000, 15_000, 20_000])
        #expect(Geo.classifiedSections(in: geometry, passages: SkiActivityDetector.Result()) == [ClassifiedTrackSection(classification: .run, points: points)])
    }

    @Test func longSampleIntervalsRemainDrawableWhileSourceBoundariesAndSingletonsStaySeparate() throws {
        let geometry = try fixtureGeometry([
            GPXSegment(points: [point(0), point(30), point(70), point(80), point(120)]),
            GPXSegment(points: [point(130), point(140)]),
            GPXSegment(points: [point(150)])
        ])
        let sections = Geo.classifiedSections(in: geometry, passages: SkiActivityDetector.Result(runs: [passage(0, 150)]))

        #expect(sections.map(\.classification) == [.run, .run])
        #expect(sections.map { $0.points.map(\.timestampMilliseconds) } == [[0, 30_000, 70_000, 80_000, 120_000], [130_000, 140_000]])
        #expect(sections.allSatisfy { $0.points.count >= 2 })
    }

    @Test func rejectsOnlyNonpositiveIntervalsInsideAnUnsplitSection() throws {
        let points = try [point(0), point(10), point(10), point(5), point(15), point(60), point(70)]
        let geometry = TrackGeometry(activityID: "invalid-intervals", sourceRevision: 1,
                                     sections: [TrackSection(sourceSegmentID: "source", breakBefore: nil, points: points)])
        let sections = Geo.classifiedSections(in: geometry, passages: SkiActivityDetector.Result())

        #expect(sections.map { $0.points.map(\.timestampMilliseconds) } == [[0, 10_000], [5_000, 15_000, 60_000, 70_000]])
        #expect(sections.allSatisfy { $0.classification == .run })
    }

    @Test func missingAltitudeDoesNotInventBoundaryElevations() throws {
        let first = try point(0)
        let last = try TrackPoint(timestampMilliseconds: 20_000, latitude: 0, longitude: 0.002, elevationMeters: nil)
        let sections = Geo.classifiedSections(in: fixtureGeometry([GPXSegment(points: [first, last])]),
                                             passages: SkiActivityDetector.Result(lifts: [passage(5, 15)]))

        #expect(sections.count == 3)
        #expect(sections[1].points.allSatisfy { $0.elevationMeters == nil })
        #expect(sections.first?.points.first == first)
        #expect(sections.last?.points.last == last)
    }

    @Test func interpolatesTheShortPathAcrossTheAntimeridian() throws {
        let first = try TrackPoint(timestampMilliseconds: 0, latitude: 10, longitude: 179.8, elevationMeters: 1_000)
        let last = try TrackPoint(timestampMilliseconds: 20_000, latitude: 12, longitude: -179.8, elevationMeters: 800)
        let sections = Geo.classifiedSections(in: fixtureGeometry([GPXSegment(points: [first, last])]),
                                             passages: SkiActivityDetector.Result(lifts: [passage(5, 15)]))
        let run = try #require(sections.first { $0.classification == .lift })
        let start = try #require(run.points.first), end = try #require(run.points.last)

        #expect(abs(start.longitude - 179.9) < 0.000001)
        #expect(abs(end.longitude + 179.9) < 0.000001)
        #expect(start.latitude == 10.5)
        #expect(end.latitude == 11.5)
        #expect(start.elevationMeters == 950)
        #expect(end.elevationMeters == 850)
        #expect(sections.first?.points.first == first)
        #expect(sections.last?.points.last == last)
    }

    @Test func emptyTracksAndIsolatedObservationsHaveNoDrawableSections() throws {
        let passages = SkiActivityDetector.Result(runs: [passage(0, 20)])
        #expect(Geo.classifiedSections(in: fixtureGeometry([]), passages: passages).isEmpty)
        #expect(Geo.classifiedSections(in: fixtureGeometry([GPXSegment(points: [try point(10)])]), passages: passages).isEmpty)
    }

    @Test func passageCodingPreservesExactBoundaries() throws {
        let passages = SkiActivityDetector.Result(runs: [.init(startedAt: 1_234, endedAt: 9_876)], lifts: [.init(startedAt: 9_876, endedAt: 54_321)])
        let encoded = try JSONEncoder().encode(passages)
        #expect(try JSONDecoder().decode(SkiActivityDetector.Result.self, from: encoded) == passages)
    }

    private func point(_ seconds: Int) throws -> TrackPoint {
        try TrackPoint(timestampMilliseconds: Int64(seconds) * 1_000, latitude: 0,
                       longitude: Double(seconds) / 10_000, elevationMeters: 1_000 - Double(seconds) * 10)
    }

    private func passage(_ startSeconds: Int, _ endSeconds: Int) -> SkiActivityDetector.Passage {
        SkiActivityDetector.Passage(startedAt: Timestamp(millisecondsSince1970: Int64(startSeconds) * 1_000),
                                    endedAt: Timestamp(millisecondsSince1970: Int64(endSeconds) * 1_000))
    }
}
