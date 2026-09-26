import Foundation
import Testing
@testable import Sunoh

struct ActivityElevationProfileDataTests {
    @Test func sourceSectionsAndMissingElevationsStaySeparate() throws {
        let first = try [point(0, 1_500), point(10, 1_600), point(20, nil), point(30, 1_700), point(40, 1_800)]
        let second = try [point(60, 1_400), point(70, 1_300)]
        let geometry = fixtureGeometry([GPXSegment(points: first), GPXSegment(points: second)])
        let profile = ActivityElevationProfileData(geometry: geometry)

        #expect(profile.sections.map { $0.map(\.elapsedSeconds) } == [[0, 10], [30, 40], [60, 70]])
        #expect(profile.sections.map { $0.map(\.elevationMeters) } == [[1_500, 1_600], [1_700, 1_800], [1_400, 1_300]])
        #expect(profile.durationSeconds == 70)
        #expect(profile.minimumElevationMeters == 1_300)
        #expect(profile.maximumElevationMeters == 1_800)
        #expect(geometry.sections.map(\.points) == [first, second])
    }

    @Test func elapsedExtentIncludesLeadingAndTrailingSamplesWithoutElevation() throws {
        let points = try [point(100, nil), point(110, 1_000), point(150, 1_200), point(200, nil)]
        let profile = ActivityElevationProfileData(geometry: fixtureGeometry([GPXSegment(points: points)]))

        #expect(profile.durationSeconds == 100)
        #expect(profile.startedAt == 100_000)
        #expect(profile.endedAt == 200_000)
        #expect(profile.sections.map { $0.map(\.elapsedSeconds) } == [[10, 50]])
        #expect(profile.minimumElevationMeters == 1_000)
        #expect(profile.maximumElevationMeters == 1_200)
    }

    @Test func duplicateAndReversedTimestampsCannotConnectALine() throws {
        let points = try [point(0, 1_000), point(10, 1_100), point(10, 1_300), point(5, 1_200), point(15, 1_400)]
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let profile = ActivityElevationProfileData(geometry: geometry)

        #expect(profile.sections.map { $0.map(\.elapsedSeconds) } == [[0, 10], [10], [5, 15]])
        #expect(profile.sections.allSatisfy { samples in zip(samples, samples.dropFirst()).allSatisfy { $0.elapsedSeconds < $1.elapsedSeconds } })
        #expect(profile.durationSeconds == 15)
        #expect(profile.minimumElevationMeters == 1_000)
        #expect(profile.maximumElevationMeters == 1_400)
        #expect(geometry.sections[0].points == points)
    }

    @Test func longSamplingIntervalsRemainRecordedPairsWithoutANewGlobalGapRule() throws {
        let points = try [point(0, 1_000), point(3_600, 2_000)]
        let profile = ActivityElevationProfileData(geometry: fixtureGeometry([GPXSegment(points: points)]))
        #expect(profile.sections.count == 1)
        #expect(profile.sections[0].map(\.elapsedSeconds) == [0, 3_600])
        #expect(profile.durationSeconds == 3_600)
    }

    @Test func reductionKeepsFullExtentsAndPeaksInOriginalOrder() throws {
        let points = try (0..<10_000).map { index in
            let elevation: Double = index == 1_231 ? 4_000 : index == 8_765 ? -200 : 1_000 + Double(index % 200)
            return try point(index, elevation)
        }
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let profile = ActivityElevationProfileData(geometry: geometry, maximumSamples: 100)
        let samples = try #require(profile.sections.first)

        #expect(samples.count <= 100)
        #expect(samples.first == .init(elapsedSeconds: 0, elevationMeters: 1_000))
        #expect(samples.last == .init(elapsedSeconds: 9_999, elevationMeters: 1_199))
        #expect(samples.contains(.init(elapsedSeconds: 1_231, elevationMeters: 4_000)))
        #expect(samples.contains(.init(elapsedSeconds: 8_765, elevationMeters: -200)))
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.elapsedSeconds < $1.elapsedSeconds })
        #expect(profile.minimumElevationMeters == -200)
        #expect(profile.maximumElevationMeters == 4_000)
        #expect(profile.durationSeconds == 9_999)
        #expect(profile == ActivityElevationProfileData(geometry: geometry, maximumSamples: 100))
        #expect(geometry.sections[0].points == points)
    }

    @Test func sampleBudgetIsSharedAcrossSectionsWithoutDroppingTheirEndpoints() throws {
        let segments = try (0..<10).map { section in
            GPXSegment(points: try (0..<200).map { try point(section * 1_000 + $0, 1_000 + Double($0)) })
        }
        let geometry = fixtureGeometry(segments)
        let profile = ActivityElevationProfileData(geometry: geometry, maximumSamples: 120)
        #expect(profile.sections.count == 10)
        #expect(profile.sections.map(\.count).reduce(0, +) <= 120)
        for (index, samples) in profile.sections.enumerated() {
            #expect(samples.first?.elapsedSeconds == Double(index * 1_000))
            #expect(samples.last?.elapsedSeconds == Double(index * 1_000 + 199))
        }

        let tinyBudget = ActivityElevationProfileData(geometry: geometry, maximumSamples: 0)
        #expect(tinyBudget.sections.count == 10)
        #expect(tinyBudget.sections.map(\.count).reduce(0, +) <= 40)
        #expect(tinyBudget.minimumElevationMeters == 1_000)
        #expect(tinyBudget.maximumElevationMeters == 1_199)
    }

    @Test func emptyMissingAndSingleElevationInputsRemainUsable() throws {
        let empty = ActivityElevationProfileData(geometry: fixtureGeometry([]))
        #expect(empty.sections.isEmpty)
        #expect(empty.minimumElevationMeters == nil)
        #expect(empty.maximumElevationMeters == nil)
        #expect(empty.durationSeconds == 0)
        #expect(empty.startedAt == nil)
        #expect(empty.endedAt == nil)

        let missing = ActivityElevationProfileData(geometry: try fixtureGeometry([GPXSegment(points: [point(0, nil), point(100, nil)])]))
        #expect(missing.sections.isEmpty)
        #expect(missing.minimumElevationMeters == nil)
        #expect(missing.maximumElevationMeters == nil)
        #expect(missing.durationSeconds == 100)

        let single = ActivityElevationProfileData(geometry: try fixtureGeometry([GPXSegment(points: [point(20, 1_200)])]))
        #expect(single.sections == [[.init(elapsedSeconds: 0, elevationMeters: 1_200)]])
        #expect(single.minimumElevationMeters == 1_200)
        #expect(single.maximumElevationMeters == 1_200)
        #expect(single.durationSeconds == 0)
    }
}

private func point(_ seconds: Int, _ elevation: Double?) throws -> TrackPoint {
    try TrackPoint(timestampMilliseconds: Int64(seconds) * 1_000, latitude: 47, longitude: 11, elevationMeters: elevation)
}
