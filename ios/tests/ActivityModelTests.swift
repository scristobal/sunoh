import Foundation
import SwiftData
import Testing
@testable import Sunoh

struct ActivityModelTests {
    @Test func continuityPreservesSourceBoundariesWithoutSplittingLongSampleIntervals() throws {
        let points = try [0, 30_000, 60_001].map {
            try TrackPoint(timestampMilliseconds: Int64($0), latitude: 47, longitude: 11 + Double($0) / 1_000_000, elevationMeters: nil)
        }
        let source = fixtureTrack([GPXSegment(points: points), GPXSegment(points: [try TrackPoint(timestampMilliseconds: 60_002,
            latitude: 48, longitude: 12, elevationMeters: 900)])])
        let geometry = TrackContinuityPolicy.geometry(for: source)
        #expect(source.segments.count == 2)
        #expect(geometry.sections.map { $0.points.count } == [3, 1])
        #expect(geometry.sections.map(\.breakBefore) == [nil, .sourceBoundary])
        #expect(geometry.sections[0].sourceSegmentID != geometry.sections[1].sourceSegmentID)
        #expect(geometry.sections.map(\.points) == source.segments.map(\.points))
        #expect(try GPX.decode(GPX.encode(source.gpx)) == [source.gpx])
    }

    @Test func invalidObservationsCannotEnterTheDomainEvenThroughDecoding() throws {
        #expect(throws: ActivityError.self) { try Coordinate(latitude: 91, longitude: 10) }
        #expect(throws: ActivityError.self) { try TrackPoint(timestampMilliseconds: -1, latitude: 47, longitude: 11, elevationMeters: nil) }
        #expect(throws: ActivityError.self) { try TrackPoint(timestampMilliseconds: 1, latitude: 47, longitude: 11, elevationMeters: .infinity) }
        let encoded = Data(#"{"recordedAt":{"millisecondsSince1970":1},"coordinate":{"latitude":47,"longitude":181}}"#.utf8)
        #expect(throws: ActivityError.self) { try JSONDecoder().decode(TrackPoint.self, from: encoded) }
    }

    @Test func latePointsAdvanceSourceRevisionAndCompletionDoesNotChangeLastPointTime() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        let repository = try await ActivityRepository.open(url: url, clock: { 1_000 })
        let active = try await repository.start()
        let points = try [1_001, 1_003, 1_002].map { try TrackPoint(timestampMilliseconds: Int64($0), latitude: 47, longitude: 11, elevationMeters: nil) }
        let first = try await repository.append(Array(points.prefix(2)), activityID: active.id)
        let late = try await repository.append([points[2]], activityID: active.id)
        #expect(late.summary.lastPointAt == first.summary.lastPointAt)
        #expect(late.summary.sourceRevision > first.summary.sourceRevision)
        let retry = try await repository.append([points[2]], activityID: active.id)
        #expect(retry.summary.sourceRevision == late.summary.sourceRevision)
        _ = try await repository.stop(id: active.id)
        let finished = try await repository.finish(id: active.id)
        #expect(finished.lastPointAt == 1_003)
        #expect(finished.completedAt == 1_003)
        #expect(finished.status == .completed)
        #expect(finished.pointCount == 3)
    }

    @Test func cascadeDeletionLeavesNoOrphanedSegmentsPointsOrAnalysis() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        let repository = try await ActivityRepository.open(url: url, clock: { 1_000 })
        let point = try TrackPoint(timestampMilliseconds: 1_000, latitude: 47, longitude: 11, elevationMeters: nil)
        let imported = try #require(try await repository.importTracks([GPXTrack(segments: [GPXSegment(points: [point])])]).imported.first)
        _ = try await ActivityProcessor(repository: repository).process(id: imported.id)
        try await repository.delete(id: imported.id)
        try await Task.detached {
            let context = ModelContext(try ActivityDatabase.container(at: url))
            #expect(try context.fetchCount(FetchDescriptor<StoredActivity>()) == 0)
            #expect(try context.fetchCount(FetchDescriptor<StoredTrackSegment>()) == 0)
            #expect(try context.fetchCount(FetchDescriptor<StoredTrackPoint>()) == 0)
            #expect(try context.fetchCount(FetchDescriptor<StoredActivityAnalysis>()) == 0)
        }.value
    }
}
