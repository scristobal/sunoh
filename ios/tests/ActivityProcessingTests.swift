import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Sunoh

private let processingTrack = GPXTrack(segments: [
    GPXSegment(points: [try! TrackPoint(timestampMilliseconds: 1_001, latitude: 47, longitude: 11, elevationMeters: 2_000),
                   try! TrackPoint(timestampMilliseconds: 2_001, latitude: 47.001, longitude: 11.001, elevationMeters: 2_010)]),
    GPXSegment(points: [try! TrackPoint(timestampMilliseconds: 40_001, latitude: 47.002, longitude: 11.002, elevationMeters: nil)])
])

private func processingURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("processing.store")
}

private func persistedResults(_ url: URL) async throws -> [ActivityAnalysis] {
    try await Task.detached {
        let context = ModelContext(try ActivityDatabase.container(at: url))
        return try context.fetch(FetchDescriptor<StoredActivityAnalysis>()).map { try $0.result() }
    }.value
}

private final class ProcessingCommit: Sendable {
    private let failure = Mutex(false)
    private let count = Mutex(0)
    var saves: Int { count.withLock { $0 } }
    func failNext() { failure.withLock { $0 = true } }
    func save(_ context: ModelContext) throws {
        let fail = failure.withLock { value in
            defer { value = false }
            return value
        }
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
        try context.save()
        count.withLock { $0 += 1 }
    }
}

