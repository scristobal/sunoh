import Foundation
import SwiftData
import Testing
@testable import Sunoh

private enum PreviousActivityMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ActivitySchemaV1.self, ActivitySchemaV2.self] }
    static var stages: [MigrationStage] { [.lightweight(fromVersion: ActivitySchemaV1.self, toVersion: ActivitySchemaV2.self)] }
}

private enum ThroughVersionThreeMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ActivitySchemaV1.self, ActivitySchemaV2.self, ActivitySchemaV3.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: ActivitySchemaV1.self, toVersion: ActivitySchemaV2.self),
         .lightweight(fromVersion: ActivitySchemaV2.self, toVersion: ActivitySchemaV3.self)]
    }
}

private enum ThroughVersionFourMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ActivitySchemaV1.self, ActivitySchemaV2.self, ActivitySchemaV3.self, ActivitySchemaV4.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: ActivitySchemaV1.self, toVersion: ActivitySchemaV2.self),
         .lightweight(fromVersion: ActivitySchemaV2.self, toVersion: ActivitySchemaV3.self),
         .lightweight(fromVersion: ActivitySchemaV3.self, toVersion: ActivitySchemaV4.self)]
    }
}

private enum ThroughVersionFiveMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ActivitySchemaV1.self, ActivitySchemaV2.self, ActivitySchemaV3.self, ActivitySchemaV4.self, ActivitySchemaV5.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: ActivitySchemaV1.self, toVersion: ActivitySchemaV2.self),
         .lightweight(fromVersion: ActivitySchemaV2.self, toVersion: ActivitySchemaV3.self),
         .lightweight(fromVersion: ActivitySchemaV3.self, toVersion: ActivitySchemaV4.self),
         .lightweight(fromVersion: ActivitySchemaV4.self, toVersion: ActivitySchemaV5.self)]
    }
}

private enum ThroughVersionSixMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ActivitySchemaV1.self, ActivitySchemaV2.self, ActivitySchemaV3.self, ActivitySchemaV4.self, ActivitySchemaV5.self, ActivitySchemaV6.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: ActivitySchemaV1.self, toVersion: ActivitySchemaV2.self),
         .lightweight(fromVersion: ActivitySchemaV2.self, toVersion: ActivitySchemaV3.self),
         .lightweight(fromVersion: ActivitySchemaV3.self, toVersion: ActivitySchemaV4.self),
         .lightweight(fromVersion: ActivitySchemaV4.self, toVersion: ActivitySchemaV5.self),
         .lightweight(fromVersion: ActivitySchemaV5.self, toVersion: ActivitySchemaV6.self)]
    }
}

private enum ThroughVersionSevenMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ActivitySchemaV1.self, ActivitySchemaV2.self, ActivitySchemaV3.self, ActivitySchemaV4.self, ActivitySchemaV5.self, ActivitySchemaV6.self, ActivitySchemaV7.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: ActivitySchemaV1.self, toVersion: ActivitySchemaV2.self),
         .lightweight(fromVersion: ActivitySchemaV2.self, toVersion: ActivitySchemaV3.self),
         .lightweight(fromVersion: ActivitySchemaV3.self, toVersion: ActivitySchemaV4.self),
         .lightweight(fromVersion: ActivitySchemaV4.self, toVersion: ActivitySchemaV5.self),
         .lightweight(fromVersion: ActivitySchemaV5.self, toVersion: ActivitySchemaV6.self),
         .lightweight(fromVersion: ActivitySchemaV6.self, toVersion: ActivitySchemaV7.self)]
    }
}

private enum ThroughVersionEightMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ActivitySchemaV1.self, ActivitySchemaV2.self, ActivitySchemaV3.self, ActivitySchemaV4.self, ActivitySchemaV5.self, ActivitySchemaV6.self, ActivitySchemaV7.self, ActivitySchemaV8.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: ActivitySchemaV1.self, toVersion: ActivitySchemaV2.self),
         .lightweight(fromVersion: ActivitySchemaV2.self, toVersion: ActivitySchemaV3.self),
         .lightweight(fromVersion: ActivitySchemaV3.self, toVersion: ActivitySchemaV4.self),
         .lightweight(fromVersion: ActivitySchemaV4.self, toVersion: ActivitySchemaV5.self),
         .lightweight(fromVersion: ActivitySchemaV5.self, toVersion: ActivitySchemaV6.self),
         .lightweight(fromVersion: ActivitySchemaV6.self, toVersion: ActivitySchemaV7.self),
         .lightweight(fromVersion: ActivitySchemaV7.self, toVersion: ActivitySchemaV8.self)]
    }
}

private struct MigrationFixture: Sendable {
    let summary: ActivitySummary
    let track: RecordedTrack
    let active: ActiveRecording
    let activeTrack: RecordedTrack
    let analysis: ActivityAnalysis

