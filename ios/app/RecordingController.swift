import Foundation
import Observation

enum RecordingState {
    case idle, recording, stopped, unavailable
}

@MainActor @Observable final class RecordingController {
    private(set) var recording: LoadState<ActiveRecording?> = .loading
    private(set) var geometry: LoadState<TrackGeometry?> = .loaded(nil)
    private(set) var operation: RecordingOperation?
    private(set) var failure: ActivityError?
    private(set) var pendingCount = 0

    var currentRecording: ActiveRecording? {
        guard case .loaded(let value) = recording else { return nil }
        return value
    }
    var currentActivity: ActivitySummary? { currentRecording?.summary }
    var geometryValue: TrackGeometry? {
        guard case .loaded(let value) = geometry else { return nil }
        return value
    }
    var pointCount: Int { currentActivity?.pointCount ?? 0 }
    var storageError: String? { failure?.localizedDescription }
    var requiresRestart: Bool { if case .storage = failure { return true }; return false }
    var recordingState: RecordingState {
        guard case .loaded = recording, failure == nil else { return .unavailable }
        switch currentRecording?.phase {
        case .recording: return .recording
        case .stopped: return .stopped
        case nil: return .idle
        }
    }
    var isChangingRecording: Bool { operation != nil || recordingState == .unavailable }
    var needsSaveDecision: Bool {
        !isChangingRecording && currentRecording?.phase == .stopped && currentRecording?.needsSaveDecision == true
    }

    var recordingStatus: RecordingStatus {
        guard failure == nil else { return .unavailable }
        if let operation { return .working(operation) }
        switch recording {
        case .loading: return .working(.restoring)
        case .failed: return .unavailable
        case .loaded(let active):
            switch active?.phase {
            case .recording: return .recording
            case .stopped: return .stopped
            case nil: return saveFeedback.isVisible ? .working(.saving) : .ready
            }
        }
    }

    private let repository: any ActivityPersistence
    private let saveFeedback: RecordingSaveFeedback
    private let geometryRefreshInterval: Duration
    private let maximumPendingPoints = 4_096
    @ObservationIgnored private var pending: [TrackPoint] = []
    @ObservationIgnored private var pendingActivityID: ActivityID?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var geometryTask: Task<Void, Never>?
    @ObservationIgnored private var commandTail: Task<Void, Never>?
    @ObservationIgnored private var lastGeometryRead: ContinuousClock.Instant?
    @ObservationIgnored private var oldestPending: ContinuousClock.Instant?
    @ObservationIgnored var onCompleted: (@MainActor (ActivitySummary) async -> Void)?

    init(repository: any ActivityPersistence, geometryRefreshInterval: Duration = .seconds(5),
         saveFeedback: RecordingSaveFeedback = .init()) {
        self.repository = repository; self.geometryRefreshInterval = geometryRefreshInterval
        self.saveFeedback = saveFeedback
    }

    func restore() async throws {
        do {
            recording = .loaded(try await repository.active())
            refreshGeometry(force: true)
            await finishStoppedRecordingIfNeeded()
        } catch {
            recording = .failed(error.localizedDescription)
            setFailure(error)
            throw error
        }
    }

    func refresh() async {
        guard !requiresRestart else { return }
        do {
            try await serialized {
                self.recording = .loaded(try await self.repository.active())
                try await self.drainPoints()
                self.failure = nil
            }
            refreshGeometry(force: true)
            await finishStoppedRecordingIfNeeded()
        } catch { setFailure(error) }
    }

    func startRecording() async {
        guard recordingState == .idle, !recordingStatus.isWorking else { return }
        await change(.starting) {
            self.recording = .loaded(try await self.repository.start())
            self.geometry = .loaded(nil)
        }
    }

    func stopRecording() async {
        guard recordingState == .recording, let id = currentActivity?.id else { return }
        await change(.stopping) {
            self.recording = .loaded(try await self.repository.stop(id: id))
            try await self.drainPoints()
            if self.currentRecording?.needsSaveDecision == false {
                self.operation = .saving
                self.saveFeedback.begin()
                try await self.saveRecording(id: id)
            }
        }
    }

