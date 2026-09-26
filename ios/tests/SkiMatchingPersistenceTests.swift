import Foundation
import Testing
@testable import Sunoh

struct SkiMatchingPersistenceTests {
    @Test func multipleMatchesAndResortSnapshotsSurviveReopeningWithoutChangingObservations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("activity.store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let points = try (0...12).map { index in
            try TrackPoint(timestampMilliseconds: Int64(index) * 5_000, latitude: 47 + Double(index) * 0.0001,
                           longitude: 11, elevationMeters: 2_000 + Double(index) * 5)
        }
        let track = GPXTrack(segments: [GPXSegment(points: points)])
        let repository = try await ActivityRepository.open(url: url)
        let activity = try #require(try await repository.importTracks([track]).imported.first)
        let resorts = [
            SkiResort(id: "area-a", name: "North Peak", sources: [.init(type: "openstreetmap", id: "relation/1")]),
            SkiResort(id: "area-b", name: "South Bowl", sources: [.init(type: "skimap.org", id: "2")])
        ]
        let features = [
            SkiFeature(identity: SkiFeatureIdentity(id: "lift-a", kind: .lift,
                sources: [.init(type: "openstreetmap", id: "way/1")], resorts: [resorts[0]]), coordinates: Array(points[0...6]).map(\.coordinate)),
            SkiFeature(identity: SkiFeatureIdentity(id: "lift-b", kind: .lift,
                sources: [.init(type: "openstreetmap", id: "way/2")], resorts: [resorts[1]]), coordinates: Array(points[6...12]).map(\.coordinate))
        ]
        let processor = ActivityProcessor(repository: repository, calculate: { input in
            let geometry = TrackContinuityPolicy.geometry(for: input.track)
            let passages = SkiActivityDetector.analyze(geometry)
            var timeline = Geo.timeline(in: geometry, passages: passages)
            timeline.skiMatches = SkiFeatureMatcher.match(geometry: geometry, timeline: timeline, features: features, datasetVersion: "snapshot-1")
            return (ActivityStatistics(), Data([1]), passages, timeline)
        })
        let analysis = try await processor.process(id: activity.id)
        let matches = try #require(analysis.timeline?.skiMatches)
        #expect(matches.entries.first?.map(\.feature.id) == ["lift-a", "lift-b"])
        #expect(matches.resorts == resorts)
        #expect(matches.datasetVersion == "snapshot-1")
        #expect(matches.entries.first?.map(\.feature.sources) == features.map(\.identity.sources))
        #expect(matches.entries.first?.allSatisfy { $0.confidence > 0.99 && $0.confidence <= 1 } == true)
        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: activity.id) == analysis)
        #expect(try await reopened.recordedTrack(id: activity.id).gpx == track)
    }

    @Test func unavailableReferenceDataDoesNotRemoveTimelineOrRecording() async throws {
        let point = try TrackPoint(timestampMilliseconds: 0, latitude: 47, longitude: 11, elevationMeters: 2_000)
        let end = try TrackPoint(timestampMilliseconds: 10_000, latitude: 47.001, longitude: 11, elevationMeters: 1_980)
        let geometry = fixtureGeometry([GPXSegment(points: [point, end])])
        let timeline = Geo.timeline(in: geometry, passages: .init(lifts: [.init(startedAt: point.recordedAt, endedAt: end.recordedAt)]))
        let result = try await SkiDataCatalog.match(geometry: geometry, timeline: timeline,
                                                   catalog: SkiDataCatalog(directory: nil))
        #expect(result.failure != nil)
        #expect(result.entries.count == timeline.entries.count)
        #expect(result.entries.allSatisfy { $0.isEmpty })
        #expect(geometry.sections.first?.points == [point, end])
    }

    @Test func runOnlyActivityDoesNotRequireReferenceData() async throws {
        let points = try (0...3).map { index in
            try TrackPoint(timestampMilliseconds: Int64(index) * 5_000, latitude: 47 + Double(index) * 0.0001,
                           longitude: 11, elevationMeters: 2_000 - Double(index) * 5)
        }
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let timeline = Geo.timeline(in: geometry, passages: SkiActivityDetector.analyze(geometry))
        #expect(timeline.entries.map(\.kind) == [.run])
        let result = try await SkiDataCatalog.match(geometry: geometry, timeline: timeline,
                                                   catalog: SkiDataCatalog(directory: nil))
        #expect(result.failure == nil)
        #expect(result.entries == [[]])
        #expect(result.resorts.isEmpty)
    }

    @Test func previousRunMatchesAndTheirResortsAreRebuiltWithoutChangingRecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try await ActivityRepository.open(url: directory.appendingPathComponent("activity.store"))
        let points = try (0...12).map { index in
            try TrackPoint(timestampMilliseconds: Int64(index) * 5_000, latitude: 47 + Double(index) * 0.0001,
                           longitude: 11, elevationMeters: 2_000 - Double(index) * 5)
        }
        let track = GPXTrack(segments: [GPXSegment(points: points)])
        let activity = try #require(try await repository.importTracks([track]).imported.first)
        let processor = ActivityProcessor(repository: repository)
        let current = try await processor.process(id: activity.id)
        var timeline = try #require(current.timeline)
        let entry = try #require(timeline.entries.first)
        let resort = SkiResort(id: "run-only-area", name: "Unvalidated Area", sources: [])
        let feature = SkiFeatureIdentity(id: "old-piste", kind: .run, sources: [], resorts: [resort])
        timeline.skiMatches = SkiTimelineMatches(datasetVersion: "previous", entries: [[
            SkiFeatureMatch(feature: feature, startedAt: entry.startedAt, endedAt: entry.endedAt, confidence: 1)
        ]], resorts: [resort])
        let previous = ActivityAnalysis(activityID: activity.id, sourceRevision: activity.sourceRevision,
            processingVersion: 22, processedAt: current.processedAt, statistics: current.statistics,
            thumbnailPNG: current.thumbnailPNG, passages: current.passages, timeline: timeline)
        try await repository.saveAnalysis(previous)
        #expect(!previous.isCurrent(for: activity))

        let rebuilt = try await processor.process(id: activity.id)
        #expect(rebuilt.isCurrent(for: activity))
        #expect(rebuilt.timeline?.entries == current.timeline?.entries)
        #expect(rebuilt.statistics == current.statistics)
        #expect(rebuilt.timeline?.skiMatches?.entries == [[]])
        #expect(rebuilt.timeline?.skiMatches?.resorts == [])
        #expect(try await repository.storedAnalysis(id: activity.id) == rebuilt)
        #expect(try await repository.recordedTrack(id: activity.id).gpx == track)
    }

    @Test func priorTimelineJSONDecodesWithoutFeatureMatches() throws {
        let data = Data(#"{"entries":[],"breaks":[]}"#.utf8)
        #expect(try JSONDecoder().decode(ActivityTimeline.self, from: data).skiMatches == nil)
    }

    @Test func priorFeatureMatchJSONDecodesWithoutPresentationFields() throws {
        let data = Data(#"{"datasetVersion":"previous","entries":[[]],"resorts":[]}"#.utf8)
        let previous = try JSONDecoder().decode(SkiTimelineMatches.self, from: data)
        #expect(previous.datasetVersion == "previous")
        #expect(previous.entries == [[]])
        #expect(try JSONDecoder().decode(SkiTimelineMatches.self, from: JSONEncoder().encode(previous)) == previous)
    }

    @Test func legacyNamesRatingsAndDistancesAreDiscardedWhileEvidenceAndResortsSurvive() throws {
        let data = Data(#"{"datasetVersion":"legacy","entries":[[{"feature":{"id":"lift","kind":"lift","name":"Ridge Chair","reference":"7","difficulty":"easy","sources":[{"type":"openstreetmap","id":"way/1"}],"resorts":[{"id":"area","name":"North Peak","sources":[]}]},"startedAt":{"millisecondsSince1970":0},"endedAt":{"millisecondsSince1970":10000},"confidence":0.8,"distanceMeters":123.45}]],"resorts":[{"id":"area","name":"North Peak","sources":[]}],"coverage":[{"matchedDistanceMeters":123.45,"totalDistanceMeters":200}]}"#.utf8)
        let previous = try JSONDecoder().decode(SkiTimelineMatches.self, from: data)
        let match = try #require(previous.entries.first?.first)
        #expect(match.feature.id == "lift")
        #expect(match.feature.kind == .lift)
        #expect(match.feature.sources == [SkiFeatureSource(type: "openstreetmap", id: "way/1")])
        #expect(match.startedAt == 0)
        #expect(match.endedAt == 10_000)
        #expect(match.confidence == 0.8)
        #expect(match.feature.resorts == previous.resorts)
        #expect(previous.resorts.first?.displayName == "North Peak")

        let encoded = try JSONEncoder().encode(previous)
        #expect(try JSONDecoder().decode(SkiTimelineMatches.self, from: encoded) == previous)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["coverage"] == nil)
        let entries = try #require(object["entries"] as? [[[String: Any]]])
        let storedMatch = try #require(entries.first?.first)
        #expect(storedMatch["distanceMeters"] == nil)
        let feature = try #require(storedMatch["feature"] as? [String: Any])
        #expect(feature["name"] == nil)
        #expect(feature["reference"] == nil)
        #expect(feature["difficulty"] == nil)
    }

    @Test func bundledPackagesResolveARealAustrianLiftAndItsSkiAreas() throws {
        let directory = try #require(Bundle.main.resourceURL).appendingPathComponent("SkiData")
        let store = try SkiFeatureStore(directory: directory)
        let point = try TrackPoint(timestampMilliseconds: 0, latitude: 47.3192024, longitude: 13.219095, elevationMeters: nil)
        let features = try store.features(for: fixtureGeometry([GPXSegment(points: [point])]))
        let lift = try #require(features.first { $0.identity.sources.contains(SkiFeatureSource(type: "openstreetmap", id: "way/22912867")) })
        #expect(!lift.identity.sources.isEmpty)
        #expect(Set(lift.identity.resorts.compactMap(\.name)) == ["Ski amadé", "Wagrain", "Snow Space Salzburg"])
        #expect(features.allSatisfy { $0.identity.kind == .lift })
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("runs.gpkg").path))
        #expect(!store.datasetVersion.isEmpty)
        #expect(lift.coordinates.count > 2)
    }
}
