import Foundation
import SQLite3
import Testing
@testable import Sunoh

struct SkiFeatureStoreTests {
    @Test func readsNearbyLiftsWithSourcesAndMultipleResortsWithoutARunsPackage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addArea(id: "local", name: "Local resort", sources: #"[{"type":"skimap.org","id":6048}]"#)
        try fixture.addArea(id: "region", name: nil)
        try fixture.addLift(id: "linked-lift", coordinates: [(9, 46), (9.001, 46.001)], areas: " local,region,local ", name: nil, reference: "34", sources: #"[{"type":"openstreetmap","id":"way/32791237"}]"#)
        try fixture.addLift(id: "unassociated-lift", coordinates: [(9, 46), (9.001, 46.001)], areas: "", name: "Chair")
        let store = try SkiFeatureStore(directory: fixture.directory)
        let candidates = try store.features(for: track([(9, 46), (9.0005, 46.0005)]))
        #expect(store.datasetVersion == "fixture-version")
        #expect(candidates.count == 2)
        let lift = try #require(candidates.first { $0.identity.id == "linked-lift" })
        #expect(candidates.allSatisfy { $0.identity.kind == .lift })
        #expect(lift.identity.sources == [SkiFeatureSource(type: "openstreetmap", id: "way/32791237")])
        #expect(lift.identity.resorts.map(\.id) == ["local", "region"])
        #expect(lift.identity.resorts[0].sources == [SkiFeatureSource(type: "skimap.org", id: "6048")])
        #expect(lift.identity.resorts[1].name == nil)
        #expect(lift.coordinates == [try Coordinate(latitude: 46, longitude: 9), try Coordinate(latitude: 46.001, longitude: 9.001)])
        #expect(candidates.first { $0.identity.id == "unassociated-lift" }?.identity.resorts.isEmpty == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == ["lifts.gpkg", "ski_areas.gpkg"])
    }

    @Test func ignoresAnInvalidRunsPackageWhileReadingLifts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("This is not a GeoPackage.".utf8).write(to: fixture.directory.appendingPathComponent("runs.gpkg"))
        try fixture.addLift(id: "lift", coordinates: [(9, 46), (9.001, 46.001)], name: "Chair")
        let store = try SkiFeatureStore(directory: fixture.directory)
        let candidates = try store.features(for: track([(9, 46)]))
        #expect(store.datasetVersion == "fixture-version")
        #expect(candidates.map(\.identity.id) == ["lift"])
        #expect(candidates.first?.identity.kind == .lift)
    }

    @Test func liftNamesAndReferencesAreNotRequiredForGeometryAndResortLookup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addArea(id: "area", name: "Local resort")
        try fixture.addLift(id: "lift", coordinates: [(9, 46), (9.001, 46.001)], areas: "area",
                            sources: #"[{"type":"openstreetmap","id":"way/1"}]"#)
        try fixture.execute(in: "lifts", sql: "ALTER TABLE lifts_linestring DROP COLUMN name; ALTER TABLE lifts_linestring DROP COLUMN ref")
        let store = try SkiFeatureStore(directory: fixture.directory)
        let lift = try #require(store.features(for: track([(9, 46)])).first)
        #expect(lift.identity.id == "lift")
        #expect(lift.identity.sources == [SkiFeatureSource(type: "openstreetmap", id: "way/1")])
        #expect(lift.identity.resorts.map(\.displayName) == ["Local resort"])
        #expect(lift.coordinates.count == 2)
    }

