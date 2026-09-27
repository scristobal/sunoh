import Foundation
import SQLite3
import Synchronization
import Testing
@testable import Sunoh

struct LiftDetectionProcessingTests {
    @Test func catalogEvidenceClassifiesAFlatLiftAndPersistsItsResortAssociation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createReferencePackages()
        let source = try track()
        let repository = try await ActivityRepository.open(url: fixture.storeURL)
        let activity = try #require(try await repository.importTracks([source]).imported.first)
        let geometry = try await repository.geometry(id: activity.id)
        #expect(SkiActivityDetector.analyze(geometry).lifts.isEmpty)
        let catalog = SkiDataCatalog(directory: fixture.referenceURL)
        let lookups = Mutex(0)
        let processor = ActivityProcessor(repository: repository, referenceData: { geometry in
            lookups.withLock { $0 += 1 }
            return try await SkiDataCatalog.referenceData(for: geometry, catalog: catalog)
        })

        let result = try await processor.process(id: activity.id)
        #expect(lookups.withLock { $0 } == 1)
        #expect(result.passages == SkiActivityDetector.Result(lifts: [.init(startedAt: 0, endedAt: 120_000)]))
        #expect(result.timeline?.entries.map(\.kind) == [.lift])
        #expect(result.statistics.runCount == 0)
        #expect(result.statistics.runDurationMilliseconds == 0)
        #expect(result.timeline?.entries.first?.durationMilliseconds == 120_000)
        #expect(abs((try #require(result.timeline?.entries.first?.distanceMeters)) - 360) < 0.001)
        #expect(result.timeline?.entries.first?.elevationGainMeters == 0)
        #expect(result.thumbnailPNG != nil)
        let matching = try #require(result.timeline?.skiMatches)
        #expect(matching.datasetVersion == "lift-processing-fixture")
        #expect(matching.failure == nil)
        #expect(matching.entries.first?.map(\.feature.id) == ["flat-lift"])
        #expect(try #require(matching.entries.first?.first).confidence > 0.99)
        #expect(matching.resorts.map(\.id) == ["valley"])
        #expect(matching.resorts.map(\.name) == ["Flat Valley"])
        #expect(try await repository.storedAnalysis(id: activity.id) == result)
        #expect(try await repository.recordedTrack(id: activity.id).gpx == source)

