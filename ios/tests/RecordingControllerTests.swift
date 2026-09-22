import Foundation
import Observation
import Testing
@testable import Sunoh

@MainActor struct RecordingControllerTests {
    @Test func thumbnailFailureDoesNotChangeRecordingHealth() async throws {
        let db = try await ControlledActivities.create()
        let store = RecordingController(repository: db)
        let library = ActivityLibrary(repository: db)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        await store.startRecording()
        await db.failGeometry()
        #expect(await library.thumbnail(id: "missing") == nil)
        #expect(store.storageError == nil)
        #expect(store.recordingStatus == .recording)
    }

    @Test func importPublishesSavedActivitiesWithoutChangingRecordingStatus() async throws {
        let db = try await ControlledActivities.create()
        let store = RecordingController(repository: db)
        let library = ActivityLibrary(repository: db)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        await library.reloadHistory()
        await store.startRecording()
        let active = store.currentRecording
        let result = try await library.importTracks([GPXTrack(segments: [GPXSegment(points: [sample(10_001)])])])
        #expect(result.imported.count == 1)
        #expect(store.currentRecording == active)
        #expect(store.recordingStatus == .recording)
        guard case .loaded(let history) = library.history else { Issue.record("Expected imported history"); return }
        #expect(history.count == 1)
        store.record([sample(1_001)])
        await store.pauseRecording()
        #expect(store.pointCount == 1)
    }

