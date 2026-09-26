import CoreData
import CryptoKit
import Foundation
import SwiftData

enum ActivityMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ActivitySchemaV1.self, ActivitySchemaV2.self, ActivitySchemaV3.self, ActivitySchemaV4.self, ActivitySchemaV5.self, ActivitySchemaV6.self, ActivitySchemaV7.self, ActivitySchemaV8.self, ActivitySchemaV9.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: ActivitySchemaV1.self, toVersion: ActivitySchemaV2.self),
         .lightweight(fromVersion: ActivitySchemaV2.self, toVersion: ActivitySchemaV3.self),
         .lightweight(fromVersion: ActivitySchemaV3.self, toVersion: ActivitySchemaV4.self),
         .lightweight(fromVersion: ActivitySchemaV4.self, toVersion: ActivitySchemaV5.self),
         .lightweight(fromVersion: ActivitySchemaV5.self, toVersion: ActivitySchemaV6.self),
         .lightweight(fromVersion: ActivitySchemaV6.self, toVersion: ActivitySchemaV7.self),
         .lightweight(fromVersion: ActivitySchemaV7.self, toVersion: ActivitySchemaV8.self),
         .lightweight(fromVersion: ActivitySchemaV8.self, toVersion: ActivitySchemaV9.self)]
    }
}

/// Keep a native backup and verify original observations before opening migrated storage.
enum ActivityMigration {
    static let pointBatchSize = 1_024
    private static let sourceVersions = [1, 2, 3, 4, 5, 6, 7, 8]

    struct Snapshot: Equatable {
        let activities: [Activity]
        let segments: [Segment]
        let points: Points

        struct Points: Equatable {
            let count: Int
            let digest: Data
        }

        struct Activity: Equatable {
            let summary: ActivitySummary
            let currentSegmentID: String?
        }

        struct Segment: Equatable {
            let id: String
            let activityID: String?
            let ordinal: Int
            let boundary: String
            let startedAt: Int64?
            let stoppedAt: Int64?
        }

        struct Point: Encodable {
            let activityID: String
            let segmentID: String?
            let observation: TrackPoint
        }
    }

