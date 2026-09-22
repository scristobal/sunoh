import Foundation

/// Owns expensive, rebuildable work and coalesces concurrent requests. No UI or
/// recording controller is required for an activity to finish processing.
actor ActivityProcessor {
    typealias Calculation = @Sendable (ActivityProcessingInput) async throws -> (ActivityStatistics, Data?)
    private let repository: any ActivityPersistence
    private let calculate: Calculation
    private let now: @Sendable () -> Int64
    private var tasks: [ActivityID: Task<ActivityAnalysis, Error>] = [:]

    init(repository: any ActivityPersistence, clock: @escaping @Sendable () -> Int64 = {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }, calculate: @escaping Calculation = ActivityProcessor.calculate) {
        self.repository = repository; self.now = clock; self.calculate = calculate
    }

    private nonisolated static func calculate(_ input: ActivityProcessingInput) async throws -> (ActivityStatistics, Data?) {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let geometry = TrackContinuityPolicy.geometry(for: input.track)
            let statistics = ActivityStatistics(activity: input.activity, geometry: geometry)
            let png = TrackThumbnail.png(geometry: geometry)
            try Task.checkCancellation()
            guard input.activity.pointCount == 0 || png != nil else { throw ActivityProcessingError.thumbnail }
            return (statistics, png)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func process(id: ActivityID) async throws -> ActivityAnalysis {
        if let task = tasks[id] { return try await task.value }
        let task = Task { [repository, calculate, now] in
            let activity = try await repository.summary(id: id)
            guard activity.status == .completed else { throw ActivityError.invalidTransition }
            if let existing = try await repository.storedAnalysis(id: id), existing.isCurrent(for: activity) { return existing }
            let input = try await repository.processingInput(id: id)
            let (statistics, png) = try await calculate(input)
            try Task.checkCancellation()
            let result = ActivityAnalysis(activityID: id, sourceRevision: input.activity.sourceRevision,
                processingVersion: ActivityAnalysis.currentProcessingVersion, processedAt: Timestamp(millisecondsSince1970: now()),
                statistics: statistics, thumbnailPNG: png)
            try await repository.saveAnalysis(result)
            return result
        }
        tasks[id] = task
        defer { tasks[id] = nil }
        return try await task.value
    }

    func cancel(id: ActivityID) { tasks[id]?.cancel() }
}