    static func create(at url: URL) async throws -> Self {
        try await Task.detached {
            let schema = Schema(versionedSchema: ActivitySchemaV1.self)
            let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
            context.autosaveEnabled = false
            let saved = ActivitySchemaV1.StoredActivity(id: "saved-v1", startedAt: 1_000, status: .completed, origin: .deviceRecording)
            saved.lastPointAtMilliseconds = 80_000; saved.completedAtMilliseconds = 90_000
            saved.pointCount = 3; saved.sourceRevision = 7
            context.insert(saved)
            let first = ActivitySchemaV1.StoredTrackSegment(id: "first-v1", ordinal: 0, boundary: .recordingStarted, activity: saved)
            first.recordingStartedAtMilliseconds = 1_000; first.recordingStoppedAtMilliseconds = 30_000
            let firstPoints = [
                try TrackPoint(timestampMilliseconds: 1_001, latitude: 47.01, longitude: 11.01, elevationMeters: 2_000),
                try TrackPoint(timestampMilliseconds: 20_002, latitude: 47.02, longitude: 11.02, elevationMeters: nil)
            ]
            context.insert(first)
            first.points = firstPoints.map { ActivitySchemaV1.StoredTrackPoint(point: $0, activityID: "saved-v1") }
            let second = ActivitySchemaV1.StoredTrackSegment(id: "second-v1", ordinal: 1, boundary: .recordingResumed, activity: saved)
            second.recordingStartedAtMilliseconds = 70_000; second.recordingStoppedAtMilliseconds = 85_000
            let secondPoints = [try TrackPoint(timestampMilliseconds: 80_000, latitude: 47.03, longitude: 11.03, elevationMeters: 1_970)]
            context.insert(second)
            second.points = secondPoints.map { ActivitySchemaV1.StoredTrackPoint(point: $0, activityID: "saved-v1") }
            let summary = try saved.summary()
            let track = RecordedTrack(activityID: summary.id, sourceRevision: summary.sourceRevision, segments: [
                TrackSegment(id: "first-v1", ordinal: 0, boundary: .recordingStarted, recordingStartedAt: 1_000,
                             recordingStoppedAt: 30_000, points: firstPoints),
                TrackSegment(id: "second-v1", ordinal: 1, boundary: .recordingResumed, recordingStartedAt: 70_000,
                             recordingStoppedAt: 85_000, points: secondPoints)
            ])
            var statistics = ActivityStatistics()
            statistics.distanceMeters = 321
            let analysis = ActivityAnalysis(activityID: summary.id, sourceRevision: summary.sourceRevision,
                processingVersion: 2, processedAt: 90_000, statistics: statistics, thumbnailPNG: Data(repeating: 17, count: 200_000))
            context.insert(ActivitySchemaV1.StoredActivityAnalysis(analysis, activity: saved))
            let recording = ActivitySchemaV1.StoredActivity(id: "active-v1", startedAt: 100_000, status: .paused, origin: .deviceRecording)
            recording.lastPointAtMilliseconds = 110_000; recording.pointCount = 1; recording.sourceRevision = 3
            recording.currentSegmentID = "active-segment-v1"
            context.insert(recording)
            let segment = ActivitySchemaV1.StoredTrackSegment(id: "active-segment-v1", ordinal: 0, boundary: .recordingStarted, activity: recording)
            segment.recordingStartedAtMilliseconds = 100_000; segment.recordingStoppedAtMilliseconds = 120_000
            let points = [try TrackPoint(timestampMilliseconds: 110_000, latitude: 48.01, longitude: 12.01, elevationMeters: 1_234.5)]
            context.insert(segment)
            segment.points = points.map { ActivitySchemaV1.StoredTrackPoint(point: $0, activityID: "active-v1") }
            let active = ActiveRecording(summary: try recording.summary(), phase: .paused, segmentID: "active-segment-v1", recordingStartedAt: 100_000)
            let activeTrack = RecordedTrack(activityID: active.id, sourceRevision: active.summary.sourceRevision, segments: [
                TrackSegment(id: active.segmentID, ordinal: 0, boundary: .recordingStarted, recordingStartedAt: 100_000,
                             recordingStoppedAt: 120_000, points: points)
            ])
            try context.save()
            return Self(summary: summary, track: track, active: active, activeTrack: activeTrack, analysis: analysis)
        }.value
    }
}

