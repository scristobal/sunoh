import ActivityKit
import Observation
import OSLog
import UIKit

@MainActor final class RecordingActivityController {
    private enum Update: Sendable {
        case content(RecordingActivityAttributes.ContentState)
        case end
    }
    private var pendingUpdate: Update?
    private var updateTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.samuel.sunoh", category: "LiveActivity")

    func startObserving(recorder: RecordingController, location: LocationTracker) {
        observationTask?.cancel()
        let updates = Observations {
            guard case .loaded(let active) = recorder.recording else { return Update?.none }
            guard let active, location.hasLocationPermission else { return Update.end }
            return Update.content(.init(
                pointCount: Int(clamping: active.summary.pointCount),
                phase: recorder.storageError != nil ? .blocked : (active.phase == .recording ? .recording : .paused),
                startedAt: active.summary.startedAt.date,
                lastPointAt: active.summary.lastPointAt?.date
            ))
        }
        observationTask = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled, let self else { break }
                if let update { enqueue(update) }
            }
        }
    }

    deinit { observationTask?.cancel() }

    private func enqueue(_ update: Update) {
        pendingUpdate = update
        guard updateTask == nil else { return }
        updateTask = Task {
            defer { updateTask = nil }
            while let update = pendingUpdate {
                pendingUpdate = nil
                let canStart = UIApplication.shared.applicationState == .active
                if let error = await Self.apply(update, canStart: canStart) {
                    logger.error("Live Activity update failed: \(error)")
                }
            }
        }
    }

    // SDK Activity references stay entirely inside this asynchronous operation.
    // The main actor passes only immutable content and serializes operations.
    private nonisolated static func apply(_ update: Update, canStart: Bool) async -> String? {
        switch update {
        case .end:
            for activity in Activity<RecordingActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        case .content(let state):
            let existing = Activity<RecordingActivityAttributes>.activities.filter {
                $0.activityState == .active || $0.activityState == .stale
            }
            for duplicate in existing.dropFirst() {
                await duplicate.end(nil, dismissalPolicy: .immediate)
            }
            let content = ActivityContent(state: state, staleDate: nil)
            if let activity = existing.first {
                await activity.update(content)
            } else if canStart, ActivityAuthorizationInfo().areActivitiesEnabled {
                do {
                    _ = try Activity.request(attributes: RecordingActivityAttributes(), content: content, pushType: nil)
                } catch { return error.localizedDescription }
            }
        }
        return nil
    }
}