    private func finishStoppedRecordingIfNeeded() async {
        guard currentRecording?.phase == .stopped, currentRecording?.needsSaveDecision == false else { return }
        await finishRecording()
    }

    func finishRecording() async {
        guard recordingState == .stopped, let id = currentActivity?.id else { return }
        await change(.saving) {
            try await self.drainPoints()
            try await self.saveRecording(id: id)
        }
    }

    private func saveRecording(id: ActivityID) async throws {
        let saved = try await repository.finish(id: id)
        recording = .loaded(nil)
        geometry = .loaded(nil)
        await onCompleted?(saved)
    }

    func discardRecording() async {
        guard needsSaveDecision, let id = currentActivity?.id else { return }
        await change(.discarding) {
            try await self.repository.discard(id: id)
            self.pending = []; self.pendingActivityID = nil; self.pendingCount = 0
            self.oldestPending = nil
            self.recording = .loaded(nil); self.geometry = .loaded(nil)
        }
    }

    func record(_ points: [TrackPoint]) {
        guard failure == nil, operation == nil,
              let active = currentRecording, active.phase == .recording else { return }
        let accepted = points.filter { $0.recordedAt >= active.recordingStartedAt }
        guard !accepted.isEmpty else { return }
        guard pending.count + accepted.count <= maximumPendingPoints,
              oldestPending.map({ $0.duration(to: .now) <= .seconds(60) }) ?? true else {
            failure = .storage("The pending sample limit was reached. New samples were not accepted.")
            return
        }
        guard pendingActivityID == nil || pendingActivityID == active.id else {
            failure = .invalidTransition; return
        }
        pendingActivityID = active.id
        if oldestPending == nil { oldestPending = .now }
        pending.append(contentsOf: accepted); pendingCount = pending.count
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil, !pending.isEmpty, failure == nil else { return }
        flushTask = Task {
            defer { flushTask = nil; scheduleFlush() }
            do {
                try await serialized { try await self.drainPoints() }
                refreshGeometry()
            } catch { setFailure(error) }
        }
    }

    private func drainPoints() async throws {
        while !pending.isEmpty {
            guard let id = pendingActivityID, id == currentActivity?.id else { throw ActivityError.invalidTransition }
            let batch = Array(pending.prefix(512))
            let result = try await repository.append(batch, activityID: id)
            recording = .loaded(result)
            pending.removeFirst(batch.count); pendingCount = pending.count
        }
        pendingActivityID = nil; oldestPending = nil
    }

    private func change(_ operation: RecordingOperation, work: @escaping @MainActor () async throws -> Void) async {
        guard !isChangingRecording else { return }
        if operation == .saving { saveFeedback.begin() }
        else { saveFeedback.clear() }
        self.operation = operation
        defer { self.operation = nil }
        do {
            try await serialized { try await work() }
            refreshGeometry(force: true)
        } catch { setFailure(error) }
    }

    func reportStorageFailure(_ error: ActivityError) {
        if case .storage = error { setFailure(error) }
    }

    private func setFailure(_ error: Error) {
        saveFeedback.clear()
        failure = (error as? ActivityError) ?? .storage(error.localizedDescription)
    }

    private func refreshGeometry(force: Bool = false) {
        guard geometryTask == nil else { return }
        guard let id = currentActivity?.id else { geometry = .loaded(nil); return }
        guard force || lastGeometryRead.map({ $0.duration(to: .now) >= geometryRefreshInterval }) ?? true else { return }
        geometryTask = Task {
            defer { geometryTask = nil }
            do {
                let result = try await repository.geometry(id: id)
                guard currentActivity?.id == id else { return }
                geometry = .loaded(result); lastGeometryRead = .now
            } catch {
                guard currentActivity?.id == id else { return }
                geometry = .failed(error.localizedDescription)
            }
        }
    }

    private func serialized<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = commandTail
        let task = Task { await previous?.value; return try await work() }
        commandTail = Task { _ = await task.result }
        return try await task.value
    }
}