struct ActivityMigrationTests {
    private func storeURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("migration.store")
    }

    @Test func versionOneMigrationPreservesRecordingsAndRebuildsCountsOnce() async throws {
        let url = try storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try await MigrationFixture.create(at: url)
        let repository = try await ActivityRepository.open(url: url, clock: { 130_000 })
        #expect(try await repository.summaries() == [original.summary])
        #expect(try await repository.recordedTrack(id: original.summary.id) == original.track)
        #expect(try await repository.active() == original.active)
        #expect(try await repository.recordedTrack(id: original.active.id) == original.activeTrack)
        #expect(try await repository.storedAnalysis(id: original.summary.id) == original.analysis)
        #expect(!original.analysis.isCurrent(for: original.summary))
        let processor = ActivityProcessor(repository: repository, clock: { 140_000 }, calculate: { _ in
            var statistics = ActivityStatistics()
            statistics.runCount = 3; statistics.liftCount = 2
            return (statistics, Data([1, 2, 3]), .init(), .init())
        })
        let processed = try await processor.process(id: original.summary.id)
        #expect(processed.statistics.runCount == 3)
        #expect(processed.statistics.liftCount == 2)
        #expect(processed.processedAt == 140_000)
        #expect(processed.isCurrent(for: original.summary))
        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: original.summary.id) == processed)
        #expect(try await reopened.recordedTrack(id: original.summary.id) == original.track)
        #expect(try await reopened.active() == original.active)
        try await Task.detached {
            let schema = Schema(versionedSchema: ActivitySchemaV1.self)
            let configuration = ModelConfiguration("Activities", schema: schema, url: ActivityMigration.backupURL(for: url),
                allowsSave: false, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
            let analysis = try #require(context.fetch(FetchDescriptor<ActivitySchemaV1.StoredActivityAnalysis>()).first)
            #expect(try analysis.result() == original.analysis)
            #expect(try context.fetchCount(FetchDescriptor<ActivitySchemaV1.StoredTrackPoint>()) == 4)
        }.value
    }

    @Test func interruptedMigrationVerifiesTheBackupBeforeOpening() async throws {
        let url = try storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try await MigrationFixture.create(at: url)
        try await Task.detached {
            _ = try ActivityMigration.prepare(at: url)
            let schema = Schema(versionedSchema: ActivitySchemaV9.self)
            let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
            _ = try ModelContainer(for: schema, migrationPlan: ActivityMigrationPlan.self, configurations: [configuration])
        }.value
        let repository = try await ActivityRepository.open(url: url)
        #expect(try await repository.recordedTrack(id: original.summary.id) == original.track)
        #expect(try await repository.active() == original.active)
    }

    @Test func versionTwoMigrationPreservesCountsAndRebuildsAverageSpeedOnce() async throws {
        let url = try storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try await MigrationFixture.create(at: url)
        let previousAnalysis = try await Task.detached {
            let schema = Schema(versionedSchema: ActivitySchemaV2.self)
            let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, migrationPlan: PreviousActivityMigrationPlan.self, configurations: [configuration]))
            let stored = try #require(context.fetch(FetchDescriptor<ActivitySchemaV2.StoredActivityAnalysis>()).first)
            stored.runCount = 3; stored.liftCount = 2; stored.processingVersion = 3
            try context.save()
            return try stored.result()
        }.value
        let repository = try await ActivityRepository.open(url: url)
        #expect(try await repository.recordedTrack(id: original.summary.id) == original.track)
        #expect(try await repository.recordedTrack(id: original.active.id) == original.activeTrack)
        #expect(try await repository.active() == original.active)
        #expect(try await repository.storedAnalysis(id: original.summary.id) == previousAnalysis)
        #expect(previousAnalysis.statistics.runCount == 3)
        #expect(previousAnalysis.statistics.liftCount == 2)
        #expect(previousAnalysis.statistics.averageDownhillSpeedMetersPerSecond == nil)
        #expect(!previousAnalysis.isCurrent(for: original.summary))
        let processor = ActivityProcessor(repository: repository, calculate: { _ in
            var statistics = previousAnalysis.statistics
            statistics.averageDownhillSpeedMetersPerSecond = 8.5
            return (statistics, previousAnalysis.thumbnailPNG, .init(), .init())
        })
        let processed = try await processor.process(id: original.summary.id)
        #expect(processed.statistics.averageDownhillSpeedMetersPerSecond == 8.5)
        #expect(processed.isCurrent(for: original.summary))
        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: original.summary.id) == processed)
        try await Task.detached {
            let schema = Schema(versionedSchema: ActivitySchemaV2.self)
            let configuration = ModelConfiguration("Activities", schema: schema,
                url: ActivityMigration.backupURL(for: url, sourceVersion: 2), allowsSave: false, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
            let stored = try #require(context.fetch(FetchDescriptor<ActivitySchemaV2.StoredActivityAnalysis>()).first)
            #expect(try stored.result() == previousAnalysis)
        }.value
    }

    @Test(arguments: [false, true], [2, 3, 4, 5, 6, 7, 8])
    func latestUpgradeRetainsVerificationOfInterruptedMigrations(changePoint: Bool, intermediateVersion: Int) async throws {
        let url = try storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try await MigrationFixture.create(at: url)
        try await Task.detached {
            _ = try ActivityMigration.prepare(at: url)
            let schema = Schema(versionedSchema: ActivitySchemaV2.self)
            let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, migrationPlan: PreviousActivityMigrationPlan.self, configurations: [configuration])
            if changePoint && intermediateVersion == 2 {
                let context = ModelContext(container)
                let point = try #require(context.fetch(FetchDescriptor<ActivitySchemaV2.StoredTrackPoint>()).first)
                point.elevationMeters = 9_999
                try context.save()
            }
        }.value
        if intermediateVersion >= 3 {
            try await Task.detached {
                _ = try ActivityMigration.prepare(at: url)
                let schema = Schema(versionedSchema: ActivitySchemaV3.self)
                let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
                let container = try ModelContainer(for: schema, migrationPlan: ThroughVersionThreeMigrationPlan.self, configurations: [configuration])
                if changePoint && intermediateVersion == 3 {
                    let context = ModelContext(container)
                    let point = try #require(context.fetch(FetchDescriptor<ActivitySchemaV3.StoredTrackPoint>()).first)
                    point.elevationMeters = 9_999
                    try context.save()
                }
            }.value
        }
        if intermediateVersion >= 4 {
            try await Task.detached {
                _ = try ActivityMigration.prepare(at: url)
                let schema = Schema(versionedSchema: ActivitySchemaV4.self)
                let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
                let container = try ModelContainer(for: schema, migrationPlan: ThroughVersionFourMigrationPlan.self, configurations: [configuration])
                if changePoint && intermediateVersion == 4 {
                    let context = ModelContext(container)
                    let point = try #require(context.fetch(FetchDescriptor<ActivitySchemaV4.StoredTrackPoint>()).first)
                    point.elevationMeters = 9_999
                    try context.save()
                }
            }.value
        }
        if intermediateVersion >= 5 {
            try await Task.detached {
                _ = try ActivityMigration.prepare(at: url)
                let schema = Schema(versionedSchema: ActivitySchemaV5.self)
                let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
                let container = try ModelContainer(for: schema, migrationPlan: ThroughVersionFiveMigrationPlan.self, configurations: [configuration])
                if changePoint && intermediateVersion == 5 {
                    let context = ModelContext(container)
                    let point = try #require(context.fetch(FetchDescriptor<ActivitySchemaV5.StoredTrackPoint>()).first)
                    point.elevationMeters = 9_999
                    try context.save()
                }
            }.value
        }
        if intermediateVersion >= 6 {
            try await Task.detached {
                _ = try ActivityMigration.prepare(at: url)
                let schema = Schema(versionedSchema: ActivitySchemaV6.self)
                let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
                let container = try ModelContainer(for: schema, migrationPlan: ThroughVersionSixMigrationPlan.self, configurations: [configuration])
                if changePoint && intermediateVersion == 6 {
                    let context = ModelContext(container)
                    let point = try #require(context.fetch(FetchDescriptor<ActivitySchemaV6.StoredTrackPoint>()).first)
                    point.elevationMeters = 9_999
                    try context.save()
                }
            }.value
        }
        if intermediateVersion >= 7 {
            try await Task.detached {
                _ = try ActivityMigration.prepare(at: url)
                let schema = Schema(versionedSchema: ActivitySchemaV7.self)
                let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
                let container = try ModelContainer(for: schema, migrationPlan: ThroughVersionSevenMigrationPlan.self, configurations: [configuration])
                if changePoint && intermediateVersion == 7 {
                    let context = ModelContext(container)
                    let point = try #require(context.fetch(FetchDescriptor<ActivitySchemaV7.StoredTrackPoint>()).first)
                    point.elevationMeters = 9_999
                    try context.save()
                }
            }.value
        }
        if intermediateVersion == 8 {
            try await Task.detached {
                _ = try ActivityMigration.prepare(at: url)
                let schema = Schema(versionedSchema: ActivitySchemaV8.self)
                let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
                let container = try ModelContainer(for: schema, migrationPlan: ThroughVersionEightMigrationPlan.self, configurations: [configuration])
                if changePoint {
                    let context = ModelContext(container)
                    let point = try #require(context.fetch(FetchDescriptor<ActivitySchemaV8.StoredTrackPoint>()).first)
                    point.elevationMeters = 9_999
                    try context.save()
                }
            }.value
        }
        if changePoint {
            await #expect(throws: ActivityError.self) { try await ActivityRepository.open(url: url) }
            await #expect(throws: ActivityError.self) { try await ActivityRepository.open(url: url) }
        } else {
            let repository = try await ActivityRepository.open(url: url)
            #expect(try await repository.recordedTrack(id: original.summary.id) == original.track)
            #expect(try await repository.active() == original.active)
        }
        for version in 1...intermediateVersion {
            #expect(FileManager.default.fileExists(atPath: ActivityMigration.backupURL(for: url, sourceVersion: version).path))
        }
    }

    @Test func versionThreeMigrationPreservesStatisticsAndRebuildsRunAndLiftTotalsOnce() async throws {
        let url = try storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try await MigrationFixture.create(at: url)
        let previousAnalysis = try await Task.detached {
            let schema = Schema(versionedSchema: ActivitySchemaV3.self)
            let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, migrationPlan: ThroughVersionThreeMigrationPlan.self, configurations: [configuration]))
            let stored = try #require(context.fetch(FetchDescriptor<ActivitySchemaV3.StoredActivityAnalysis>()).first)
            stored.runCount = 3; stored.liftCount = 2; stored.processingVersion = 4
            stored.averageDownhillSpeedMetersPerSecond = 8.5
            try context.save()
            return try stored.result()
        }.value
        let repository = try await ActivityRepository.open(url: url)
        #expect(try await repository.recordedTrack(id: original.summary.id) == original.track)
        #expect(try await repository.recordedTrack(id: original.active.id) == original.activeTrack)
        #expect(try await repository.active() == original.active)
        #expect(try await repository.storedAnalysis(id: original.summary.id) == previousAnalysis)
        #expect(!previousAnalysis.isCurrent(for: original.summary))
        let processor = ActivityProcessor(repository: repository, calculate: { _ in
            var statistics = previousAnalysis.statistics
            statistics.runDistanceMeters = 1_200.5; statistics.liftDistanceMeters = 800.25
            statistics.runDurationMilliseconds = 90_250; statistics.liftDurationMilliseconds = 160_500
            statistics.maximumRunSpeedMetersPerSecond = 15.75
            statistics.tallestRunHeightMeters = 300.5; statistics.longestRunDistanceMeters = 800.25
            return (statistics, previousAnalysis.thumbnailPNG, .init(), .init())
        })
        let processed = try await processor.process(id: original.summary.id)
        #expect(processed.statistics.runDistanceMeters == 1_200.5)
        #expect(processed.statistics.liftDistanceMeters == 800.25)
        #expect(processed.statistics.runDurationMilliseconds == 90_250)
        #expect(processed.statistics.liftDurationMilliseconds == 160_500)
        #expect(processed.statistics.maximumRunSpeedMetersPerSecond == 15.75)
        #expect(processed.statistics.tallestRunHeightMeters == 300.5)
        #expect(processed.statistics.longestRunDistanceMeters == 800.25)
        #expect(processed.isCurrent(for: original.summary))
        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: original.summary.id) == processed)
        try await Task.detached {
            let schema = Schema(versionedSchema: ActivitySchemaV3.self)
            let configuration = ModelConfiguration("Activities", schema: schema,
                url: ActivityMigration.backupURL(for: url, sourceVersion: 3), allowsSave: false, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
            let stored = try #require(context.fetch(FetchDescriptor<ActivitySchemaV3.StoredActivityAnalysis>()).first)
            #expect(try stored.result() == previousAnalysis)
            #expect(try context.fetchCount(FetchDescriptor<ActivitySchemaV3.StoredTrackPoint>()) == 4)
        }.value
    }

    @Test func versionFourMigrationPreservesStatisticsAndRebuildsAverageLiftSpeedOnce() async throws {
        let url = try storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try await MigrationFixture.create(at: url)
        let previousAnalysis = try await Task.detached {
            let schema = Schema(versionedSchema: ActivitySchemaV4.self)
            let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, migrationPlan: ThroughVersionFourMigrationPlan.self, configurations: [configuration]))
            let stored = try #require(context.fetch(FetchDescriptor<ActivitySchemaV4.StoredActivityAnalysis>()).first)
            stored.runCount = 3; stored.liftCount = 2; stored.processingVersion = 5
            stored.averageDownhillSpeedMetersPerSecond = 8.5
            stored.runDistanceMeters = 1_200.5; stored.liftDistanceMeters = 800
            stored.runDurationMilliseconds = 90_250; stored.liftDurationMilliseconds = 160_000
            stored.maximumRunSpeedMetersPerSecond = 15.75
            stored.tallestRunHeightMeters = 300.5; stored.longestRunDistanceMeters = 800.25
            try context.save()
            return try stored.result()
        }.value
        let repository = try await ActivityRepository.open(url: url)
        #expect(try await repository.recordedTrack(id: original.summary.id) == original.track)
        #expect(try await repository.recordedTrack(id: original.active.id) == original.activeTrack)
        #expect(try await repository.active() == original.active)
        #expect(try await repository.storedAnalysis(id: original.summary.id) == previousAnalysis)
        #expect(previousAnalysis.statistics.averageLiftSpeedMetersPerSecond == nil)
        #expect(!previousAnalysis.isCurrent(for: original.summary))
        let processor = ActivityProcessor(repository: repository, calculate: { _ in
            var statistics = previousAnalysis.statistics
            statistics.averageLiftSpeedMetersPerSecond = 5
            return (statistics, previousAnalysis.thumbnailPNG, .init(), .init())
        })
        let processed = try await processor.process(id: original.summary.id)
        #expect(processed.statistics.averageLiftSpeedMetersPerSecond == 5)
        #expect(processed.statistics.averageDownhillSpeedMetersPerSecond == 8.5)
        #expect(processed.isCurrent(for: original.summary))
        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: original.summary.id) == processed)
        try await Task.detached {
            let schema = Schema(versionedSchema: ActivitySchemaV4.self)
            let configuration = ModelConfiguration("Activities", schema: schema,
                url: ActivityMigration.backupURL(for: url, sourceVersion: 4), allowsSave: false, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
            let stored = try #require(context.fetch(FetchDescriptor<ActivitySchemaV4.StoredActivityAnalysis>()).first)
            #expect(try stored.result() == previousAnalysis)
            #expect(try context.fetchCount(FetchDescriptor<ActivitySchemaV4.StoredTrackPoint>()) == 4)
        }.value
    }

    @Test func versionFiveMigrationPreservesStatisticsAndRebuildsElevationAndLiftRecordsOnce() async throws {
        let url = try storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try await MigrationFixture.create(at: url)
        let previousAnalysis = try await Task.detached {
            let schema = Schema(versionedSchema: ActivitySchemaV5.self)
            let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, migrationPlan: ThroughVersionFiveMigrationPlan.self, configurations: [configuration]))
            let stored = try #require(context.fetch(FetchDescriptor<ActivitySchemaV5.StoredActivityAnalysis>()).first)
            stored.runCount = 3; stored.liftCount = 2; stored.processingVersion = 6
            stored.averageDownhillSpeedMetersPerSecond = 8.5
            stored.averageLiftSpeedMetersPerSecond = 5
            stored.runDistanceMeters = 1_200.5; stored.liftDistanceMeters = 800
            stored.runDurationMilliseconds = 90_250; stored.liftDurationMilliseconds = 160_000
            stored.maximumRunSpeedMetersPerSecond = 15.75
            stored.tallestRunHeightMeters = 300.5; stored.longestRunDistanceMeters = 800.25
            try context.save()
            return try stored.result()
        }.value
        let repository = try await ActivityRepository.open(url: url)
        #expect(try await repository.recordedTrack(id: original.summary.id) == original.track)
        #expect(try await repository.recordedTrack(id: original.active.id) == original.activeTrack)
        #expect(try await repository.active() == original.active)
        #expect(try await repository.storedAnalysis(id: original.summary.id) == previousAnalysis)
        #expect(previousAnalysis.statistics.runElevationLossMeters == 0)
        #expect(previousAnalysis.statistics.liftElevationGainMeters == 0)
        #expect(previousAnalysis.statistics.tallestLiftHeightMeters == nil)
        #expect(previousAnalysis.statistics.longestLiftDistanceMeters == nil)
        #expect(!previousAnalysis.isCurrent(for: original.summary))
        let processor = ActivityProcessor(repository: repository, calculate: { _ in
            var statistics = previousAnalysis.statistics
            statistics.runElevationLossMeters = 430.5; statistics.liftElevationGainMeters = 400.25
            statistics.tallestLiftHeightMeters = 300.5; statistics.longestLiftDistanceMeters = 600.25
            return (statistics, previousAnalysis.thumbnailPNG, .init(), .init())
        })
        let processed = try await processor.process(id: original.summary.id)
        #expect(processed.statistics.runElevationLossMeters == 430.5)
        #expect(processed.statistics.liftElevationGainMeters == 400.25)
        #expect(processed.statistics.tallestLiftHeightMeters == 300.5)
        #expect(processed.statistics.longestLiftDistanceMeters == 600.25)
        #expect(processed.statistics.averageLiftSpeedMetersPerSecond == 5)
        #expect(processed.statistics.averageDownhillSpeedMetersPerSecond == 8.5)
        #expect(processed.isCurrent(for: original.summary))
        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: original.summary.id) == processed)
        try await Task.detached {
            let schema = Schema(versionedSchema: ActivitySchemaV5.self)
            let configuration = ModelConfiguration("Activities", schema: schema,
                url: ActivityMigration.backupURL(for: url, sourceVersion: 5), allowsSave: false, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
            let stored = try #require(context.fetch(FetchDescriptor<ActivitySchemaV5.StoredActivityAnalysis>()).first)
            #expect(try stored.result() == previousAnalysis)
            #expect(try context.fetchCount(FetchDescriptor<ActivitySchemaV5.StoredTrackPoint>()) == 4)
        }.value
    }

    @Test func versionSixMigrationPreservesStatisticsAndRebuildsPassageRangesOnce() async throws {
        let url = try storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try await MigrationFixture.create(at: url)
        let previousAnalysis = try await Task.detached {
            let schema = Schema(versionedSchema: ActivitySchemaV6.self)
            let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, migrationPlan: ThroughVersionSixMigrationPlan.self, configurations: [configuration]))
            let stored = try #require(context.fetch(FetchDescriptor<ActivitySchemaV6.StoredActivityAnalysis>()).first)
            stored.runCount = 3; stored.liftCount = 2; stored.processingVersion = 7
            stored.averageDownhillSpeedMetersPerSecond = 8.5
            stored.averageLiftSpeedMetersPerSecond = 5
            stored.runDistanceMeters = 1_200.5; stored.liftDistanceMeters = 800
            stored.runDurationMilliseconds = 90_250; stored.liftDurationMilliseconds = 160_000
            stored.maximumRunSpeedMetersPerSecond = 15.75
            stored.tallestRunHeightMeters = 300.5; stored.longestRunDistanceMeters = 800.25
            stored.runElevationLossMeters = 430.5; stored.liftElevationGainMeters = 400.25
            stored.tallestLiftHeightMeters = 300.5; stored.longestLiftDistanceMeters = 600.25
            try context.save()
            return try stored.result()
        }.value
        let repository = try await ActivityRepository.open(url: url)
        #expect(try await repository.recordedTrack(id: original.summary.id) == original.track)
        #expect(try await repository.recordedTrack(id: original.active.id) == original.activeTrack)
        #expect(try await repository.active() == original.active)
        #expect(try await repository.storedAnalysis(id: original.summary.id) == previousAnalysis)
        #expect(previousAnalysis.passages == nil)
        #expect(!previousAnalysis.isCurrent(for: original.summary))
        let passages = SkiActivityDetector.Result(
            runs: [.init(startedAt: 1_001, endedAt: 10_000), .init(startedAt: 20_000, endedAt: 30_000), .init(startedAt: 70_000, endedAt: 80_000)],
            lifts: [.init(startedAt: 10_000, endedAt: 20_000), .init(startedAt: 30_000, endedAt: 70_000)])
        let processor = ActivityProcessor(repository: repository, calculate: { _ in
            (previousAnalysis.statistics, previousAnalysis.thumbnailPNG, passages, .init())
        })
        let processed = try await processor.process(id: original.summary.id)
        #expect(processed.passages == passages)
        #expect(processed.statistics == previousAnalysis.statistics)
        #expect(processed.statistics.runElevationLossMeters == 430.5)
        #expect(processed.statistics.liftElevationGainMeters == 400.25)
        #expect(processed.statistics.tallestLiftHeightMeters == 300.5)
        #expect(processed.statistics.longestLiftDistanceMeters == 600.25)
        #expect(processed.statistics.averageLiftSpeedMetersPerSecond == 5)
        #expect(processed.statistics.averageDownhillSpeedMetersPerSecond == 8.5)
        #expect(processed.isCurrent(for: original.summary))
        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: original.summary.id) == processed)
        try await Task.detached {
            let schema = Schema(versionedSchema: ActivitySchemaV6.self)
            let configuration = ModelConfiguration("Activities", schema: schema,
                url: ActivityMigration.backupURL(for: url, sourceVersion: 6), allowsSave: false, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
            let stored = try #require(context.fetch(FetchDescriptor<ActivitySchemaV6.StoredActivityAnalysis>()).first)
            #expect(try stored.result() == previousAnalysis)
            #expect(try context.fetchCount(FetchDescriptor<ActivitySchemaV6.StoredTrackPoint>()) == 4)
        }.value
    }

    @Test func versionSevenMigrationPreservesStatisticsAndPassagesAndRebuildsSteepnessOnce() async throws {
        let url = try storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try await MigrationFixture.create(at: url)
        let passages = SkiActivityDetector.Result(
            runs: [.init(startedAt: 1_001, endedAt: 10_000), .init(startedAt: 20_000, endedAt: 30_000), .init(startedAt: 70_000, endedAt: 80_000)],
            lifts: [.init(startedAt: 10_000, endedAt: 20_000), .init(startedAt: 30_000, endedAt: 70_000)])
        let previousAnalysis = try await Task.detached {
            let schema = Schema(versionedSchema: ActivitySchemaV7.self)
            let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, migrationPlan: ThroughVersionSevenMigrationPlan.self, configurations: [configuration]))
            let stored = try #require(context.fetch(FetchDescriptor<ActivitySchemaV7.StoredActivityAnalysis>()).first)
            stored.runCount = 3; stored.liftCount = 2; stored.processingVersion = 8
            stored.averageDownhillSpeedMetersPerSecond = 8.5
            stored.averageLiftSpeedMetersPerSecond = 5
            stored.runDistanceMeters = 1_200.5; stored.liftDistanceMeters = 800
            stored.runDurationMilliseconds = 90_250; stored.liftDurationMilliseconds = 160_000
            stored.maximumRunSpeedMetersPerSecond = 15.75
            stored.tallestRunHeightMeters = 300.5; stored.longestRunDistanceMeters = 800.25
            stored.runElevationLossMeters = 430.5; stored.liftElevationGainMeters = 400.25
            stored.tallestLiftHeightMeters = 300.5; stored.longestLiftDistanceMeters = 600.25
            stored.passagesJSON = try JSONEncoder().encode(passages)
            try context.save()
            return try stored.result()
        }.value
        let repository = try await ActivityRepository.open(url: url)
        #expect(try await repository.recordedTrack(id: original.summary.id) == original.track)
        #expect(try await repository.recordedTrack(id: original.active.id) == original.activeTrack)
        #expect(try await repository.active() == original.active)
        let migrated = try #require(try await repository.storedAnalysis(id: original.summary.id))
        #expect(migrated == previousAnalysis)
        #expect(migrated.passages == passages)
        #expect(migrated.statistics.averageRunSteepnessPercent == nil)
        #expect(migrated.statistics.averageLiftSteepnessPercent == nil)
        #expect(migrated.statistics.maximumRunSteepnessPercent == nil)
        #expect(migrated.statistics.maximumLiftSteepnessPercent == nil)
        #expect(!migrated.isCurrent(for: original.summary))
        var statistics = previousAnalysis.statistics
        statistics.averageRunSteepnessPercent = 12.5; statistics.averageLiftSteepnessPercent = 25.75
        statistics.maximumRunSteepnessPercent = 31.25; statistics.maximumLiftSteepnessPercent = 40.5
        let expectedStatistics = statistics
        let processor = ActivityProcessor(repository: repository, calculate: { _ in
            (expectedStatistics, previousAnalysis.thumbnailPNG, passages, .init())
        })
        let processed = try await processor.process(id: original.summary.id)
        #expect(processed.statistics == expectedStatistics)
        #expect(processed.passages == passages)
        #expect(processed.isCurrent(for: original.summary))
        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: original.summary.id) == processed)
        #expect(try await reopened.recordedTrack(id: original.summary.id) == original.track)
        #expect(try await reopened.active() == original.active)
        try await Task.detached {
            let schema = Schema(versionedSchema: ActivitySchemaV7.self)
            let configuration = ModelConfiguration("Activities", schema: schema,
                url: ActivityMigration.backupURL(for: url, sourceVersion: 7), allowsSave: false, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
            let stored = try #require(context.fetch(FetchDescriptor<ActivitySchemaV7.StoredActivityAnalysis>()).first)
            #expect(try stored.result() == previousAnalysis)
            #expect(try context.fetchCount(FetchDescriptor<ActivitySchemaV7.StoredTrackPoint>()) == 4)
        }.value
    }

    @Test func versionEightMigrationPreservesStatisticsAndPassagesAndRebuildsTimelineOnce() async throws {
        let url = try storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try await MigrationFixture.create(at: url)
        let passages = SkiActivityDetector.Result(
            runs: [.init(startedAt: 1_001, endedAt: 10_000), .init(startedAt: 20_000, endedAt: 30_000), .init(startedAt: 70_000, endedAt: 80_000)],
            lifts: [.init(startedAt: 10_000, endedAt: 20_000), .init(startedAt: 30_000, endedAt: 70_000)])
        let previousAnalysis = try await Task.detached {
            let schema = Schema(versionedSchema: ActivitySchemaV8.self)
            let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, migrationPlan: ThroughVersionEightMigrationPlan.self, configurations: [configuration]))
            let stored = try #require(context.fetch(FetchDescriptor<ActivitySchemaV8.StoredActivityAnalysis>()).first)
            stored.runCount = 3; stored.liftCount = 2; stored.processingVersion = 9
            stored.averageDownhillSpeedMetersPerSecond = 8.5
            stored.averageLiftSpeedMetersPerSecond = 5
            stored.runDistanceMeters = 1_200.5; stored.liftDistanceMeters = 800
            stored.runDurationMilliseconds = 90_250; stored.liftDurationMilliseconds = 160_000
            stored.maximumRunSpeedMetersPerSecond = 15.75
            stored.tallestRunHeightMeters = 300.5; stored.longestRunDistanceMeters = 800.25
            stored.runElevationLossMeters = 430.5; stored.liftElevationGainMeters = 400.25
            stored.tallestLiftHeightMeters = 300.5; stored.longestLiftDistanceMeters = 600.25
            stored.averageRunSteepnessPercent = 12.5; stored.averageLiftSteepnessPercent = 25.75
            stored.maximumRunSteepnessPercent = 31.25; stored.maximumLiftSteepnessPercent = 40.5
            stored.passagesJSON = try JSONEncoder().encode(passages)
            try context.save()
            return try stored.result()
        }.value
        let repository = try await ActivityRepository.open(url: url)
        #expect(try await repository.recordedTrack(id: original.summary.id) == original.track)
        #expect(try await repository.recordedTrack(id: original.active.id) == original.activeTrack)
        #expect(try await repository.active() == original.active)
        let migrated = try #require(try await repository.storedAnalysis(id: original.summary.id))
        #expect(migrated == previousAnalysis)
        #expect(migrated.passages == passages)
        #expect(migrated.statistics.averageRunSteepnessPercent == 12.5)
        #expect(migrated.statistics.averageLiftSteepnessPercent == 25.75)
        #expect(migrated.statistics.maximumRunSteepnessPercent == 31.25)
        #expect(migrated.statistics.maximumLiftSteepnessPercent == 40.5)
        #expect(migrated.timeline == nil)
        #expect(!migrated.isCurrent(for: original.summary))
        var counts = [Int](repeating: 0, count: 30)
        counts[19] = 1
        let timeline = ActivityTimeline(entries: [
            ActivityTimelineEntry(kind: .run, startedAt: 1_001, endedAt: 20_002, distanceMeters: 321.5, elevationGainMeters: nil, elevationLossMeters: nil,
                                  quality: ActivityTimelineQuality(level: .low, maximumSampleIntervalMilliseconds: 19_001,
                                    sampleGapHistogram: SampleGapHistogram(binWidthMilliseconds: 1_000, counts: counts)), pointCount: 2)
        ], breaks: [ActivityTimelineBreak(startedAt: 20_002, endedAt: 80_000, reason: .sourceBoundary)])
        let processor = ActivityProcessor(repository: repository, calculate: { _ in
            (previousAnalysis.statistics, previousAnalysis.thumbnailPNG, passages, timeline)
        })
        let processed = try await processor.process(id: original.summary.id)
        #expect(processed.statistics == previousAnalysis.statistics)
        #expect(processed.timeline == timeline)
        #expect(processed.passages == passages)
        #expect(processed.isCurrent(for: original.summary))
        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: original.summary.id) == processed)
        #expect(try await reopened.recordedTrack(id: original.summary.id) == original.track)
        #expect(try await reopened.active() == original.active)
        try await Task.detached {
            let schema = Schema(versionedSchema: ActivitySchemaV8.self)
            let configuration = ModelConfiguration("Activities", schema: schema,
                url: ActivityMigration.backupURL(for: url, sourceVersion: 8), allowsSave: false, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
            let stored = try #require(context.fetch(FetchDescriptor<ActivitySchemaV8.StoredActivityAnalysis>()).first)
            #expect(try stored.result() == previousAnalysis)
            #expect(try context.fetchCount(FetchDescriptor<ActivitySchemaV8.StoredTrackPoint>()) == 4)
        }.value
    }

    @Test func changedObservationsAfterInterruptedMigrationKeepOpeningBlocked() async throws {
        let url = try storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try await MigrationFixture.create(at: url)
        try await Task.detached {
            _ = try ActivityMigration.prepare(at: url)
            let schema = Schema(versionedSchema: ActivitySchemaV9.self)
            let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, migrationPlan: ActivityMigrationPlan.self, configurations: [configuration]))
            let point = try #require(context.fetch(FetchDescriptor<StoredTrackPoint>()).first)
            point.latitude += 0.1
            try context.save()
        }.value
        await #expect(throws: ActivityError.self) { try await ActivityRepository.open(url: url) }
        await #expect(throws: ActivityError.self) { try await ActivityRepository.open(url: url) }
        #expect(FileManager.default.fileExists(atPath: ActivityMigration.backupURL(for: url).path))
    }

    @Test(arguments: [false, true]) func verificationCoversPointsAcrossBatchesAndActivityBoundaries(changeLastPoint: Bool) async throws {
        let url = try storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await Task.detached {
            let countPerActivity = ActivityMigration.pointBatchSize + 3
            let schema = Schema(versionedSchema: ActivitySchemaV1.self)
            let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
            for id in ["first", "second"] {
                let activityID = ActivityID(rawValue: id)
                let activity = ActivitySchemaV1.StoredActivity(id: activityID, startedAt: 1_000, status: .completed, origin: .gpxImport)
                activity.pointCount = countPerActivity; activity.sourceRevision = 1
                activity.lastPointAtMilliseconds = Int64(1_000 + countPerActivity - 1)
                context.insert(activity)
                let segment = ActivitySchemaV1.StoredTrackSegment(ordinal: 0, boundary: .importedSegment, activity: activity)
                context.insert(segment)
                segment.points = try (0..<countPerActivity).map { index in
                    let point = try TrackPoint(timestampMilliseconds: Int64(1_000 + index), latitude: 47 + Double(index) / 100_000,
                        longitude: 11, elevationMeters: index.isMultiple(of: 7) ? nil : Double(index))
                    return ActivitySchemaV1.StoredTrackPoint(point: point, activityID: activityID)
                }
            }
            try context.save()
        }.value
        try await Task.detached {
            let original = try #require(try ActivityMigration.prepare(at: url))
            #expect(original.points.count == 2 * (ActivityMigration.pointBatchSize + 3))
            let schema = Schema(versionedSchema: ActivitySchemaV9.self)
            let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, migrationPlan: ActivityMigrationPlan.self, configurations: [configuration])
            if changeLastPoint {
                let context = ModelContext(container)
                var query = FetchDescriptor<StoredTrackPoint>(sortBy: [SortDescriptor(\.activityID, order: .reverse),
                    SortDescriptor(\.recordedAtMilliseconds, order: .reverse)])
                query.fetchLimit = 1
                let point = try #require(context.fetch(query).first)
                point.elevationMeters = 9_999
                try context.save()
                #expect(throws: ActivityError.self) { try ActivityMigration.verify(original, in: container, at: url) }
            } else {
                try ActivityMigration.verify(original, in: container, at: url)
                #expect(try ActivityMigration.prepare(at: url) == nil)
            }
        }.value
    }
}