    @Test func limitsQueriesToSampleNeighborhoodsAcrossSeparateResorts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addLift(id: "first", coordinates: [(9, 46), (9.001, 46.001)])
        try fixture.addLift(id: "second", coordinates: [(13, 48), (13.001, 48.001)])
        try fixture.addLift(id: "unvisited", coordinates: [(11, 47), (11.001, 47.001)], geometry: Data([0]))
        let store = try SkiFeatureStore(directory: fixture.directory)
        let candidates = try store.features(for: track([(9, 46), (13, 48)]))
        #expect(candidates.map(\.identity.id) == ["first", "second"])
        #expect(try store.features(for: track([])).isEmpty)
    }

    @Test func queriesAcrossTheAntimeridian() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addLift(id: "wrapped", coordinates: [(-179.9999, 46), (-179.9998, 46.001)])
        let store = try SkiFeatureStore(directory: fixture.directory)
        #expect(try store.features(for: track([(179.9999, 46)])).map(\.identity.id) == ["wrapped"])
    }

    @Test(arguments: [UInt32(2), 1_002, 2_002, 3_002, 0x80000002, 0xa0000002])
    func readsWKBAndEWKBDimensionsWithIndependentHeaderByteOrder(type: UInt32) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let coordinates = [(9.0, 46.0), (9.001, 46.001)]
        let data = lineGeometry(coordinates, type: type, littleEndian: false, envelope: true)
        try fixture.addLift(id: "lift", coordinates: coordinates, geometry: data)
        let store = try SkiFeatureStore(directory: fixture.directory)
        let feature = try #require(store.features(for: track([(9, 46)])).first)
        #expect(feature.coordinates.count == 2)
        #expect(feature.coordinates[1] == (try Coordinate(latitude: 46.001, longitude: 9.001)))
    }

    @Test(arguments: ["truncated", "magic", "type", "count", "coordinate", "srs", "trailing"])
    func rejectsInvalidGeometryWithoutReadingOutsideTheBlob(problem: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let coordinates = [(9.0, 46.0), (9.001, 46.001)]
        var data = lineGeometry(coordinates)
        switch problem {
        case "truncated": data.removeLast()
        case "magic": data[0] = 0
        case "type": data[9] = 3
        case "count": data.replaceSubrange(13..<17, with: [255, 255, 255, 255])
        case "coordinate": data = lineGeometry([(9, 91), (9.001, 46.001)])
        case "srs": data[7] = 0
        case "trailing": data.append(0)
        default: break
        }
        try fixture.addLift(id: "lift", coordinates: coordinates, geometry: data)
        let store = try SkiFeatureStore(directory: fixture.directory)
        #expect(throws: SkiFeatureStoreError.self) { try store.features(for: track([(9, 46)])) }
    }

    @Test func rejectsDanglingResortReferencesAndInvalidSources() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addLift(id: "lift", coordinates: [(9, 46), (9.001, 46.001)], areas: "missing")
        let store = try SkiFeatureStore(directory: fixture.directory)
        #expect(throws: SkiFeatureStoreError.self) { try store.features(for: track([(9, 46)])) }
        try fixture.execute(in: "lifts", sql: "UPDATE lifts_linestring SET ski_area_ids = '', sources = 'invalid'")
        #expect(throws: SkiFeatureStoreError.self) { try store.features(for: track([(9, 46)])) }
    }

    @Test func requiresLiftsAndSkiAreasToHaveTheSameSupportedVersion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.execute(in: "lifts", sql: "UPDATE sunoh_metadata SET value = 'another-version' WHERE key = 'dataset_version'")
        #expect(throws: SkiFeatureStoreError.self) { try SkiFeatureStore(directory: fixture.directory) }
        try fixture.execute(in: "lifts", sql: "UPDATE sunoh_metadata SET value = 'fixture-version' WHERE key = 'dataset_version'; UPDATE sunoh_metadata SET value = '2' WHERE key = 'package_schema_version'")
        #expect(throws: SkiFeatureStoreError.self) { try SkiFeatureStore(directory: fixture.directory) }
    }

    @Test func missingPackagesFailWithoutCreatingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: SkiFeatureStoreError.self) { try SkiFeatureStore(directory: directory) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private func track(_ coordinates: [(Double, Double)]) throws -> TrackGeometry {
        let points = try coordinates.enumerated().map { index, coordinate in
            try TrackPoint(timestampMilliseconds: Int64(index) * 1_000, latitude: coordinate.1, longitude: coordinate.0, elevationMeters: nil)
        }
        return TrackGeometry(activityID: "store-fixture", sourceRevision: 1, sections: [TrackSection(sourceSegmentID: "section", breakBefore: nil, points: points)])
    }

    private struct Fixture {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for package in ["lifts", "ski_areas"] {
                try execute(in: package, sql: """
                    CREATE TABLE sunoh_metadata (key TEXT PRIMARY KEY, value TEXT);
                    INSERT INTO sunoh_metadata VALUES ('dataset_version', 'fixture-version'), ('package_schema_version', '1'), ('source_updated_at', '2026-09-23T23:39:00Z');
                    """)
            }
            try execute(in: "ski_areas", sql: "CREATE TABLE ski_areas_point (feature_id TEXT PRIMARY KEY, name TEXT, sources TEXT)")
            try execute(in: "lifts", sql: """
                CREATE TABLE lifts_linestring (id INTEGER PRIMARY KEY, geometry BLOB, feature_id TEXT, name TEXT, ref TEXT, sources TEXT, ski_area_ids TEXT);
                CREATE VIRTUAL TABLE rtree_lifts_linestring_geometry USING rtree(id, minx, maxx, miny, maxy);
                """)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func addArea(id: String, name: String?, sources: String = "[]") throws {
            try execute(in: "ski_areas", sql: "INSERT INTO ski_areas_point VALUES (\(literal(id)), \(literal(name)), \(literal(sources)))")
        }

        func addLift(id: String, coordinates: [(Double, Double)], areas: String = "", name: String? = nil, reference: String? = nil, sources: String = "[]", geometry: Data? = nil) throws {
            let data = geometry ?? lineGeometry(coordinates)
            let hex = data.map { String(format: "%02x", $0) }.joined()
            let xs = coordinates.map(\.0), ys = coordinates.map(\.1)
            try execute(in: "lifts", sql: """
                INSERT INTO lifts_linestring (geometry, feature_id, name, ref, sources, ski_area_ids)
                VALUES (X'\(hex)', \(literal(id)), \(literal(name)), \(literal(reference)), \(literal(sources)), \(literal(areas)));
                INSERT INTO rtree_lifts_linestring_geometry VALUES (last_insert_rowid(), \(xs.min()!), \(xs.max()!), \(ys.min()!), \(ys.max()!));
                """)
        }

        func execute(in package: String, sql: String) throws {
            var database: OpaquePointer?
            guard sqlite3_open(directory.appendingPathComponent("\(package).gpkg").path, &database) == SQLITE_OK, let database else {
                if let database { sqlite3_close(database) }
                throw FixtureError.database
            }
            defer { sqlite3_close(database) }
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.database }
        }

        private func literal(_ string: String?) -> String {
            guard let string else { return "NULL" }
            return "'" + string.replacingOccurrences(of: "'", with: "''") + "'"
        }
    }

    private enum FixtureError: Error { case database }
}

