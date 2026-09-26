import Foundation

/// Owns expensive, rebuildable work and coalesces concurrent requests. No UI or
/// recording controller is required for an activity to finish processing.
actor ActivityProcessor {
    typealias Calculation = @Sendable (ActivityProcessingInput) async throws -> (ActivityStatistics, Data?, SkiActivityDetector.Result, ActivityTimeline)
    typealias ReferenceLookup = @Sendable (TrackGeometry) async throws -> SkiDataCatalog.ReferenceData
    private let repository: any ActivityPersistence
    private let calculate: Calculation
    private let now: @Sendable () -> Int64
    private struct Work {
        let token: UUID
        let task: Task<ActivityAnalysis, Error>
        let forced: Bool
    }
    private var tasks: [ActivityID: Work] = [:]

    init(repository: any ActivityPersistence, clock: @escaping @Sendable () -> Int64 = {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }, referenceData: @escaping ReferenceLookup = { try await SkiDataCatalog.referenceData(for: $0) },
         calculate: Calculation? = nil) {
        self.repository = repository; self.now = clock
        self.calculate = calculate ?? { input in try await Self.calculate(input, referenceData: referenceData) }
    }

    private nonisolated static func calculate(_ input: ActivityProcessingInput, referenceData: @escaping ReferenceLookup) async throws -> (ActivityStatistics, Data?, SkiActivityDetector.Result, ActivityTimeline) {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let geometry = TrackContinuityPolicy.geometry(for: input.track)
            let reference = try await referenceData(geometry)
            try Task.checkCancellation()
            var statistics = ActivityStatistics(activity: input.activity, geometry: geometry)
            let passages = SkiActivityDetector.analyze(geometry, liftFeatures: reference.features)
            statistics.runCount = passages.runCount
            statistics.liftCount = passages.liftCount
            let ski = Geo.skiStatistics(in: geometry, passages: passages)
            statistics.averageDownhillSpeedMetersPerSecond = ski.averageDownhillSpeedMetersPerSecond
            statistics.averageLiftSpeedMetersPerSecond = ski.averageLiftSpeedMetersPerSecond
            statistics.runDistanceMeters = ski.runDistanceMeters
            statistics.liftDistanceMeters = ski.liftDistanceMeters
            statistics.runElevationLossMeters = ski.runElevationLossMeters
            statistics.liftElevationGainMeters = ski.liftElevationGainMeters
            statistics.runDurationMilliseconds = ski.runDurationMilliseconds
            statistics.liftDurationMilliseconds = ski.liftDurationMilliseconds
            statistics.maximumRunSpeedMetersPerSecond = ski.maximumRunSpeedMetersPerSecond
            statistics.tallestRunHeightMeters = ski.tallestRunHeightMeters
            statistics.longestRunDistanceMeters = ski.longestRunDistanceMeters
            statistics.tallestLiftHeightMeters = ski.tallestLiftHeightMeters
            statistics.longestLiftDistanceMeters = ski.longestLiftDistanceMeters
            statistics.averageRunSteepnessPercent = ski.averageRunSteepnessPercent
            statistics.averageLiftSteepnessPercent = ski.averageLiftSteepnessPercent
            statistics.maximumRunSteepnessPercent = ski.maximumRunSteepnessPercent
            statistics.maximumLiftSteepnessPercent = ski.maximumLiftSteepnessPercent
            var timeline = Geo.timeline(in: geometry, passages: passages)
            if !timeline.entries.isEmpty {
                timeline.skiMatches = reference.match(geometry: geometry, timeline: timeline)
            }
            let png = TrackThumbnail.png(geometry: geometry)
            try Task.checkCancellation()
            guard input.activity.pointCount == 0 || png != nil else { throw ActivityProcessingError.thumbnail }
            return (statistics, png, passages, timeline)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func process(id: ActivityID, force: Bool = false) async throws -> ActivityAnalysis {
        if let work = tasks[id] {
            let result = try await work.task.value
            if !force || work.forced { return result }
            if tasks[id]?.token == work.token { tasks[id] = nil }
            return try await process(id: id, force: true)
        }
        let token = UUID()
        let task = Task { [repository, calculate, now] in
            let activity = try await repository.summary(id: id)
            guard activity.status == .completed else { throw ActivityError.invalidTransition }
            if !force, let existing = try await repository.storedAnalysis(id: id), existing.isCurrent(for: activity) { return existing }
            let input = try await repository.processingInput(id: id)
            let (statistics, png, passages, timeline) = try await calculate(input)
            try Task.checkCancellation()
            let result = ActivityAnalysis(activityID: id, sourceRevision: input.activity.sourceRevision,
                processingVersion: ActivityAnalysis.currentProcessingVersion, processedAt: Timestamp(millisecondsSince1970: now()),
                statistics: statistics, thumbnailPNG: png, passages: passages, timeline: timeline)
            try await repository.saveAnalysis(result)
            return result
        }
        tasks[id] = Work(token: token, task: task, forced: force)
        defer { if tasks[id]?.token == token { tasks[id] = nil } }
        return try await task.value
    }

    func cancel(id: ActivityID) { tasks[id]?.task.cancel() }
}
