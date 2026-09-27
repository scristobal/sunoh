import Foundation

/// Rebuildable output. Increment this version for changes to continuity,
/// passage classification, timeline, quality thresholds, statistics or thumbnails; original observations stay intact.
struct ActivityAnalysis: Equatable, Sendable {
    static let currentProcessingVersion = 0
    let activityID: ActivityID
    let sourceRevision: Int64
    let processingVersion: Int
    let processedAt: Timestamp
    let statistics: ActivityStatistics
    let thumbnailPNG: Data?
    var passages: SkiActivityDetector.Result? = nil
    var timeline: ActivityTimeline? = nil

    func isCurrent(for activity: ActivitySummary) -> Bool {
        activityID == activity.id && sourceRevision == activity.sourceRevision
            && processingVersion == Self.currentProcessingVersion
            && passages != nil
            && timeline?.entries.allSatisfy({ $0.pointCount != nil && $0.quality?.sampleGapHistogram != nil }) == true
            && (activity.pointCount == 0 || thumbnailPNG != nil)
    }
}

enum ActivityProcessingError: LocalizedError {
    case thumbnail
    var errorDescription: String? { "The activity preview could not be generated. Please try again." }
}
