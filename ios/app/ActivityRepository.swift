import Foundation
import SwiftData

struct ActivityProcessingInput: Sendable {
    let activity: ActivitySummary
    let track: RecordedTrack
}

protocol ActivityPersistence: Actor {
    func start() async throws -> ActiveRecording
    func pause(id: ActivityID) async throws -> ActiveRecording
    func resume(id: ActivityID) async throws -> ActiveRecording
    func finish(id: ActivityID) async throws -> ActivitySummary
    func active() async throws -> ActiveRecording?
    func append(_ points: [TrackPoint], activityID: ActivityID) async throws -> ActiveRecording
    func summary(id: ActivityID) async throws -> ActivitySummary
    func summaries() async throws -> [ActivitySummary]
    func geometry(id: ActivityID) async throws -> TrackGeometry
    func details(id: ActivityID) async throws -> ActivityDetails
    func recordedTrack(id: ActivityID) async throws -> RecordedTrack
    func storedAnalysis(id: ActivityID) async throws -> ActivityAnalysis?
    func processingInput(id: ActivityID) async throws -> ActivityProcessingInput
    func saveAnalysis(_ result: ActivityAnalysis) async throws
    func importTracks(_ tracks: [GPXTrack]) async throws -> GPXImportResult
    func delete(id: ActivityID) async throws
    func discard(id: ActivityID) async throws
}

