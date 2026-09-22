import Foundation

/// Rebuildable output. Increment this version for changes to continuity,
/// statistics or thumbnail rendering; the original observations stay intact.
struct ActivityAnalysis: Equatable, Sendable {
    static let currentProcessingVersion = 2
    let activityID: ActivityID
    let sourceRevision: Int64
    let processingVersion: Int
    let processedAt: Timestamp
    let statistics: ActivityStatistics
    let thumbnailPNG: Data?

    func isCurrent(for activity: ActivitySummary) -> Bool {
        activityID == activity.id && sourceRevision == activity.sourceRevision
            && processingVersion == Self.currentProcessingVersion
            && (activity.pointCount == 0 || thumbnailPNG != nil)
    }
}

enum ActivityProcessingError: LocalizedError {
    case thumbnail
    var errorDescription: String? { "The activity preview could not be generated. Please try again." }
}
