import Foundation
import Testing
import Synchronization
@testable import Sunoh

/// Delays/failures around the real repository preserve its domain invariants.
actor ControlledActivities: ActivityPersistence {
    private let repository: ActivityRepository
    private let clock: ControlledClock
    private var historyFails = false
    private var geometryFails = false
    private var writesFail = false
    private var blockWrite = false
    private var writeStarted = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var blockedOperation: RecordingOperation?
    private var failingOperation: RecordingOperation?
    private var operationStarted = false
    private var operationWaiter: CheckedContinuation<Void, Never>?
    private var operationRelease: CheckedContinuation<Void, Never>?
    private var blockAnalysisRead = false
    private var analysisReadStarted = false
    private var analysisReadWaiter: CheckedContinuation<Void, Never>?
    private var analysisReadRelease: CheckedContinuation<Void, Never>?

    init(repository: ActivityRepository, clock: ControlledClock) { self.repository = repository; self.clock = clock }
    static func create() async throws -> ControlledActivities {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clock = ControlledClock()
        return ControlledActivities(repository: try await ActivityRepository.open(url: directory.appendingPathComponent("test.store"), clock: clock.now), clock: clock)
    }
    func advanceClock(by milliseconds: Int64) { clock.advance(by: milliseconds) }
    func failHistory() { historyFails = true }
    func failGeometry() { geometryFails = true }
    func failWrites() { writesFail = true }
    func blockNextWrite() { blockWrite = true }
    func waitForWrite() async {
        if writeStarted { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func releaseWrite() { release?.resume(); release = nil }
    func blockOperation(_ operation: RecordingOperation) { blockedOperation = operation }
    func failOperation(_ operation: RecordingOperation) { failingOperation = operation }
    func waitForOperation() async {
        if operationStarted { return }
        await withCheckedContinuation { operationWaiter = $0 }
    }
    func releaseOperation() { operationRelease?.resume(); operationRelease = nil }
    func blockNextStoredAnalysis() { blockAnalysisRead = true; analysisReadStarted = false }
    func waitForStoredAnalysis() async {
        if analysisReadStarted { return }
        await withCheckedContinuation { analysisReadWaiter = $0 }
    }
    func releaseStoredAnalysis() { analysisReadRelease?.resume(); analysisReadRelease = nil }
    private func perform(_ operation: RecordingOperation) async throws {
        if blockedOperation == operation {
            blockedOperation = nil; operationStarted = true
            operationWaiter?.resume(); operationWaiter = nil
            await withCheckedContinuation { operationRelease = $0 }
        }
        if failingOperation == operation { throw ActivityError.storage("Injected operation failure") }
    }
    func start() async throws -> ActiveRecording { try await perform(.starting); return try await repository.start() }
    func active() async throws -> ActiveRecording? { try await perform(.restoring); return try await repository.active() }
    func stop(id: ActivityID) async throws -> ActiveRecording { try await perform(.stopping); clock.advance(); return try await repository.stop(id: id) }
    func finish(id: ActivityID) async throws -> ActivitySummary { try await perform(.saving); return try await repository.finish(id: id) }
    func discard(id: ActivityID) async throws { try await perform(.discarding); try await repository.discard(id: id) }
    func append(_ points: [TrackPoint], activityID: ActivityID) async throws -> ActiveRecording {
        if blockWrite {
            blockWrite = false; writeStarted = true
            startWaiter?.resume(); startWaiter = nil
            await withCheckedContinuation { release = $0 }
        }
        if writesFail { throw ActivityError.storage("Injected terminal failure") }
        return try await repository.append(points, activityID: activityID)
    }
    func summaries() async throws -> [ActivitySummary] {
        if historyFails { throw ActivityError.missing }
        return try await repository.summaries()
    }
    func summary(id: ActivityID) async throws -> ActivitySummary { try await repository.summary(id: id) }
    func geometry(id: ActivityID) async throws -> TrackGeometry {
        if geometryFails { throw ActivityError.missing }
        return try await repository.geometry(id: id)
    }
    func details(id: ActivityID) async throws -> ActivityDetails { try await repository.details(id: id) }
    func recordedTrack(id: ActivityID) async throws -> RecordedTrack { try await repository.recordedTrack(id: id) }
    func storedAnalysis(id: ActivityID) async throws -> ActivityAnalysis? {
        if blockAnalysisRead {
            blockAnalysisRead = false; analysisReadStarted = true
            analysisReadWaiter?.resume(); analysisReadWaiter = nil
            await withCheckedContinuation { analysisReadRelease = $0 }
        }
        return try await repository.storedAnalysis(id: id)
    }
    func processingInput(id: ActivityID) async throws -> ActivityProcessingInput { try await repository.processingInput(id: id) }
    func saveAnalysis(_ result: ActivityAnalysis) async throws { try await repository.saveAnalysis(result) }
    func importTracks(_ tracks: [GPXTrack]) async throws -> GPXImportResult {
        if writesFail { throw ActivityError.storage("Injected terminal failure") }
        return try await repository.importTracks(tracks)
    }
    func delete(id: ActivityID) async throws { try await repository.delete(id: id) }
}

final class ControlledClock: Sendable {
    private let value = Mutex<Int64>(1_000)
    func now() -> Int64 { value.withLock { $0 } }
    func advance(by milliseconds: Int64 = 1_000) { value.withLock { $0 += milliseconds } }
}