private func lineGeometry(_ coordinates: [(Double, Double)], type: UInt32 = 0x80000002, littleEndian: Bool = true, envelope: Bool = false) -> Data {
    var data = Data([0x47, 0x50, 0, envelope ? 3 : 0])
    func append(_ value: UInt64, count: Int, littleEndian: Bool) {
        for index in 0..<count {
            data.append(UInt8(truncatingIfNeeded: value >> ((littleEndian ? index : count - index - 1) * 8)))
        }
    }
    append(4326, count: 4, littleEndian: envelope)
    if envelope { data.append(contentsOf: [UInt8](repeating: 0, count: 32)) }
    data.append(littleEndian ? 1 : 0)
    append(UInt64(type), count: 4, littleEndian: littleEndian)
    if type & 0x20000000 != 0 { append(4326, count: 4, littleEndian: littleEndian) }
    append(UInt64(coordinates.count), count: 4, littleEndian: littleEndian)
    let isoDimensions = (type & 0x1fffffff) / 1_000
    let hasZ = type & 0x80000000 != 0 || isoDimensions == 1 || isoDimensions == 3
    let hasM = type & 0x40000000 != 0 || isoDimensions == 2 || isoDimensions == 3
    for coordinate in coordinates {
        append(coordinate.0.bitPattern, count: 8, littleEndian: littleEndian)
        append(coordinate.1.bitPattern, count: 8, littleEndian: littleEndian)
        if hasZ { append(Double(1_500).bitPattern, count: 8, littleEndian: littleEndian) }
        if hasM { append(Double(10).bitPattern, count: 8, littleEndian: littleEndian) }
    }
    return data
}
