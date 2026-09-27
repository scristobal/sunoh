import Foundation
import Synchronization
import SwiftData
import Testing
@testable import Sunoh

private final class Clock: Sendable {
    private let storage = Mutex<Int64>(1_000)
    func set(_ value: Int64) { storage.withLock { $0 = value } }
    func now() -> Int64 { storage.withLock { $0 } }
}

private struct Fixture {
    let directory: URL
    let repository: ActivityRepository
    let clock: Clock
    static func create() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clock = Clock()
        let repository = try await ActivityRepository.open(url: directory.appendingPathComponent("test.store"), clock: clock.now)
        return Fixture(directory: directory, repository: repository, clock: clock)
    }
}

private func point(_ time: Int64, longitude: Double = 11, elevationMeters: Double? = 2_000) -> TrackPoint {
    try! TrackPoint(timestampMilliseconds: time, latitude: 47, longitude: longitude, elevationMeters: elevationMeters)
}

private final class FailingCommit: Sendable {
    private let fails = Mutex(false)
    func fail() { fails.withLock { $0 = true } }
    func save(_ context: ModelContext) throws {
        if fails.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
        try context.save()
    }
}

private final class GPXFixtureBundle: NSObject {}

struct ActivityRepositoryTests {
    #if DEBUG
    @Test func gpxSeedPersistsObservationsAndSkipsDuplicatesAfterReopening() async throws {
        let fixture = try await Fixture.create()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let track = GPXTrack(segments: [GPXSegment(points: [point(10_001), point(20_002, elevationMeters: nil)]),
                                        GPXSegment(points: [point(90_003)])])
        let file = fixture.directory.appendingPathComponent("seed.gpx")
        try GPX.encode(track).write(to: file)
        let result = try await fixture.repository.importSeed(from: file)
        let activity = try #require(result.imported.first)
        #expect(result.imported.count == 1)
        #expect(result.skipped == 0)
        let reopened = try await ActivityRepository.open(url: fixture.directory.appendingPathComponent("test.store"))
        #expect(try await reopened.recordedTrack(id: activity.id).gpx == track)
        let repeated = try await reopened.importSeed(from: file)
        #expect(repeated.imported.isEmpty)
        #expect(repeated.skipped == 1)
    }

    @Test func gpxSeedRejectsInvalidInputAndPreservesAnOpenRecording() async throws {
        let fixture = try await Fixture.create()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let file = fixture.directory.appendingPathComponent("seed.gpx")
        try Data("not GPX".utf8).write(to: file)
        await #expect(throws: GPXError.self) { try await fixture.repository.importSeed(from: file) }
        let legacy = fixture.directory.appendingPathComponent("seed.jsonl")
        await #expect(throws: GPXError.self) { try await fixture.repository.importSeed(from: legacy) }
        #expect(try await fixture.repository.summaries().isEmpty)
        let active = try await fixture.repository.start()
        let track = GPXTrack(segments: [GPXSegment(points: [point(10_001)])])
        try GPX.encode(track).write(to: file)
        await #expect(throws: ActivityError.self) { try await fixture.repository.importSeed(from: file) }
        #expect(try await fixture.repository.active()?.id == active.id)
        #expect(try await fixture.repository.summaries().isEmpty)
    }
    #endif

    @Test @MainActor func exportsAllSavedTracksWithoutEmptyActivitiesOrChangingTheActiveRecording() async throws {
        let fixture = try await Fixture.create()
        let store = RecordingController(repository: fixture.repository)
        let library = ActivityLibrary(repository: fixture.repository)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        await library.reloadHistory()
        #expect(!library.canExportAllGPX)
        await #expect(throws: GPXError.self) { try await library.exportAllGPX() }
        let first = GPXTrack(segments: [GPXSegment(points: [point(10_001), point(20_001, elevationMeters: nil)])])
        let second = GPXTrack(segments: [GPXSegment(points: [point(30_001)]), GPXSegment(points: [point(90_001)])])
        _ = try await library.importTracks([first, second])
        let empty = try await fixture.repository.start()
        _ = try await fixture.repository.pause(id: empty.id)
        _ = try await fixture.repository.finish(id: empty.id)
        let active = try await fixture.repository.start()
        _ = try await fixture.repository.append([point(1_001)], activityID: active.id)
        try await store.restore()
        await library.reloadHistory()
        let before = try await fixture.repository.summaries()
        let activeBefore = try await fixture.repository.active()
        #expect(library.canExportAllGPX)
        let file = try await library.exportAllGPX()
        defer { file.removeTemporaryFile() }
        #expect(try await GPXFiles.read(file.url) == [second, first])
        #expect(try await fixture.repository.summaries() == before)
        #expect(try await fixture.repository.active() == activeBefore)
        #expect(store.recordingState == .recording)
        let target = try await Fixture.create()
        let imported = try await ActivityLibrary(repository: target.repository).importGPX(from: file.url)
        #expect(imported.imported.count == 2)
        #expect(imported.imported.map(\.pointCount) == [2, 2])
    }