enum ActivityDatabase {
    static func container(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: ActivitySchemaV0.self)
        let configuration = ModelConfiguration("Activities", schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("Activities", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Activities.store")
    }
}

/// One writer and private context. SwiftData model objects never leave this actor.
@ModelActor actor ActivityRepository: ActivityPersistence {
    private var writeFailure: String?
    private var now: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    private var commit: @Sendable (ModelContext) throws -> Void = { try $0.save() }

    static func open(url: URL? = nil, clock: @escaping @Sendable () -> Int64 = {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }, commit: @escaping @Sendable (ModelContext) throws -> Void = { try $0.save() }) async throws -> ActivityRepository {
        try await Task.detached {
            let repository = ActivityRepository(modelContainer: try ActivityDatabase.container(at: url ?? ActivityDatabase.defaultURL()))
            await repository.configure(clock: clock, commit: commit)
            return repository
        }.value
    }

    private func configure(clock: @escaping @Sendable () -> Int64, commit: @escaping @Sendable (ModelContext) throws -> Void) {
        modelContext.autosaveEnabled = false; now = clock; self.commit = commit
    }

    private func write<T>(_ work: () throws -> T) throws -> T {
        if let writeFailure { throw ActivityError.storage(writeFailure) }
        do {
            let result = try work()
            if modelContext.hasChanges { try commit(modelContext) }
            return result
        } catch {
            modelContext.rollback()
            if error is CancellationError || error is ActivityError || error is GPXError { throw error }
            writeFailure = error.localizedDescription
            throw ActivityError.storage(error.localizedDescription)
        }
    }

    private func activity(_ id: ActivityID) throws -> StoredActivity {
        let rawID = id.rawValue
        var query = FetchDescriptor<StoredActivity>(predicate: #Predicate { $0.id == rawID })
        query.fetchLimit = 1
        guard let value = try modelContext.fetch(query).first else { throw ActivityError.missing }
        return value
    }

    private func openActivity() throws -> StoredActivity? {
        var query = FetchDescriptor<StoredActivity>(predicate: #Predicate { $0.statusRawValue != "completed" })
        query.fetchLimit = 2
        let values = try modelContext.fetch(query)
        guard values.count <= 1 else { throw ActivityError.multipleRecordings }
        return values.first
    }

    private func currentSegment(_ value: StoredActivity) throws -> StoredTrackSegment {
        guard let id = value.currentSegmentID else { throw ActivityError.invalidData("An open recording has no current segment.") }
        var query = FetchDescriptor<StoredTrackSegment>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        guard let segment = try modelContext.fetch(query).first, segment.activity?.id == value.id else {
            throw ActivityError.invalidData("The current segment has inconsistent ownership.")
        }
        return segment
    }

    private func recording(_ value: StoredActivity) throws -> ActiveRecording {
        let summary = try value.summary()
        guard let phase = RecordingPhase(rawValue: summary.status.rawValue) else { throw ActivityError.invalidTransition }
        let segment = try currentSegment(value)
        guard let startedAt = segment.recordingStartedAtMilliseconds else { throw ActivityError.invalidData("Missing recording interval.") }
        return ActiveRecording(summary: summary, phase: phase, segmentID: SegmentID(rawValue: segment.id),
                               recordingStartedAt: Timestamp(millisecondsSince1970: startedAt))
    }

    func active() throws -> ActiveRecording? { try openActivity().map(recording) }

    func start() throws -> ActiveRecording {
        try write {
            if let existing = try openActivity() { return try recording(existing) }
            let timestamp = now()
            let value = StoredActivity(startedAt: Timestamp(millisecondsSince1970: timestamp), status: .recording, origin: .deviceRecording)
            modelContext.insert(value)
            let segment = StoredTrackSegment(ordinal: 0, boundary: .recordingStarted, activity: value)
            segment.recordingStartedAtMilliseconds = timestamp
            modelContext.insert(segment); value.currentSegmentID = segment.id
            return try recording(value)
        }
    }

    func pause(id: ActivityID) throws -> ActiveRecording {
        try write {
            let value = try activity(id)
            guard value.statusRawValue != ActivityStatus.completed.rawValue else { throw ActivityError.invalidTransition }
            if value.statusRawValue == ActivityStatus.recording.rawValue {
                let segment = try currentSegment(value)
                segment.recordingStoppedAtMilliseconds = max(now(), value.lastPointAtMilliseconds ?? value.startedAtMilliseconds)
                value.statusRawValue = ActivityStatus.paused.rawValue; value.sourceRevision += 1
            }
            return try recording(value)
        }
    }

    func resume(id: ActivityID) throws -> ActiveRecording {
        try write {
            let value = try activity(id)
            guard value.statusRawValue != ActivityStatus.completed.rawValue else { throw ActivityError.invalidTransition }
            if value.statusRawValue == ActivityStatus.paused.rawValue {
                let previous = try currentSegment(value)
                let lowerBound = max(previous.recordingStoppedAtMilliseconds ?? 0, value.lastPointAtMilliseconds ?? value.startedAtMilliseconds)
                guard lowerBound < Int64.max else { throw ActivityError.invalidTransition }
                let segment = StoredTrackSegment(ordinal: previous.ordinal + 1, boundary: .recordingResumed, activity: value)
                segment.recordingStartedAtMilliseconds = max(now(), lowerBound + 1)
                modelContext.insert(segment); value.currentSegmentID = segment.id
                value.statusRawValue = ActivityStatus.recording.rawValue; value.sourceRevision += 1
            }
            return try recording(value)
        }
    }

    func finish(id: ActivityID) throws -> ActivitySummary {
        try write {
            let value = try activity(id)
            guard value.statusRawValue != ActivityStatus.recording.rawValue else { throw ActivityError.invalidTransition }
            if value.statusRawValue == ActivityStatus.paused.rawValue {
                value.statusRawValue = ActivityStatus.completed.rawValue
                value.completedAtMilliseconds = max(now(), value.lastPointAtMilliseconds ?? value.startedAtMilliseconds)
                value.currentSegmentID = nil; value.sourceRevision += 1
            }
            return try value.summary()
        }
    }

    func append(_ points: [TrackPoint], activityID: ActivityID) throws -> ActiveRecording {
        try write {
            let value = try activity(activityID)
            guard value.statusRawValue != ActivityStatus.completed.rawValue else { throw ActivityError.invalidTransition }
            let segment = try currentSegment(value)
            guard let startedAt = segment.recordingStartedAtMilliseconds else { throw ActivityError.invalidTransition }
            var distinct: [Int64: TrackPoint] = [:]
            for point in points {
                if let duplicate = distinct[point.timestampMilliseconds], duplicate != point {
                    throw ActivityError.conflictingPoint(point.timestampMilliseconds)
                }
                distinct[point.timestampMilliseconds] = point
            }
            let times = Array(distinct.keys), rawID = activityID.rawValue
            let existing = try modelContext.fetch(FetchDescriptor<StoredTrackPoint>(predicate: #Predicate {
                $0.activityID == rawID && times.contains($0.recordedAtMilliseconds)
            }))
            for stored in existing {
                guard try distinct[stored.recordedAtMilliseconds] == stored.point() else {
                    throw ActivityError.conflictingPoint(stored.recordedAtMilliseconds)
                }
                distinct.removeValue(forKey: stored.recordedAtMilliseconds)
            }
            for point in distinct.values {
                guard point.timestampMilliseconds >= startedAt,
                      point.timestampMilliseconds <= (segment.recordingStoppedAtMilliseconds ?? Int64.max) else { throw ActivityError.invalidPoint }
            }
            segment.points.append(contentsOf: distinct.values.map { StoredTrackPoint(point: $0, activityID: activityID) })
            for point in distinct.values {
                value.lastPointAtMilliseconds = max(value.lastPointAtMilliseconds ?? point.timestampMilliseconds, point.timestampMilliseconds)
            }
            value.pointCount += distinct.count
            if !distinct.isEmpty { value.sourceRevision += 1 }
            return try recording(value)
        }
    }

    func summary(id: ActivityID) throws -> ActivitySummary { try activity(id).summary() }

    func summaries() throws -> [ActivitySummary] {
        try modelContext.fetch(FetchDescriptor<StoredActivity>(predicate: #Predicate { $0.statusRawValue == "completed" },
            sortBy: [SortDescriptor(\.startedAtMilliseconds, order: .reverse), SortDescriptor(\.id)])).map { try $0.summary() }
    }

    func recordedTrack(id: ActivityID) throws -> RecordedTrack {
        let value = try activity(id), rawID = id.rawValue
        let segments = try modelContext.fetch(FetchDescriptor<StoredTrackSegment>(predicate: #Predicate { $0.activity?.id == rawID },
                                                                                 sortBy: [SortDescriptor(\.ordinal)]))
        let points = try modelContext.fetch(FetchDescriptor<StoredTrackPoint>(predicate: #Predicate { $0.activityID == rawID },
                                                                             sortBy: [SortDescriptor(\.recordedAtMilliseconds)]))
        guard points.count == value.pointCount else { throw ActivityError.invalidData("Point count does not match the stored track.") }
        var grouped: [String: [TrackPoint]] = [:]
        for point in points {
            guard let segment = point.segment else { throw ActivityError.invalidData("A point has no segment.") }
            grouped[segment.id, default: []].append(try point.point())
        }
        var ordinals = Set<Int>()
        let trackSegments = try segments.map { segment in
            guard ordinals.insert(segment.ordinal).inserted, let boundary = SegmentBoundary(rawValue: segment.boundaryRawValue) else {
                throw ActivityError.invalidData("Invalid segment metadata.")
            }
            return TrackSegment(id: SegmentID(rawValue: segment.id), ordinal: segment.ordinal, boundary: boundary,
                recordingStartedAt: segment.recordingStartedAtMilliseconds.map(Timestamp.init(millisecondsSince1970:)),
                recordingStoppedAt: segment.recordingStoppedAtMilliseconds.map(Timestamp.init(millisecondsSince1970:)),
                points: grouped[segment.id] ?? [])
        }
        return RecordedTrack(activityID: id, sourceRevision: value.sourceRevision, segments: trackSegments)
    }

    func geometry(id: ActivityID) async throws -> TrackGeometry {
        let track = try recordedTrack(id: id)
        return await Task.detached(priority: .userInitiated) { TrackContinuityPolicy.geometry(for: track) }.value
    }

    func details(id: ActivityID) async throws -> ActivityDetails {
        let summary = try activity(id).summary()
        let track = try recordedTrack(id: id)
        let geometry = await Task.detached(priority: .userInitiated) { TrackContinuityPolicy.geometry(for: track) }.value
        return ActivityDetails(activity: summary, geometry: geometry)
    }

    func storedAnalysis(id: ActivityID) throws -> ActivityAnalysis? { try activity(id).analysis?.result() }

    func processingInput(id: ActivityID) throws -> ActivityProcessingInput {
        let summary = try activity(id).summary()
        guard summary.status == .completed else { throw ActivityError.invalidTransition }
        return ActivityProcessingInput(activity: summary, track: try recordedTrack(id: id))
    }

    /// Derived writes have a separate transaction and never poison point intake.
    func saveAnalysis(_ result: ActivityAnalysis) throws {
        let value = try activity(result.activityID)
        guard value.statusRawValue == ActivityStatus.completed.rawValue, value.sourceRevision == result.sourceRevision else {
            throw ActivityError.staleAnalysis
        }
        do {
            if let existing = value.analysis { try existing.update(result) }
            else { modelContext.insert(try StoredActivityAnalysis(result, activity: value)) }
            try commit(modelContext)
        } catch { modelContext.rollback(); throw error }
    }

    func importTracks(_ tracks: [GPXTrack]) throws -> GPXImportResult {
        guard !tracks.isEmpty else { throw GPXError.noTracks }
        var count = 0
        for track in tracks {
            try Task.checkCancellation(); try track.validate()
            count += track.segments.reduce(0) { $0 + $1.points.count }
            guard count <= GPX.maximumPoints else { throw GPXError.tooLarge }
        }
        return try write {
            var imported: [ActivitySummary] = [], skipped = 0
            for track in tracks {
                try Task.checkCancellation()
                guard let first = track.segments.first?.points.first, let last = track.segments.last?.points.last else { throw ActivityError.invalidPoint }
                let pointCount = track.segments.reduce(0) { $0 + $1.points.count }, end = last.timestampMilliseconds
                let candidates = try modelContext.fetch(FetchDescriptor<StoredActivity>(predicate: #Predicate {
                    $0.statusRawValue == "completed" && $0.lastPointAtMilliseconds == end && $0.pointCount == pointCount
                }))
                var duplicate = false
                for candidate in candidates {
                    if try recordedTrack(id: ActivityID(rawValue: candidate.id)).gpx == track { duplicate = true; break }
                }
                if duplicate { skipped += 1; continue }
                let value = StoredActivity(startedAt: first.recordedAt, status: .completed, origin: .gpxImport)
                value.lastPointAtMilliseconds = end; value.importedAtMilliseconds = now()
                value.pointCount = pointCount; value.sourceRevision = 1
                modelContext.insert(value)
                for (index, source) in track.segments.enumerated() {
                    let segment = StoredTrackSegment(ordinal: index, boundary: .importedSegment, activity: value)
                    modelContext.insert(segment)
                    segment.points = try source.points.map { point in
                        try Task.checkCancellation()
                        return StoredTrackPoint(point: point, activityID: ActivityID(rawValue: value.id))
                    }
                }
                imported.append(try value.summary())
            }
            try Task.checkCancellation()
            return GPXImportResult(imported: imported, skipped: skipped)
        }
    }

    func delete(id: ActivityID) throws {
        try write {
            let value = try activity(id)
            guard value.statusRawValue == ActivityStatus.completed.rawValue else { throw ActivityError.invalidTransition }
            modelContext.delete(value)
        }
    }

    func discard(id: ActivityID) throws {
        try write {
            let value = try activity(id)
            guard value.statusRawValue == ActivityStatus.paused.rawValue else { throw ActivityError.invalidTransition }
            modelContext.delete(value)
        }
    }
}

#if DEBUG
extension ActivityRepository {
    func importSeed(from url: URL) async throws -> GPXImportResult {
        guard url.pathExtension.lowercased() == "gpx" else {
            throw GPXError.invalid("Choose a GPX seed file.")
        }
        let tracks = try await GPXFiles.read(url)
        guard try openActivity() == nil else { throw ActivityError.invalidTransition }
        return try importTracks(tracks)
    }
}
#endif
