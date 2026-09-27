import Foundation
import SwiftData

/// Storage baseline for controlled, reseedable installations.
enum ActivitySchemaV0: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [StoredActivity.self, StoredTrackSegment.self, StoredTrackPoint.self, StoredActivityAnalysis.self]
    }

    @Model final class StoredActivity {
        @Attribute(.unique) var id: String
        var startedAtMilliseconds: Int64
        var lastPointAtMilliseconds: Int64?
        var completedAtMilliseconds: Int64?
        var importedAtMilliseconds: Int64?
        var statusRawValue: String
        var originRawValue: String
        var pointCount: Int
        var sourceRevision: Int64
        var currentSegmentID: String?
        @Relationship(deleteRule: .cascade, inverse: \StoredTrackSegment.activity)
        var segments: [StoredTrackSegment] = []
        @Relationship(deleteRule: .cascade, inverse: \StoredActivityAnalysis.activity)
        var analysis: StoredActivityAnalysis?

        init(id: ActivityID = ActivityID(), startedAt: Timestamp, status: ActivityStatus, origin: ActivityOrigin) {
            self.id = id.rawValue
            startedAtMilliseconds = startedAt.millisecondsSince1970
            statusRawValue = status.rawValue; originRawValue = origin.rawValue
            pointCount = 0; sourceRevision = 0
        }

        func summary() throws -> ActivitySummary {
            guard let status = ActivityStatus(rawValue: statusRawValue),
                  let origin = ActivityOrigin(rawValue: originRawValue), pointCount >= 0, sourceRevision >= 0 else {
                throw ActivityError.invalidData("Invalid activity metadata.")
            }
            return ActivitySummary(id: ActivityID(rawValue: id), startedAt: Timestamp(millisecondsSince1970: startedAtMilliseconds),
                lastPointAt: lastPointAtMilliseconds.map(Timestamp.init(millisecondsSince1970:)),
                completedAt: completedAtMilliseconds.map(Timestamp.init(millisecondsSince1970:)),
                importedAt: importedAtMilliseconds.map(Timestamp.init(millisecondsSince1970:)),
                origin: origin, status: status, pointCount: pointCount, sourceRevision: sourceRevision)
        }
    }

    @Model final class StoredTrackSegment {
        @Attribute(.unique) var id: String
        var ordinal: Int
        var boundaryRawValue: String
        var recordingStartedAtMilliseconds: Int64?
        var recordingStoppedAtMilliseconds: Int64?
        var activity: StoredActivity?
        @Relationship(deleteRule: .cascade, inverse: \StoredTrackPoint.segment)
        var points: [StoredTrackPoint] = []

        init(id: SegmentID = SegmentID(), ordinal: Int, boundary: SegmentBoundary, activity: StoredActivity) {
            self.id = id.rawValue; self.ordinal = ordinal; boundaryRawValue = boundary.rawValue
            self.activity = activity
        }
    }

    @Model final class StoredTrackPoint {
        // Denormalized activity ID supports bounded timestamp queries without
        // loading relationship arrays. Repository insertion validates ownership.
        #Index<StoredTrackPoint>([\.activityID, \.recordedAtMilliseconds])
        #Unique<StoredTrackPoint>([\.activityID, \.recordedAtMilliseconds])
        var activityID: String
        var recordedAtMilliseconds: Int64
        var latitude: Double
        var longitude: Double
        var elevationMeters: Double?
        var segment: StoredTrackSegment?

        /// Attach a whole batch through the segment relationship before saving.
        /// Setting each point's inverse individually makes large tracks quadratic.
        init(point: TrackPoint, activityID: ActivityID) {
            self.activityID = activityID.rawValue
            recordedAtMilliseconds = point.timestampMilliseconds
            latitude = point.latitude; longitude = point.longitude; elevationMeters = point.elevationMeters
        }

        func point() throws -> TrackPoint {
            guard segment?.activity?.id == activityID else { throw ActivityError.invalidData("A point has inconsistent ownership.") }
            return try TrackPoint(timestampMilliseconds: recordedAtMilliseconds, latitude: latitude,
                                  longitude: longitude, elevationMeters: elevationMeters)
        }
    }

    @Model final class StoredActivityAnalysis {
        @Attribute(.unique) var activityID: String
        var sourceRevision: Int64
        var processingVersion: Int
        var processedAtMilliseconds: Int64
        var elapsedDurationMilliseconds: Int64
        var distanceMeters: Double
        var elevationGainMeters: Double
        var elevationLossMeters: Double
        var maximumElevationMeters: Double?
        var minimumElevationMeters: Double?
        var runCount: Int = 0
        var averageDownhillSpeedMetersPerSecond: Double?
        var runDistanceMeters: Double = 0
        var runDurationMilliseconds: Int64 = 0
        var maximumRunSpeedMetersPerSecond: Double?
        var tallestRunHeightMeters: Double?
        var longestRunDistanceMeters: Double?
        var averageRunSteepnessPercent: Double?
        var maximumRunSteepnessPercent: Double?
        @Attribute(.externalStorage) var thumbnailPNG: Data?
        var passagesJSON: Data?
        var timelineJSON: Data?
        var activity: StoredActivity?

        init(_ result: ActivityAnalysis, activity: StoredActivity) throws {
            activityID = result.activityID.rawValue; self.activity = activity
            sourceRevision = result.sourceRevision; processingVersion = result.processingVersion
            processedAtMilliseconds = result.processedAt.millisecondsSince1970
            elapsedDurationMilliseconds = result.statistics.elapsedDurationMilliseconds
            distanceMeters = result.statistics.distanceMeters
            elevationGainMeters = result.statistics.elevationGainMeters
            elevationLossMeters = result.statistics.elevationLossMeters
            maximumElevationMeters = result.statistics.maximumElevationMeters
            minimumElevationMeters = result.statistics.minimumElevationMeters
            runCount = result.statistics.runCount
            averageDownhillSpeedMetersPerSecond = result.statistics.averageDownhillSpeedMetersPerSecond
            runDistanceMeters = result.statistics.runDistanceMeters
            runDurationMilliseconds = result.statistics.runDurationMilliseconds
            maximumRunSpeedMetersPerSecond = result.statistics.maximumRunSpeedMetersPerSecond
            tallestRunHeightMeters = result.statistics.tallestRunHeightMeters
            longestRunDistanceMeters = result.statistics.longestRunDistanceMeters
            averageRunSteepnessPercent = result.statistics.averageRunSteepnessPercent
            maximumRunSteepnessPercent = result.statistics.maximumRunSteepnessPercent
            thumbnailPNG = result.thumbnailPNG
            passagesJSON = try result.passages.map { try JSONEncoder().encode($0) }
            timelineJSON = try result.timeline.map { try JSONEncoder().encode($0) }
        }

        func update(_ result: ActivityAnalysis) throws {
            sourceRevision = result.sourceRevision; processingVersion = result.processingVersion
            processedAtMilliseconds = result.processedAt.millisecondsSince1970
            elapsedDurationMilliseconds = result.statistics.elapsedDurationMilliseconds
            distanceMeters = result.statistics.distanceMeters
            elevationGainMeters = result.statistics.elevationGainMeters
            elevationLossMeters = result.statistics.elevationLossMeters
            maximumElevationMeters = result.statistics.maximumElevationMeters
            minimumElevationMeters = result.statistics.minimumElevationMeters
            runCount = result.statistics.runCount
            averageDownhillSpeedMetersPerSecond = result.statistics.averageDownhillSpeedMetersPerSecond
            runDistanceMeters = result.statistics.runDistanceMeters
            runDurationMilliseconds = result.statistics.runDurationMilliseconds
            maximumRunSpeedMetersPerSecond = result.statistics.maximumRunSpeedMetersPerSecond
            tallestRunHeightMeters = result.statistics.tallestRunHeightMeters
            longestRunDistanceMeters = result.statistics.longestRunDistanceMeters
            averageRunSteepnessPercent = result.statistics.averageRunSteepnessPercent
            maximumRunSteepnessPercent = result.statistics.maximumRunSteepnessPercent
            thumbnailPNG = result.thumbnailPNG
            passagesJSON = try result.passages.map { try JSONEncoder().encode($0) }
            timelineJSON = try result.timeline.map { try JSONEncoder().encode($0) }
        }

        func result() throws -> ActivityAnalysis {
            guard activity?.id == activityID else { throw ActivityError.invalidData("Analysis has no owning activity.") }
            var statistics = ActivityStatistics()
            statistics.elapsedDurationMilliseconds = elapsedDurationMilliseconds
            statistics.distanceMeters = distanceMeters
            statistics.elevationGainMeters = elevationGainMeters
            statistics.elevationLossMeters = elevationLossMeters
            statistics.maximumElevationMeters = maximumElevationMeters
            statistics.minimumElevationMeters = minimumElevationMeters
            statistics.runCount = runCount
            statistics.averageDownhillSpeedMetersPerSecond = averageDownhillSpeedMetersPerSecond
            statistics.runDistanceMeters = runDistanceMeters
            statistics.runDurationMilliseconds = runDurationMilliseconds
            statistics.maximumRunSpeedMetersPerSecond = maximumRunSpeedMetersPerSecond
            statistics.tallestRunHeightMeters = tallestRunHeightMeters
            statistics.longestRunDistanceMeters = longestRunDistanceMeters
            statistics.averageRunSteepnessPercent = averageRunSteepnessPercent
            statistics.maximumRunSteepnessPercent = maximumRunSteepnessPercent
            let passages = try passagesJSON.map { try JSONDecoder().decode(SkiActivityDetector.Result.self, from: $0) }
            // Skip stale derived payloads so the processor can rebuild them.
            let timeline = processingVersion == ActivityAnalysis.currentProcessingVersion
                ? try timelineJSON.map { try JSONDecoder().decode(ActivityTimeline.self, from: $0) } : nil
            return ActivityAnalysis(activityID: ActivityID(rawValue: activityID), sourceRevision: sourceRevision,
                processingVersion: processingVersion, processedAt: Timestamp(millisecondsSince1970: processedAtMilliseconds),
                statistics: statistics, thumbnailPNG: thumbnailPNG, passages: passages, timeline: timeline)
        }
    }
}

typealias StoredActivity = ActivitySchemaV0.StoredActivity
typealias StoredTrackSegment = ActivitySchemaV0.StoredTrackSegment
typealias StoredTrackPoint = ActivitySchemaV0.StoredTrackPoint
typealias StoredActivityAnalysis = ActivitySchemaV0.StoredActivityAnalysis
