import Testing
@testable import Sunoh

struct TrackSelectionTests {
    @Test func clipsBetweenSamplesAndRetainsExactInteriorObservations() throws {
        let points = try [point(0), point(10), point(20)]
        let original = fixtureGeometry([GPXSegment(points: points)])
        let selected = Geo.selectedGeometry(in: original, entry: entry(5, 15))
        let result = try #require(selected.sections.first).points
        #expect(result.map(\.timestampMilliseconds) == [5_000, 10_000, 15_000])
        #expect(result[1] == points[1])
        #expect(result.first?.elevationMeters == 1_950)
        #expect(result.last?.elevationMeters == 1_850)
        #expect(abs(try #require(result.first?.latitude) - 47.0005) < 0.000001)
        #expect(original.sections.first?.points == points)
        #expect(selected.activityID == original.activityID)
        #expect(selected.sourceRevision == original.sourceRevision)
    }

    @Test func retainsSeparateSourceSectionsWithoutConnectingTheGap() throws {
        let original = try fixtureGeometry([GPXSegment(points: [point(0), point(10)]), GPXSegment(points: [point(30), point(40)])])
        let selected = Geo.selectedGeometry(in: original, entry: entry(5, 35))
        #expect(selected.sections.map { $0.points.map(\.timestampMilliseconds) } == [[5_000, 10_000], [30_000, 35_000]])
        #expect(selected.sections.map(\.sourceSegmentID) == original.sections.map(\.sourceSegmentID))
        #expect(selected.sections.map(\.breakBefore) == [nil, .sourceBoundary])
    }

    @Test func doesNotJoinReversedIntervalsOrInventOutsideData() throws {
        let original = try fixtureGeometry([GPXSegment(points: [point(0), point(10), point(5), point(15)])])
        let selected = Geo.selectedGeometry(in: original, entry: entry(0, 20))
        #expect(selected.sections.map { $0.points.map(\.timestampMilliseconds) } == [[0, 10_000], [5_000, 15_000]])
        #expect(Geo.selectedGeometry(in: original, entry: entry(30, 40)).sections.isEmpty)
        #expect(Geo.selectedGeometry(in: original, entry: entry(10, 10)).sections.isEmpty)
    }

    @Test func interpolatesAcrossTheDateLineWithoutInventingMissingElevation() throws {
        let points = try [TrackPoint(timestampMilliseconds: 0, latitude: 47, longitude: 179.8, elevationMeters: 2_000),
                          TrackPoint(timestampMilliseconds: 20_000, latitude: 47, longitude: -179.8, elevationMeters: nil)]
        let selected = Geo.selectedGeometry(in: fixtureGeometry([GPXSegment(points: points)]), entry: entry(5, 15))
        let section = try #require(selected.sections.first)
        #expect(abs(try #require(section.points.first?.longitude) - 179.9) < 0.000001)
        #expect(abs(try #require(section.points.last?.longitude) + 179.9) < 0.000001)
        #expect(section.points.allSatisfy { $0.elevationMeters == nil })
    }

    private func point(_ seconds: Int64) throws -> TrackPoint {
        try TrackPoint(timestampMilliseconds: seconds * 1_000, latitude: 47 + Double(seconds) / 10_000,
                       longitude: 11, elevationMeters: 2_000 - Double(seconds) * 10)
    }

    private func entry(_ start: Int64, _ end: Int64) -> ActivityTimelineEntry {
        ActivityTimelineEntry(kind: .run, startedAt: Timestamp(millisecondsSince1970: start * 1_000),
                              endedAt: Timestamp(millisecondsSince1970: end * 1_000), distanceMeters: nil,
                              elevationGainMeters: nil, elevationLossMeters: nil)
    }
}