    @Test @MainActor func onlyEmptySavedActivitiesCannotBeExported() async throws {
        let fixture = try await Fixture.create()
        let empty = try await fixture.repository.start()
        _ = try await fixture.repository.pause(id: empty.id)
        _ = try await fixture.repository.finish(id: empty.id)
        let store = RecordingController(repository: fixture.repository)
        let library = ActivityLibrary(repository: fixture.repository)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        await library.reloadHistory()
        #expect(!library.canExportAllGPX)
        await #expect(throws: GPXError.self) { try await library.exportAllGPX() }
        #expect(try await fixture.repository.summaries().count == 1)
    }

    @Test @MainActor func importsTheBundledSkiDayThroughTheFileAndStoreFlow() async throws {
        let url = try #require(Bundle(for: GPXFixtureBundle.self).url(forResource: "SkiDay", withExtension: "gpx"))
        let fixture = try await Fixture.create()
        let store = RecordingController(repository: fixture.repository)
        let library = ActivityLibrary(repository: fixture.repository)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        await library.reloadHistory()
        let result = try await library.importGPX(from: url)
        let activity = try #require(result.imported.first)
        #expect(activity.pointCount == 8)
        let track = try await fixture.repository.recordedTrack(id: activity.id).gpx
        #expect(track.segments.count == 2)
        #expect(track.segments[1].points[2].elevationMeters == nil)
        #expect(try await library.importGPX(from: url).skipped == 1)
        let file = try await library.exportGPX(id: activity.id)
        defer { file.removeTemporaryFile() }
        #expect(try await GPXFiles.read(file.url) == [track])
        let thumbnail = try #require(await library.thumbnail(id: activity.id))
        #expect(await library.thumbnail(id: activity.id) == thumbnail)
        #expect(try await fixture.repository.recordedTrack(id: activity.id).gpx == track)
        try await library.delete(id: activity.id)
        #expect(await library.thumbnail(id: activity.id) == nil)
    }

    @Test func failedImportCommitRollsBackEveryTrackAndPreservesRecordingsAfterReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("test.store")
        let commit = FailingCommit()
        let repository = try await ActivityRepository.open(url: url, clock: { 1_000 }, commit: commit.save)
        let savedID = try await repository.start().id
        _ = try await repository.append([point(1_001)], activityID: savedID)
        _ = try await repository.pause(id: savedID)
        _ = try await repository.finish(id: savedID)
        let active = try await repository.start()
        let original = try await repository.recordedTrack(id: savedID).gpx