    @Test func importValidationDoesNotStopRecordingButPersistenceFailureIsVisible() async throws {
        let db = try await ControlledActivities.create()
        let store = RecordingController(repository: db)
        let library = ActivityLibrary(repository: db)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        await library.reloadHistory()
        await store.startRecording()
        await #expect(throws: GPXError.self) { try await library.importTracks([GPXTrack(segments: [])]) }
        #expect(store.recordingStatus == .recording)
        #expect(store.storageError == nil)
        await db.failWrites()
        await #expect(throws: ActivityError.self) {
            try await library.importTracks([GPXTrack(segments: [GPXSegment(points: [sample(10_001)])])])
        }
        #expect(store.requiresRestart)
        #expect(store.recordingStatus == .unavailable)
        guard case .loaded(let history) = library.history else { Issue.record("Expected unchanged history"); return }
        #expect(history.isEmpty)
    }

    @Test func readinessWaitsForStorageToLoad() async throws {
        let db = try await ControlledActivities.create()
        let store = RecordingController(repository: db)
        let library = ActivityLibrary(repository: db)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        #expect(store.recordingStatus == .working(.restoring))
        await db.blockOperation(.restoring)
        let restore = Task { try await store.restore() }
        await db.waitForOperation()
        #expect(store.recordingStatus == .working(.restoring))
        await db.releaseOperation()
        try await restore.value
        #expect(store.recordingStatus == .ready)
    }

    @Test(arguments: [RecordingOperation.starting, .pausing, .resuming, .saving, .discarding])
    func statusFollowsTheEntireRecordingOperation(_ operation: RecordingOperation) async throws {
        let db = try await ControlledActivities.create()
        let store = RecordingController(repository: db, saveFeedback: .init(minimumDuration: .zero))
        let library = ActivityLibrary(repository: db)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        if operation != .starting { await store.startRecording() }
        if [.resuming, .saving, .discarding].contains(operation) { await store.pauseRecording() }

        await db.blockOperation(operation)
        let change = Task {
            switch operation {
            case .starting: await store.startRecording()
            case .pausing: await store.pauseRecording()
            case .resuming: await store.resumeRecording()
            case .saving: await store.finishRecording()
            case .discarding: await store.discardRecording()
            case .restoring: Issue.record("Restoration is tested separately")
            }
        }
        await db.waitForOperation()
        #expect(store.recordingStatus == .working(operation))
        #expect(store.isChangingRecording)
        await db.releaseOperation()
        await change.value

        let expected: RecordingStatus = switch operation {
        case .starting, .resuming: .recording
        case .pausing: .paused
        case .saving, .discarding: .ready
        case .restoring: .ready
        }
        #expect(store.recordingStatus == expected)
        #expect(!store.isChangingRecording)
    }

    @Test func failedRestorationIsUnavailableInsteadOfReadyOrWorking() async throws {
        let db = try await ControlledActivities.create()
        await db.failOperation(.restoring)
        let store = RecordingController(repository: db)
        let library = ActivityLibrary(repository: db)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        await #expect(throws: ActivityError.self) { try await store.restore() }
        #expect(store.recordingStatus == .unavailable)
    }

    @Test func failedSaveKeepsTheRecordingAndEndsWorkingStatus() async throws {
        let db = try await ControlledActivities.create()
        let feedback = RecordingSaveFeedback()
        let store = RecordingController(repository: db, saveFeedback: feedback)
        let library = ActivityLibrary(repository: db)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        await store.startRecording()
        await store.pauseRecording()
        let id = store.currentActivity?.id
        await db.failOperation(.saving)
        await store.finishRecording()
        #expect(store.currentActivity?.id == id)
        #expect(store.operation == nil)
        #expect(store.recordingStatus == .unavailable)
        #expect(!feedback.isVisible)
    }

    @Test func fastSaveKeepsSharedFeedbackWithoutDelayingTheCommittedResult() async throws {
        let db = try await ControlledActivities.create()
        let timer = FeedbackTimer()
        let feedback = RecordingSaveFeedback { await timer.sleep(for: $0) }
        let store = RecordingController(repository: db, saveFeedback: feedback)
        let library = ActivityLibrary(repository: db)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        await store.startRecording()
        await store.pauseRecording()
        await store.finishRecording()
        await timer.waitForSleep()

        #expect(timer.duration == .seconds(2))
        #expect(store.operation == nil)
        #expect(store.currentActivity == nil)
        guard case .loaded(let history) = library.history else { Issue.record("Expected saved activity"); return }
        #expect(history.count == 1)
        #expect(store.recordingStatus == .working(.saving))
        #expect(store.recordingStatus.withLocationReadiness(false) == .working(.saving))

        timer.advance()
        for await status in Observations({ store.recordingStatus }) {
            if status == .ready { break }
        }
        #expect(!feedback.isVisible)
        #expect(store.recordingStatus.withLocationReadiness(false) == .locationNotReady)
    }

    @Test func slowSaveKeepsWorkingAfterTheMinimumFeedbackExpires() async throws {
        let db = try await ControlledActivities.create()
        let timer = FeedbackTimer()
        let feedback = RecordingSaveFeedback { await timer.sleep(for: $0) }
        let store = RecordingController(repository: db, saveFeedback: feedback)
        let library = ActivityLibrary(repository: db)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        await store.startRecording()
        await store.pauseRecording()
        await db.blockOperation(.saving)
        let save = Task { await store.finishRecording() }
        await db.waitForOperation()
        await timer.waitForSleep()

        timer.advance()
        for await visible in Observations({ feedback.isVisible }) {
            if !visible { break }
        }
        #expect(store.recordingStatus == .working(.saving))
        #expect(store.currentActivity != nil)
        await db.releaseOperation()
        await save.value
        #expect(store.recordingStatus == .ready)
    }

    @Test func historyFailureDoesNotBlockRecording() async throws {
        let db = try await ControlledActivities.create()
        await db.failHistory()
        let store = RecordingController(repository: db)
        let library = ActivityLibrary(repository: db)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        await library.reloadHistory()
        guard case .failed = library.history else { Issue.record("Expected history error"); return }
        #expect(store.recordingStatus == .ready)
        await store.startRecording()
        #expect(store.recordingState == .recording)
        #expect(store.recordingStatus == .recording)
        #expect(store.storageError == nil)
    }

    @Test func geometryFailureDoesNotStopPointWrites() async throws {
        let db = try await ControlledActivities.create()
        await db.failGeometry()
        let store = RecordingController(repository: db, geometryRefreshInterval: .zero)
        let library = ActivityLibrary(repository: db)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        await store.startRecording()
        store.record([sample(1_001)])
        await store.pauseRecording()
        #expect(store.pointCount == 1)
        #expect(store.storageError == nil)
        #expect(store.recordingState == .paused)
    }

    @Test func terminalFailureIsNotClearedBySuccessfulReadsAndStopsIntake() async throws {
        let db = try await ControlledActivities.create()
        let store = RecordingController(repository: db)
        let library = ActivityLibrary(repository: db)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        await store.startRecording()
        await db.failWrites()
        store.record([sample(1_001)])
        await store.pauseRecording()
        #expect(store.requiresRestart)
        #expect(store.pendingCount == 1)
        store.record([sample(1_002)])
        await store.refresh()
        #expect(store.pendingCount == 1)
        #expect(store.recordingState == .unavailable)
        #expect(store.recordingStatus == .unavailable)
        #expect(store.storageError != nil)
    }

    @Test func pauseCutsOffIntakeWhileAWriteIsSuspended() async throws {
        let db = try await ControlledActivities.create()
        let store = RecordingController(repository: db)
        let library = ActivityLibrary(repository: db)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        await store.startRecording()
        await db.blockNextWrite()
        store.record([sample(1_001)])
        await db.waitForWrite()
        #expect(store.recordingStatus == .recording)
        #expect(store.pointCount == 0)
        let pause = Task { await store.pauseRecording() }
        for await operation in Observations({ store.operation }) {
            if operation == .pausing { break }
        }
        #expect(store.recordingStatus == .working(.pausing))
        store.record([sample(1_002)])
        await db.releaseWrite()
        await pause.value
        #expect(store.pointCount == 1)
        #expect(store.recordingState == .paused)
        #expect(store.recordingStatus == .paused)
    }

    @Test(arguments: [RecordingOperation.saving, .discarding])
    func completingAnActiveRecordingWaitsForWritesAndStopsIntake(_ operation: RecordingOperation) async throws {
        let db = try await ControlledActivities.create()
        let store = RecordingController(repository: db, saveFeedback: .init(minimumDuration: .zero))
        try await store.restore()
        await store.startRecording()
        let id = try #require(store.currentActivity?.id)
        await db.blockNextWrite()
        store.record([sample(1_001)])
        await db.waitForWrite()
        store.record([sample(1_002)])

        let completion = Task {
            if operation == .saving { await store.finishRecording() }
            else { await store.discardRecording() }
        }
        for await current in Observations({ store.operation }) {
            if current == operation { break }
        }
        store.record([sample(1_003)])
        #expect(store.pendingCount == 2)
        await db.releaseWrite()
        await completion.value

        #expect(store.storageError == nil)
        #expect(store.currentActivity == nil)
        #expect(store.pendingCount == 0)
        #expect(try await db.active() == nil)
        if operation == .saving {
            let saved = try await db.summary(id: id)
            #expect(saved.status == .completed)
            #expect(try await db.recordedTrack(id: id).segments.flatMap(\.points) == [sample(1_001), sample(1_002)])
        } else {
            #expect(try await db.summaries().isEmpty)
            await #expect(throws: ActivityError.self) { try await db.details(id: id) }
        }
    }

    @Test(arguments: [RecordingOperation.saving, .discarding])
    func failureToStopAnActiveRecordingPreservesItsPoints(_ operation: RecordingOperation) async throws {
        let db = try await ControlledActivities.create()
        let store = RecordingController(repository: db)
        try await store.restore()
        await store.startRecording()
        let id = try #require(store.currentActivity?.id)
        store.record([sample(1_001)])
        await store.refresh()
        await db.failOperation(.pausing)

        if operation == .saving { await store.finishRecording() }
        else { await store.discardRecording() }

        #expect(store.recordingStatus == .unavailable)
        #expect(store.currentActivity?.id == id)
        #expect(try await db.active()?.phase == .recording)
        #expect(try await db.recordedTrack(id: id).segments.flatMap(\.points) == [sample(1_001)])
    }

    @Test func savePublishesTheCommittedSummaryWithoutReadingHistoryAgain() async throws {
        let db = try await ControlledActivities.create()
        let store = RecordingController(repository: db)
        let library = ActivityLibrary(repository: db)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        await library.reloadHistory()
        await store.startRecording()
        store.record([sample(1_001)])
        await store.pauseRecording()
        await db.failHistory()
        await store.finishRecording()
        #expect(store.currentActivity == nil)
        #expect(store.storageError == nil)
        guard case .loaded(let history) = library.history else { Issue.record("Expected saved summary"); return }
        #expect(history.first?.pointCount == 1)
    }

    @Test func oversizedDeliveryIsVisibleAndBounded() async throws {
        let db = try await ControlledActivities.create()
        let store = RecordingController(repository: db)
        let library = ActivityLibrary(repository: db)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        await store.startRecording()
        store.record((1_001...6_001).map { sample(Int64($0)) })
        #expect(store.pendingCount == 0)
        #expect(store.storageError != nil)
    }
}

@MainActor private final class FeedbackTimer {
    private(set) var duration: Duration?
    private var sleeper: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func sleep(for duration: Duration) async {
        self.duration = duration
        started?.resume(); started = nil
        await withCheckedContinuation { sleeper = $0 }
    }

    func waitForSleep() async {
        if duration != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func advance() { sleeper?.resume(); sleeper = nil }
}

private func sample(_ time: Int64) -> TrackPoint {
    try! TrackPoint(timestampMilliseconds: time, latitude: 47, longitude: 11, elevationMeters: nil)
}