    static func backupURL(for url: URL, sourceVersion: Int = 1) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".v\(sourceVersion)-backup", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
    }

    private static func pendingURL(for url: URL, sourceVersion: Int) -> URL {
        backupURL(for: url, sourceVersion: sourceVersion).appendingPathExtension("pending")
    }

    private static func pendingVersions(at url: URL) -> [Int] {
        sourceVersions.filter { FileManager.default.fileExists(atPath: pendingURL(for: url, sourceVersion: $0).path) }
    }

    static func prepare(at url: URL) throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
        if let version = sourceVersions.first(where: { metadata[NSStoreModelVersionIdentifiersKey] as? [String] == ["\($0).0.0"] }),
           !pendingVersions(at: url).contains(version) {
            let backup = backupURL(for: url, sourceVersion: version)
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
            // Core Data copies committed WAL data and external blobs consistently.
            try coordinator.replacePersistentStore(at: backup, destinationOptions: nil, withPersistentStoreFrom: url,
                                                   sourceOptions: nil, ofType: NSSQLiteStoreType)
            try Data().write(to: pendingURL(for: url, sourceVersion: version), options: .atomic)
        }
        var original: Snapshot?
        for version in pendingVersions(at: url) {
            let backup = backupURL(for: url, sourceVersion: version)
            guard FileManager.default.fileExists(atPath: backup.path) else {
                throw ActivityError.invalidData("The original storage backup is missing, so recordings could not be verified.")
            }
            let schema: Schema
            switch version {
            case 1: schema = Schema(versionedSchema: ActivitySchemaV1.self)
            case 2: schema = Schema(versionedSchema: ActivitySchemaV2.self)
            case 3: schema = Schema(versionedSchema: ActivitySchemaV3.self)
            case 4: schema = Schema(versionedSchema: ActivitySchemaV4.self)
            case 5: schema = Schema(versionedSchema: ActivitySchemaV5.self)
            case 6: schema = Schema(versionedSchema: ActivitySchemaV6.self)
            case 7: schema = Schema(versionedSchema: ActivitySchemaV7.self)
            default: schema = Schema(versionedSchema: ActivitySchemaV8.self)
            }
            let configuration = ModelConfiguration("Activities", schema: schema, url: backup, allowsSave: false, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
            let snapshot: Snapshot
            switch version {
            case 1: snapshot = try snapshotV1(context)
            case 2: snapshot = try snapshotV2(context)
            case 3: snapshot = try snapshotV3(context)
            case 4: snapshot = try snapshotV4(context)
            case 5: snapshot = try snapshotV5(context)
            case 6: snapshot = try snapshotV6(context)
            case 7: snapshot = try snapshotV7(context)
            default: snapshot = try snapshotV8(context)
            }
            if let original, original != snapshot {
                throw ActivityError.invalidData("Recordings changed during an unfinished storage update. The original backups have been kept.")
            }
            original = snapshot
        }
        return original
    }

    static func verify(_ original: Snapshot?, in container: ModelContainer, at url: URL) throws {
        guard let original else { return }
        guard try original == snapshotV9(ModelContext(container)) else {
            throw ActivityError.invalidData("Recordings could not be verified after updating storage. The original backup has been kept.")
        }
        for version in pendingVersions(at: url) {
            try FileManager.default.removeItem(at: pendingURL(for: url, sourceVersion: version))
        }
    }

    private static func snapshotV1(_ context: ModelContext) throws -> Snapshot {
        let activities = try context.fetch(FetchDescriptor<ActivitySchemaV1.StoredActivity>(sortBy: [SortDescriptor(\.id)]))
        let segments = try context.fetch(FetchDescriptor<ActivitySchemaV1.StoredTrackSegment>(sortBy: [SortDescriptor(\.id)]))
        let points = try fingerprint(in: context.container,
            sortBy: [SortDescriptor(\ActivitySchemaV1.StoredTrackPoint.activityID), SortDescriptor(\.recordedAtMilliseconds)],
            after: { id, time in #Predicate { $0.activityID > id || ($0.activityID == id && $0.recordedAtMilliseconds > time) } },
            point: { Snapshot.Point(activityID: $0.activityID, segmentID: $0.segment?.id, observation: try $0.point()) })
        return try Snapshot(
            activities: activities.map { Snapshot.Activity(summary: try $0.summary(), currentSegmentID: $0.currentSegmentID) },
            segments: segments.map { Snapshot.Segment(id: $0.id, activityID: $0.activity?.id, ordinal: $0.ordinal,
                boundary: $0.boundaryRawValue, startedAt: $0.recordingStartedAtMilliseconds, stoppedAt: $0.recordingStoppedAtMilliseconds) },
            points: points)
    }

    private static func snapshotV2(_ context: ModelContext) throws -> Snapshot {
        let activities = try context.fetch(FetchDescriptor<ActivitySchemaV2.StoredActivity>(sortBy: [SortDescriptor(\.id)]))
        let segments = try context.fetch(FetchDescriptor<ActivitySchemaV2.StoredTrackSegment>(sortBy: [SortDescriptor(\.id)]))
        let points = try fingerprint(in: context.container,
            sortBy: [SortDescriptor(\ActivitySchemaV2.StoredTrackPoint.activityID), SortDescriptor(\.recordedAtMilliseconds)],
            after: { id, time in #Predicate { $0.activityID > id || ($0.activityID == id && $0.recordedAtMilliseconds > time) } },
            point: { Snapshot.Point(activityID: $0.activityID, segmentID: $0.segment?.id, observation: try $0.point()) })
        return try Snapshot(
            activities: activities.map { Snapshot.Activity(summary: try $0.summary(), currentSegmentID: $0.currentSegmentID) },
            segments: segments.map { Snapshot.Segment(id: $0.id, activityID: $0.activity?.id, ordinal: $0.ordinal,
                boundary: $0.boundaryRawValue, startedAt: $0.recordingStartedAtMilliseconds, stoppedAt: $0.recordingStoppedAtMilliseconds) },
            points: points)
    }

    private static func snapshotV3(_ context: ModelContext) throws -> Snapshot {
        let activities = try context.fetch(FetchDescriptor<ActivitySchemaV3.StoredActivity>(sortBy: [SortDescriptor(\.id)]))
        let segments = try context.fetch(FetchDescriptor<ActivitySchemaV3.StoredTrackSegment>(sortBy: [SortDescriptor(\.id)]))
        let points = try fingerprint(in: context.container,
            sortBy: [SortDescriptor(\ActivitySchemaV3.StoredTrackPoint.activityID), SortDescriptor(\.recordedAtMilliseconds)],
            after: { id, time in #Predicate { $0.activityID > id || ($0.activityID == id && $0.recordedAtMilliseconds > time) } },
            point: { Snapshot.Point(activityID: $0.activityID, segmentID: $0.segment?.id, observation: try $0.point()) })
        return try Snapshot(
            activities: activities.map { Snapshot.Activity(summary: try $0.summary(), currentSegmentID: $0.currentSegmentID) },
            segments: segments.map { Snapshot.Segment(id: $0.id, activityID: $0.activity?.id, ordinal: $0.ordinal,
                boundary: $0.boundaryRawValue, startedAt: $0.recordingStartedAtMilliseconds, stoppedAt: $0.recordingStoppedAtMilliseconds) },
            points: points)
    }

    private static func snapshotV4(_ context: ModelContext) throws -> Snapshot {
        let activities = try context.fetch(FetchDescriptor<ActivitySchemaV4.StoredActivity>(sortBy: [SortDescriptor(\.id)]))
        let segments = try context.fetch(FetchDescriptor<ActivitySchemaV4.StoredTrackSegment>(sortBy: [SortDescriptor(\.id)]))
        let points = try fingerprint(in: context.container,
            sortBy: [SortDescriptor(\ActivitySchemaV4.StoredTrackPoint.activityID), SortDescriptor(\.recordedAtMilliseconds)],
            after: { id, time in #Predicate { $0.activityID > id || ($0.activityID == id && $0.recordedAtMilliseconds > time) } },
            point: { Snapshot.Point(activityID: $0.activityID, segmentID: $0.segment?.id, observation: try $0.point()) })
        return try Snapshot(
            activities: activities.map { Snapshot.Activity(summary: try $0.summary(), currentSegmentID: $0.currentSegmentID) },
            segments: segments.map { Snapshot.Segment(id: $0.id, activityID: $0.activity?.id, ordinal: $0.ordinal,
                boundary: $0.boundaryRawValue, startedAt: $0.recordingStartedAtMilliseconds, stoppedAt: $0.recordingStoppedAtMilliseconds) },
            points: points)
    }

    private static func snapshotV5(_ context: ModelContext) throws -> Snapshot {
        let activities = try context.fetch(FetchDescriptor<ActivitySchemaV5.StoredActivity>(sortBy: [SortDescriptor(\.id)]))
        let segments = try context.fetch(FetchDescriptor<ActivitySchemaV5.StoredTrackSegment>(sortBy: [SortDescriptor(\.id)]))
        let points = try fingerprint(in: context.container,
            sortBy: [SortDescriptor(\ActivitySchemaV5.StoredTrackPoint.activityID), SortDescriptor(\.recordedAtMilliseconds)],
            after: { id, time in #Predicate { $0.activityID > id || ($0.activityID == id && $0.recordedAtMilliseconds > time) } },
            point: { Snapshot.Point(activityID: $0.activityID, segmentID: $0.segment?.id, observation: try $0.point()) })
        return try Snapshot(
            activities: activities.map { Snapshot.Activity(summary: try $0.summary(), currentSegmentID: $0.currentSegmentID) },
            segments: segments.map { Snapshot.Segment(id: $0.id, activityID: $0.activity?.id, ordinal: $0.ordinal,
                boundary: $0.boundaryRawValue, startedAt: $0.recordingStartedAtMilliseconds, stoppedAt: $0.recordingStoppedAtMilliseconds) },
            points: points)
    }

    private static func snapshotV6(_ context: ModelContext) throws -> Snapshot {
        let activities = try context.fetch(FetchDescriptor<ActivitySchemaV6.StoredActivity>(sortBy: [SortDescriptor(\.id)]))
        let segments = try context.fetch(FetchDescriptor<ActivitySchemaV6.StoredTrackSegment>(sortBy: [SortDescriptor(\.id)]))
        let points = try fingerprint(in: context.container,
            sortBy: [SortDescriptor(\ActivitySchemaV6.StoredTrackPoint.activityID), SortDescriptor(\.recordedAtMilliseconds)],
            after: { id, time in #Predicate { $0.activityID > id || ($0.activityID == id && $0.recordedAtMilliseconds > time) } },
            point: { Snapshot.Point(activityID: $0.activityID, segmentID: $0.segment?.id, observation: try $0.point()) })
        return try Snapshot(
            activities: activities.map { Snapshot.Activity(summary: try $0.summary(), currentSegmentID: $0.currentSegmentID) },
            segments: segments.map { Snapshot.Segment(id: $0.id, activityID: $0.activity?.id, ordinal: $0.ordinal,
                boundary: $0.boundaryRawValue, startedAt: $0.recordingStartedAtMilliseconds, stoppedAt: $0.recordingStoppedAtMilliseconds) },
            points: points)
    }

    private static func snapshotV7(_ context: ModelContext) throws -> Snapshot {
        let activities = try context.fetch(FetchDescriptor<ActivitySchemaV7.StoredActivity>(sortBy: [SortDescriptor(\.id)]))
        let segments = try context.fetch(FetchDescriptor<ActivitySchemaV7.StoredTrackSegment>(sortBy: [SortDescriptor(\.id)]))
        let points = try fingerprint(in: context.container,
            sortBy: [SortDescriptor(\ActivitySchemaV7.StoredTrackPoint.activityID), SortDescriptor(\.recordedAtMilliseconds)],
            after: { id, time in #Predicate { $0.activityID > id || ($0.activityID == id && $0.recordedAtMilliseconds > time) } },
            point: { Snapshot.Point(activityID: $0.activityID, segmentID: $0.segment?.id, observation: try $0.point()) })
        return try Snapshot(
            activities: activities.map { Snapshot.Activity(summary: try $0.summary(), currentSegmentID: $0.currentSegmentID) },
            segments: segments.map { Snapshot.Segment(id: $0.id, activityID: $0.activity?.id, ordinal: $0.ordinal,
                boundary: $0.boundaryRawValue, startedAt: $0.recordingStartedAtMilliseconds, stoppedAt: $0.recordingStoppedAtMilliseconds) },
            points: points)
    }

    private static func snapshotV8(_ context: ModelContext) throws -> Snapshot {
        let activities = try context.fetch(FetchDescriptor<ActivitySchemaV8.StoredActivity>(sortBy: [SortDescriptor(\.id)]))
        let segments = try context.fetch(FetchDescriptor<ActivitySchemaV8.StoredTrackSegment>(sortBy: [SortDescriptor(\.id)]))
        let points = try fingerprint(in: context.container,
            sortBy: [SortDescriptor(\ActivitySchemaV8.StoredTrackPoint.activityID), SortDescriptor(\.recordedAtMilliseconds)],
            after: { id, time in #Predicate { $0.activityID > id || ($0.activityID == id && $0.recordedAtMilliseconds > time) } },
            point: { Snapshot.Point(activityID: $0.activityID, segmentID: $0.segment?.id, observation: try $0.point()) })
        return try Snapshot(
            activities: activities.map { Snapshot.Activity(summary: try $0.summary(), currentSegmentID: $0.currentSegmentID) },
            segments: segments.map { Snapshot.Segment(id: $0.id, activityID: $0.activity?.id, ordinal: $0.ordinal,
                boundary: $0.boundaryRawValue, startedAt: $0.recordingStartedAtMilliseconds, stoppedAt: $0.recordingStoppedAtMilliseconds) },
            points: points)
    }

    private static func snapshotV9(_ context: ModelContext) throws -> Snapshot {
        let activities = try context.fetch(FetchDescriptor<StoredActivity>(sortBy: [SortDescriptor(\.id)]))
        let segments = try context.fetch(FetchDescriptor<StoredTrackSegment>(sortBy: [SortDescriptor(\.id)]))
        let points = try fingerprint(in: context.container,
            sortBy: [SortDescriptor(\StoredTrackPoint.activityID), SortDescriptor(\.recordedAtMilliseconds)],
            after: { id, time in #Predicate { $0.activityID > id || ($0.activityID == id && $0.recordedAtMilliseconds > time) } },
            point: { Snapshot.Point(activityID: $0.activityID, segmentID: $0.segment?.id, observation: try $0.point()) })
        return try Snapshot(
            activities: activities.map { Snapshot.Activity(summary: try $0.summary(), currentSegmentID: $0.currentSegmentID) },
            segments: segments.map { Snapshot.Segment(id: $0.id, activityID: $0.activity?.id, ordinal: $0.ordinal,
                boundary: $0.boundaryRawValue, startedAt: $0.recordingStartedAtMilliseconds, stoppedAt: $0.recordingStoppedAtMilliseconds) },
            points: points)
    }

    private static func fingerprint<Model: PersistentModel>(in container: ModelContainer, sortBy: [SortDescriptor<Model>],
        after: (String, Int64) -> Predicate<Model>, point: (Model) throws -> Snapshot.Point) throws -> Snapshot.Points {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var hash = SHA256(), count = 0
        var previous: Snapshot.Point?
        while true {
            let batch = try autoreleasepool {
                let context = ModelContext(container)
                var query = FetchDescriptor<Model>(sortBy: sortBy)
                if let previous { query.predicate = after(previous.activityID, previous.observation.timestampMilliseconds) }
                query.fetchLimit = pointBatchSize
                query.includePendingChanges = false
                return try context.fetch(query).map(point)
            }
            guard !batch.isEmpty else { break }
            hash.update(data: try encoder.encode(batch))
            count += batch.count
            previous = batch.last
            if batch.count < pointBatchSize { break }
        }
        return Snapshot.Points(count: count, digest: Data(hash.finalize()))
    }
}