        commit.fail()
        let tracks = [2_001, 3_001].map { GPXTrack(segments: [GPXSegment(points: [point(Int64($0))])]) }
        await #expect(throws: ActivityError.self) { try await repository.importTracks(tracks) }
        #expect(try await repository.summaries().map(\.id) == [savedID])
        #expect(try await repository.active() == active)
        let reopened = try await ActivityRepository.open(url: url)
        #expect(try await reopened.summaries().map(\.id) == [savedID])
        #expect(try await reopened.recordedTrack(id: savedID).gpx == original)
        #expect(try await reopened.active() == active)
        #expect(try await reopened.importTracks(tracks).imported.count == 2)
    }

    @Test func gpxRoundTripPreservesStoredSamplesAndSourceBoundaries() async throws {
        let f = try await Fixture.create()
        let id = try await f.repository.start().id
        _ = try await f.repository.append([point(1_001), point(61_001, longitude: 11.001, elevationMeters: nil)], activityID: id)
        _ = try await f.repository.pause(id: id)
        f.clock.set(62_000)
        _ = try await f.repository.resume(id: id)
        _ = try await f.repository.append([point(62_001)], activityID: id)
        _ = try await f.repository.pause(id: id)
        _ = try await f.repository.finish(id: id)
        let original = try await f.repository.recordedTrack(id: id).gpx
        #expect(original.segments.count == 2)
        #expect(try await f.repository.geometry(id: id).sections.count == 2)

        let destination = try await Fixture.create()
        let decoded = try GPX.decode(GPX.encode(original))
        let result = try await destination.repository.importTracks(decoded)
        let imported = try #require(result.imported.first)
        #expect(imported.pointCount == 3)
        #expect(try await destination.repository.recordedTrack(id: imported.id).gpx == original)
        let reopened = try await ActivityRepository.open(url: destination.directory.appendingPathComponent("test.store"))
        #expect(try await reopened.recordedTrack(id: imported.id).gpx == original)
    }

    @Test func repeatedGPXImportsSkipIdenticalTracksIncludingNativeRecordings() async throws {
        let f = try await Fixture.create()
        let id = try await f.repository.start().id
        _ = try await f.repository.append([point(1_001)], activityID: id)
        _ = try await f.repository.pause(id: id)
        _ = try await f.repository.finish(id: id)
        let native = try await f.repository.recordedTrack(id: id).gpx
        let another = GPXTrack(segments: [GPXSegment(points: [point(3_001)])])
        let result = try await f.repository.importTracks([native, another, another])
        #expect(result.imported.count == 1)
        #expect(result.skipped == 2)
        let retry = try await f.repository.importTracks([another])
        #expect(retry.imported.isEmpty)
        #expect(retry.skipped == 1)
        #expect(try await f.repository.summaries().count == 2)
        #expect(try await f.repository.recordedTrack(id: id).gpx == native)
    }

    @Test func importingMultipleTracksPreservesTheActiveRecordingAndRejectsAnInvalidFileAtomically() async throws {
        let f = try await Fixture.create()
        let active = try await f.repository.start().id
        _ = try await f.repository.append([point(1_001)], activityID: active)
        let before = try await f.repository.active()
        let first = GPXTrack(segments: [GPXSegment(points: [point(10_001)])])
        let second = GPXTrack(segments: [GPXSegment(points: [point(20_001, elevationMeters: nil)])])
        let result = try await f.repository.importTracks([first, second])
        #expect(result.imported.count == 2)
        #expect(try await f.repository.active() == before)
        _ = try await f.repository.append([point(1_002)], activityID: active)
        #expect(try await f.repository.active()?.summary.pointCount == 2)
        // Source tracks remain readable while recording; export separately requires completion.
        #expect(try await f.repository.recordedTrack(id: active).segments.count == 1)

        let third = GPXTrack(segments: [GPXSegment(points: [point(30_001)])])
        let invalid = GPXTrack(segments: [GPXSegment(points: [point(40_001), point(40_001)])])
        await #expect(throws: GPXError.self) { try await f.repository.importTracks([third, invalid]) }
        #expect(try await f.repository.summaries().count == 2)
        #expect(try await f.repository.active()?.summary.pointCount == 2)
    }

    @Test func canceledImportDoesNotSaveOrPoisonTheRepository() async throws {
        let f = try await Fixture.create()
        let track = GPXTrack(segments: [GPXSegment(points: [point(1_001)])])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { try await f.repository.importTracks([track]) }
        }
        await task.value
        #expect(try await f.repository.summaries().isEmpty)
        #expect(try await f.repository.importTracks([track]).imported.count == 1)
    }

    @Test func lifecycleSurvivesReopeningAndPreservesPauseBoundaries() async throws {
        let f = try await Fixture.create()
        let start = try await f.repository.start()
        #expect(try await f.repository.start().id == start.id)
        _ = try await f.repository.append([point(1_001)], activityID: start.id)
        f.clock.set(1_005)
        _ = try await f.repository.pause(id: start.id)
        let reopened = try await ActivityRepository.open(url: f.directory.appendingPathComponent("test.store"), clock: f.clock.now)
        #expect(try await reopened.active()?.phase == .paused)
        #expect(try await reopened.active()?.summary.pointCount == 1)
        f.clock.set(1_010)
        _ = try await reopened.resume(id: start.id)
        _ = try await reopened.append([point(1_011)], activityID: start.id)
        _ = try await reopened.pause(id: start.id)
        let saved = try await reopened.finish(id: start.id)
        #expect(saved.pointCount == 2)
        #expect(try await reopened.active() == nil)
        let details = try await reopened.details(id: start.id)
        #expect(details.geometry.sections.count == 2)
        #expect(ActivityStatistics(activity: details.activity, geometry: details.geometry).distanceMeters == 0)
        #expect(try await reopened.summaries().map(\.id) == [start.id])
    }

    @Test func retriesAreIdempotentAndConflictsRollBackTheWholeBatch() async throws {
        let f = try await Fixture.create()
        let id = try await f.repository.start().id
        _ = try await f.repository.append([point(1_001), point(1_001)], activityID: id)
        _ = try await f.repository.append([point(1_001)], activityID: id)
        await #expect(throws: ActivityError.self) {
            try await f.repository.append([point(1_002), point(1_001, longitude: 12)], activityID: id)
        }
        #expect(try await f.repository.active()?.summary.pointCount == 1)
        let route = try await f.repository.geometry(id: id)
        #expect(route.sections.flatMap(\.points).map(\.timestampMilliseconds) == [1_001])
    }

    @Test func pauseAcceptsQueuedPointsButRejectsOutsideTheInterval() async throws {
        let f = try await Fixture.create()
        let id = try await f.repository.start().id
        f.clock.set(1_010)
        _ = try await f.repository.pause(id: id)
        _ = try await f.repository.append([point(1_005)], activityID: id)
        await #expect(throws: ActivityError.self) { try await f.repository.append([point(1_011)], activityID: id) }
        f.clock.set(1_020)
        _ = try await f.repository.resume(id: id)
        await #expect(throws: ActivityError.self) { try await f.repository.append([point(1_015)], activityID: id) }
        #expect(try await f.repository.active()?.summary.pointCount == 1)
    }

    @Test func delayedSamplesAreIncludedEvenWhenLatestTimestampDoesNotChange() async throws {
        let f = try await Fixture.create()
        let id = try await f.repository.start().id
        _ = try await f.repository.append([point(1_010), point(1_030)], activityID: id)
        _ = try await f.repository.append([point(1_020)], activityID: id)
        let route = try await f.repository.geometry(id: id)
        #expect(route.sections.flatMap(\.points).map(\.timestampMilliseconds) == [1_010, 1_020, 1_030])
    }

    @Test func discardRemovesTheRecordingAndPointsWithoutSavingAnActivity() async throws {
        let f = try await Fixture.create()
        let id = try await f.repository.start().id
        _ = try await f.repository.append([point(1_001)], activityID: id)
        _ = try await f.repository.pause(id: id)
        try await f.repository.discard(id: id)
        #expect(try await f.repository.active() == nil)
        #expect(try await f.repository.summaries().isEmpty)
        await #expect(throws: ActivityError.self) { try await f.repository.details(id: id) }
    }

    @Test func deletingAnActivityPreservesItsNeighbours() async throws {
        let f = try await Fixture.create()
        let first = try await f.repository.start().id
        _ = try await f.repository.pause(id: first)
        _ = try await f.repository.finish(id: first)
        let second = try await f.repository.start().id
        _ = try await f.repository.append([point(1_001)], activityID: second)
        _ = try await f.repository.pause(id: second)
        _ = try await f.repository.finish(id: second)
        try await f.repository.delete(id: first)
        #expect(try await f.repository.summaries().map(\.id) == [second])
        #expect(try await f.repository.details(id: second).activity.pointCount == 1)
    }

    @Test func invalidPointsDoNotChangeMetadata() async throws {
        let f = try await Fixture.create()
        _ = try await f.repository.start()
        #expect(throws: ActivityError.self) {
            try TrackPoint(timestampMilliseconds: 1_001, latitude: 47, longitude: .nan, elevationMeters: nil)
        }
        #expect(try await f.repository.active()?.summary.pointCount == 0)
    }

    @Test func statisticsRespectSourceBoundariesAndMissingElevation() {
        let summary = ActivitySummary(id: "stats", startedAt: 1_000, lastPointAt: 61_000, pointCount: 4)
        let p: (Double, Double?) -> TrackPoint = { lon, elevationMeters in
            try! TrackPoint(timestampMilliseconds: 1_001, latitude: 0, longitude: lon, elevationMeters: elevationMeters)
        }
        let stats = ActivityStatistics(activity: summary, geometry: fixtureGeometry([
            GPXSegment(points: [p(0, 100), p(1, 120), p(2, nil)]), GPXSegment(points: [p(90, 1_000)])
        ]))
        #expect(abs(stats.distanceMeters - 222_389.853) < 0.1)
        #expect(stats.elevationGainMeters == 20)
        #expect(stats.elevationLossMeters == 0)
        #expect(stats.elapsedDurationMilliseconds == 60_000)
        #expect(stats.maximumElevationMeters == 1_000)
    }
}