struct ActivityProcessingTests {
    @Test func statisticsAndPNGSurviveReopenWithoutAnotherWrite() async throws {
        let url = try processingURL()
        let commit = ProcessingCommit()
        let repository = try await ActivityRepository.open(url: url, clock: { 50_000 }, commit: commit.save)
        let imported = try await repository.importTracks([processingTrack])
        let summary = try #require(imported.imported.first)
        let processor = ActivityProcessor(repository: repository, clock: { 50_000 })
        let saves = commit.saves
        async let first = processor.process(id: summary.id)
        async let second = processor.process(id: summary.id)
        let (result, concurrent) = try await (first, second)
        #expect(result == concurrent)
        #expect(commit.saves == saves + 1)
        #expect(result.processedAt == 50_000)
        #expect(result.processingVersion == ActivityAnalysis.currentProcessingVersion)
        #expect(result.thumbnailPNG?.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) == true)
        #expect(result.statistics.distanceMeters > 0)
        #expect(result.statistics.elevationGainMeters == 10)
        #expect(try await persistedResults(url) == [result])

        let reopened = try await ActivityRepository.open(url: url, clock: { 99_000 }, commit: { _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        let reopenedProcessor = ActivityProcessor(repository: reopened)
        #expect(try await reopenedProcessor.process(id: summary.id) == result)
        #expect(try await reopened.details(id: summary.id).activity == summary)
        #expect(try await reopened.recordedTrack(id: summary.id).gpx == processingTrack)
        #expect(try await reopened.summaries() == [summary])
    }

    @Test func failedProcessingCommitRemainsRetryableAndDoesNotBlockRecording() async throws {
        let url = try processingURL()
        let commit = ProcessingCommit()
        let repository = try await ActivityRepository.open(url: url, clock: { 1_000 }, commit: commit.save)
        let summary = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let processor = ActivityProcessor(repository: repository)
        commit.failNext()
        await #expect(throws: CocoaError.self) { try await processor.process(id: summary.id) }
        #expect(try await persistedResults(url).isEmpty)
        #expect(try await repository.summaries() == [summary])
        #expect(try await repository.recordedTrack(id: summary.id).gpx == processingTrack)
        let active = try await repository.start()
        _ = try await repository.append([processingTrack.segments[0].points[0]], activityID: active.id)
        let retry = try await processor.process(id: summary.id)
        #expect(retry.thumbnailPNG != nil)
        #expect(try await persistedResults(url) == [retry])
        #expect(try await repository.active()?.summary.pointCount == 1)
    }

    @Test func olderProcessingVersionIsReplacedAtomicallyAndDeletedWithItsActivity() async throws {
        let url = try processingURL()
        let repository = try await ActivityRepository.open(url: url, clock: { 50_000 })
        let summary = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let stale = ActivityAnalysis(activityID: summary.id, sourceRevision: summary.sourceRevision, processingVersion: 0, processedAt: 10,
                                     statistics: ActivityStatistics(),
                                     thumbnailPNG: Data([0]))
        try await Task.detached {
            let context = ModelContext(try ActivityDatabase.container(at: url))
            let activity = try #require(context.fetch(FetchDescriptor<StoredActivity>()).first)
            context.insert(StoredActivityAnalysis(stale, activity: activity))
            try context.save()
        }.value
        let commit = ProcessingCommit()
        let reopened = try await ActivityRepository.open(url: url, clock: { 60_000 }, commit: commit.save)
        let reopenedProcessor = ActivityProcessor(repository: reopened, clock: { 60_000 })
        commit.failNext()
        await #expect(throws: CocoaError.self) { try await reopenedProcessor.process(id: summary.id) }
        #expect(try await persistedResults(url) == [stale])
        let updated = try await reopenedProcessor.process(id: summary.id)
        #expect(updated.processingVersion == ActivityAnalysis.currentProcessingVersion)
        #expect(updated.processedAt == 60_000)
        #expect(updated.statistics.distanceMeters > 0)
        #expect(try await persistedResults(url) == [updated])
        #expect(try await reopened.recordedTrack(id: summary.id).gpx == processingTrack)
        try await reopened.delete(id: summary.id)
        #expect(try await persistedResults(url).isEmpty)
        await #expect(throws: ActivityError.self) { try await reopenedProcessor.process(id: summary.id) }
        #expect(try await reopened.summaries().isEmpty)
    }

    @Test @MainActor func savingAndImportingProcessWithoutOpeningActivityViews() async throws {
        let url = try processingURL()
        let repository = try await ActivityRepository.open(url: url, clock: { 1_000 })
        let store = RecordingController(repository: repository)
        let library = ActivityLibrary(repository: repository)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        await library.reloadHistory()
        await store.startRecording()
        store.record([try! TrackPoint(timestampMilliseconds: 1_000, latitude: 47, longitude: 11, elevationMeters: 2_000)])
        await store.pauseRecording()
        await store.finishRecording()
        await library.processingTask?.value
        let saved = try #require(try await repository.summaries().first)
        #expect(try await persistedResults(url).map(\.activityID) == [saved.id])
        #expect(library.processingFailures.isEmpty)
        let imported = try #require(try await library.importTracks([processingTrack]).imported.first)
        await library.processingTask?.value
        let results = try await persistedResults(url)
        #expect(Set(results.map(\.activityID)) == Set([saved.id, imported.id]))
        #expect(results.allSatisfy { $0.thumbnailPNG != nil })
        #expect(store.storageError == nil)
    }

    @Test @MainActor func historyRefreshRetriesProcessingFailureWithoutAffectingRecording() async throws {
        let url = try processingURL()
        let commit = ProcessingCommit()
        let repository = try await ActivityRepository.open(url: url, clock: { 1_000 }, commit: commit.save)
        let saved = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let active = try await repository.start()
        let store = RecordingController(repository: repository)
        let library = ActivityLibrary(repository: repository)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        commit.failNext()
        await library.reloadHistory()
        await library.processingTask?.value
        #expect(library.processingFailures[saved.id] != nil)
        #expect(store.storageError == nil)
        #expect(store.recordingState == .recording)
        #expect(try await persistedResults(url).isEmpty)
        await library.reloadHistory()
        await library.processingTask?.value
        #expect(library.processingFailures.isEmpty)
        #expect(try await persistedResults(url).map(\.activityID) == [saved.id])
        #expect(try await repository.active() == active)
    }

    @Test func processingFailureLeavesOriginalDetailsAvailable() async throws {
        let repository = try await ActivityRepository.open(url: processingURL())
        let saved = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let processor = ActivityProcessor(repository: repository, calculate: { _ in throw ActivityProcessingError.thumbnail })
        await #expect(throws: ActivityProcessingError.self) { try await processor.process(id: saved.id) }
        let details = try await repository.details(id: saved.id)
        #expect(details.activity == saved)
        #expect(details.geometry.sections.flatMap(\.points) == processingTrack.segments.flatMap(\.points))
        #expect(try await repository.storedAnalysis(id: saved.id) == nil)
    }

    @Test func deletionDuringProcessingCannotRecreateAnActivity() async throws {
        let url = try processingURL()
        let repository = try await ActivityRepository.open(url: url)
        let saved = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let gate = CalculationGate()
        let processor = ActivityProcessor(repository: repository, calculate: { _ in
            await gate.suspend()
            return (ActivityStatistics(), Data([1]))
        })
        let processing = Task { try await processor.process(id: saved.id) }
        await gate.waitUntilStarted()
        try await repository.delete(id: saved.id)
        await gate.release()
        do { _ = try await processing.value; Issue.record("Deleted activity accepted late analysis") }
        catch { #expect(error is ActivityError) }
        #expect(try await repository.summaries().isEmpty)
        #expect(try await persistedResults(url).isEmpty)
    }

    @Test func wrongSourceRevisionCannotReplaceCommittedAnalysis() async throws {
        let repository = try await ActivityRepository.open(url: processingURL())
        let saved = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let original = try await ActivityProcessor(repository: repository).process(id: saved.id)
        let stale = ActivityAnalysis(activityID: saved.id, sourceRevision: saved.sourceRevision - 1,
            processingVersion: ActivityAnalysis.currentProcessingVersion, processedAt: 1, statistics: ActivityStatistics(), thumbnailPNG: nil)
        await #expect(throws: ActivityError.self) { try await repository.saveAnalysis(stale) }
        #expect(try await repository.storedAnalysis(id: saved.id) == original)
    }

    @Test func emptyCompletedActivityHasPersistedStatisticsWithoutPNG() async throws {
        let url = try processingURL()
        let repository = try await ActivityRepository.open(url: url, clock: { 1_000 })
        let active = try await repository.start()
        _ = try await repository.pause(id: active.id)
        _ = try await repository.finish(id: active.id)
        let processor = ActivityProcessor(repository: repository)
        let result = try await processor.process(id: active.id)
        #expect(result.thumbnailPNG == nil)
        #expect(result.statistics.elapsedDurationMilliseconds == 0)
        #expect(try await persistedResults(url) == [result])
    }
}

private actor CalculationGate {
    private var started = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var calculation: CheckedContinuation<Void, Never>?
    func suspend() async {
        started = true; waiting?.resume(); waiting = nil
        await withCheckedContinuation { calculation = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { calculation?.resume(); calculation = nil }
}