        let reopened = try await ActivityRepository.open(url: fixture.storeURL, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, referenceData: { _ in throw UnexpectedLookup.called })
        #expect(try await cached.process(id: activity.id) == result)
        #expect(try await reopened.recordedTrack(id: activity.id).gpx == source)
    }

    @Test(arguments: ["unavailable", "missing", "invalid-geometry", "nonoverlap"])
    func unsupportedReferenceDataPreservesTheTrackOnlyLiftAndOriginalObservations(condition: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        if condition == "invalid-geometry" { try fixture.createReferencePackages(invalidGeometry: true) }
        if condition == "nonoverlap" { try fixture.createReferencePackages(northOffsetMeters: 1_000) }
        let source = try track(climbRate: 1)
        let repository = try await ActivityRepository.open(url: fixture.storeURL)
        let activity = try #require(try await repository.importTracks([source]).imported.first)
        let geometry = try await repository.geometry(id: activity.id)
        let baseline = SkiActivityDetector.analyze(geometry)
        #expect(baseline.lifts == [.init(startedAt: 0, endedAt: 120_000)])
        let catalog = SkiDataCatalog(directory: condition == "unavailable" ? nil : fixture.referenceURL)
        let processor = ActivityProcessor(repository: repository, referenceData: { geometry in
            try await SkiDataCatalog.referenceData(for: geometry, catalog: catalog)
        })

        let result = try await processor.process(id: activity.id)
        #expect(result.passages == baseline)
        #expect(result.timeline?.entries == Geo.timeline(in: geometry, passages: baseline).entries)
        #expect(result.timeline?.entries.first?.durationMilliseconds == 120_000)
        #expect(abs((try #require(result.timeline?.entries.first?.distanceMeters)) - 360) < 0.001)
        #expect(result.timeline?.entries.first?.elevationGainMeters == 120)
        #expect(result.isCurrent(for: activity))
        let matching = try #require(result.timeline?.skiMatches)
        #expect(matching.entries == [[]])
        #expect(matching.resorts.isEmpty)
        #expect((matching.failure == nil) == (condition == "nonoverlap"))
        if condition == "invalid-geometry" || condition == "nonoverlap" {
            #expect(matching.datasetVersion == "lift-processing-fixture")
        }
        #expect(try await repository.storedAnalysis(id: activity.id) == result)
        #expect(try await repository.recordedTrack(id: activity.id).gpx == source)
    }

    @Test func staleAnalysisIsRebuiltUsingLiftReferenceEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createReferencePackages()
        let source = try track()
        let repository = try await ActivityRepository.open(url: fixture.storeURL)
        let activity = try #require(try await repository.importTracks([source]).imported.first)
        let baselineProcessor = ActivityProcessor(repository: repository, referenceData: { _ in
            .init(datasetVersion: nil, features: [])
        })
        let baseline = try await baselineProcessor.process(id: activity.id)
        #expect(baseline.timeline?.entries.map(\.kind) == [.run])
        let previous = ActivityAnalysis(activityID: activity.id, sourceRevision: activity.sourceRevision,
            processingVersion: ActivityAnalysis.currentProcessingVersion - 1, processedAt: baseline.processedAt, statistics: baseline.statistics,
            thumbnailPNG: baseline.thumbnailPNG, passages: baseline.passages, timeline: baseline.timeline)
        try await repository.saveAnalysis(previous)
        #expect(!previous.isCurrent(for: activity))
        let lookups = Mutex(0)
        let catalog = SkiDataCatalog(directory: fixture.referenceURL)
        let processor = ActivityProcessor(repository: repository, referenceData: { geometry in
            lookups.withLock { $0 += 1 }
            return try await SkiDataCatalog.referenceData(for: geometry, catalog: catalog)
        })

        let result = try await processor.process(id: activity.id)
        #expect(lookups.withLock { $0 } == 1)
        #expect(result.isCurrent(for: activity))
        #expect(result.statistics.runCount == 0)
        #expect(result.timeline?.entries.map(\.kind) == [.lift])
        #expect(result.timeline?.skiMatches?.entries.first?.map(\.feature.id) == ["flat-lift"])
        #expect(try await repository.storedAnalysis(id: activity.id) == result)
        #expect(try await repository.recordedTrack(id: activity.id).gpx == source)
    }

    @Test func cancelledReferenceLookupPropagatesWithoutSavingAnalysisOrChangingTheRecording() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createReferencePackages()
        let source = try track()
        let repository = try await ActivityRepository.open(url: fixture.storeURL)
        let activity = try #require(try await repository.importTracks([source]).imported.first)
        let catalog = SkiDataCatalog(directory: fixture.referenceURL)
        let lookups = Mutex(0)
        let processor = ActivityProcessor(repository: repository, referenceData: { geometry in
            lookups.withLock { $0 += 1 }
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SkiDataCatalog.referenceData(for: geometry, catalog: catalog)
        })

        await #expect(throws: CancellationError.self) { try await processor.process(id: activity.id) }
        #expect(lookups.withLock { $0 } == 1)
        #expect(try await repository.storedAnalysis(id: activity.id) == nil)
        #expect(try await repository.recordedTrack(id: activity.id).gpx == source)
        #expect(try await repository.summary(id: activity.id).sourceRevision == activity.sourceRevision)
    }

    private func track(climbRate: Double = 0) throws -> GPXTrack {
        let points = try (0...24).map { index in
            let seconds = Double(index * 5)
            return try TrackPoint(timestampMilliseconds: Int64(index * 5_000), latitude: 0,
                                  longitude: seconds * 3 / Fixture.metersPerDegree,
                                  elevationMeters: 1_000 + seconds * climbRate)
        }
        return GPXTrack(segments: [GPXSegment(points: points)])
    }

    private enum UnexpectedLookup: Error { case called }

    private struct Fixture {
        static let metersPerDegree = Double.pi * 6_371_000 / 180.0
        let directory: URL
        var referenceURL: URL { directory.appendingPathComponent("reference") }
        var storeURL: URL { directory.appendingPathComponent("activity.store") }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func createReferencePackages(northOffsetMeters: Double = 0, invalidGeometry: Bool = false) throws {
            try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
            for package in ["lifts", "ski_areas"] {
                try execute(in: package, sql: """
                    CREATE TABLE sunoh_metadata (key TEXT PRIMARY KEY, value TEXT);
                    INSERT INTO sunoh_metadata VALUES ('dataset_version', 'lift-processing-fixture'), ('package_schema_version', '1');
                    """)
            }
            try execute(in: "ski_areas", sql: """
                CREATE TABLE ski_areas_point (feature_id TEXT PRIMARY KEY, name TEXT, sources TEXT);
                INSERT INTO ski_areas_point VALUES ('valley', 'Flat Valley', '[{"type":"skimap.org","id":1}]');
                """)
            let longitude = 360 / Self.metersPerDegree
            let latitude = northOffsetMeters / Self.metersPerDegree
            let geometry = invalidGeometry ? Data([0]) : lineGeometry(longitude: longitude, latitude: latitude)
            let hex = geometry.map { String(format: "%02x", $0) }.joined()
            try execute(in: "lifts", sql: """
                CREATE TABLE lifts_linestring (id INTEGER PRIMARY KEY, geometry BLOB, feature_id TEXT, name TEXT, ref TEXT, sources TEXT, ski_area_ids TEXT);
                CREATE VIRTUAL TABLE rtree_lifts_linestring_geometry USING rtree(id, minx, maxx, miny, maxy);
                INSERT INTO lifts_linestring VALUES (1, X'\(hex)', 'flat-lift', 'Valley Connector', 'A', '[{"type":"openstreetmap","id":"way/1"}]', 'valley');
                INSERT INTO rtree_lifts_linestring_geometry VALUES (1, 0, \(longitude), \(latitude), \(latitude));
                """)
        }

        private func execute(in package: String, sql: String) throws {
            var database: OpaquePointer?
            guard sqlite3_open(referenceURL.appendingPathComponent("\(package).gpkg").path, &database) == SQLITE_OK,
                  let database else {
                if let database { sqlite3_close(database) }
                throw CocoaError(.fileWriteUnknown)
            }
            defer { sqlite3_close(database) }
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        }

        private func lineGeometry(longitude: Double, latitude: Double) -> Data {
            var data = Data([0x47, 0x50, 0, 1])
            func append(_ value: UInt64, bytes: Int) {
                for index in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
            }
            append(4326, bytes: 4)
            data.append(1)
            append(2, bytes: 4)
            append(2, bytes: 4)
            for x in [0, longitude] {
                append(x.bitPattern, bytes: 8)
                append(latitude.bitPattern, bytes: 8)
            }
            return data
        }
    }
}
