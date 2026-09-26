import Foundation
import SQLite3

/// Reads the bundled ski data without copying or changing it.
struct SkiFeatureStore: Sendable {
    let datasetVersion: String
    private let liftsURL: URL
    private let resorts: [String: SkiResort]

    init(directory: URL) throws {
        liftsURL = directory.appendingPathComponent("lifts.gpkg")
        let areasURL = directory.appendingPathComponent("ski_areas.gpkg")
        let versions = try [liftsURL, areasURL].map { url in
            let database = try SkiDatabase(url: url)
            return try database.version()
        }
        guard let version = versions.first, versions.allSatisfy({ $0 == version }) else {
            throw SkiFeatureStoreError.invalidData("The ski packages have different dataset versions.")
        }
        datasetVersion = version
        let database = try SkiDatabase(url: areasURL)
        let statement = try database.prepare("SELECT feature_id, name, sources FROM ski_areas_point")
        defer { sqlite3_finalize(statement) }
        var areas: [String: SkiResort] = [:]
        while try database.step(statement) {
            guard let id = Self.text(statement, 0), areas[id] == nil else {
                throw SkiFeatureStoreError.invalidData("A ski area has a missing or duplicate ID.")
            }
            areas[id] = SkiResort(id: id, name: Self.text(statement, 1), sources: try Self.sources(Self.text(statement, 2)))
        }
        resorts = areas
    }

    func features(for geometry: TrackGeometry) throws -> [SkiFeature] {
        let windows = Self.windows(for: geometry)
        guard !windows.isEmpty else { return [] }
        return try lifts(in: windows)
    }

    private func lifts(in windows: [Window]) throws -> [SkiFeature] {
        let database = try SkiDatabase(url: liftsURL)
        let statement = try database.prepare("""
            SELECT f.id, f.geometry, f.feature_id, f.sources, f.ski_area_ids
            FROM rtree_lifts_linestring_geometry AS r JOIN lifts_linestring AS f ON f.id = r.id
            WHERE r.maxx >= ?1 AND r.minx <= ?2 AND r.maxy >= ?3 AND r.miny <= ?4
            """)
        defer { sqlite3_finalize(statement) }
        var seenRows = Set<Int64>()
        var seenIDs = Set<String>()
        var result: [SkiFeature] = []
        for window in windows {
            try Task.checkCancellation()
            sqlite3_reset(statement)
            sqlite3_bind_double(statement, 1, window.minLongitude)
            sqlite3_bind_double(statement, 2, window.maxLongitude)
            sqlite3_bind_double(statement, 3, window.minLatitude)
            sqlite3_bind_double(statement, 4, window.maxLatitude)
            while try database.step(statement) {
                guard seenRows.insert(sqlite3_column_int64(statement, 0)).inserted else { continue }
                guard let id = Self.text(statement, 2), seenIDs.insert(id).inserted else {
                    throw SkiFeatureStoreError.invalidData("A ski feature has a missing or duplicate ID.")
                }
                guard let bytes = sqlite3_column_blob(statement, 1) else {
                    throw SkiFeatureStoreError.invalidData("A ski feature has no geometry.")
                }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
                let areaIDs = (Self.text(statement, 4) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                var seenAreas = Set<String>()
                let areas = try areaIDs.filter { seenAreas.insert($0).inserted }.map { id in
                    guard let resort = resorts[id] else {
                        throw SkiFeatureStoreError.invalidData("A ski feature refers to a missing ski area.")
                    }
                    return resort
                }
                let identity = SkiFeatureIdentity(id: id, kind: .lift, sources: try Self.sources(Self.text(statement, 3)), resorts: areas)
                result.append(SkiFeature(identity: identity, coordinates: try SkiLineGeometry.decode(data)))
            }
        }
        return result.sorted { $0.identity.id < $1.identity.id }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        let string = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    private static func sources(_ json: String?) throws -> [SkiFeatureSource] {
        guard let json else { return [] }
        do {
            let sources = try JSONDecoder().decode([SkiFeatureSource].self, from: Data(json.utf8))
            guard sources.allSatisfy({ !$0.type.isEmpty && !$0.id.isEmpty }) else {
                throw SkiFeatureStoreError.invalidData("A source identity is empty.")
            }
            return sources
        } catch {
            throw SkiFeatureStoreError.invalidData("A ski feature has invalid source identities.")
        }
    }

    private struct Cell: Hashable {
        let latitude: Int
        let longitude: Int
    }

    private struct Window {
        let minLatitude: Double
        let maxLatitude: Double
        let minLongitude: Double
        let maxLongitude: Double
    }

    /// Nearby cells keep separate resorts and source breaks from creating a large query rectangle.
    private static func windows(for geometry: TrackGeometry) -> [Window] {
        let cellDegrees = 0.005
        let latitudePadding = 150.0 / 111_000
        let cells = Set(geometry.sections.flatMap { section in
            section.points.map { point in
                Cell(latitude: Int(floor(point.latitude / cellDegrees)), longitude: Int(floor(point.longitude / cellDegrees)))
            }
        })
        return cells.sorted { ($0.latitude, $0.longitude) < ($1.latitude, $1.longitude) }.flatMap { cell in
            let minLatitude = max(-90, Double(cell.latitude) * cellDegrees - latitudePadding)
            let maxLatitude = min(90, Double(cell.latitude + 1) * cellDegrees + latitudePadding)
            let longitudePadding = min(180, latitudePadding / max(0.000001, cos(max(abs(minLatitude), abs(maxLatitude)) * .pi / 180)))
            let minLongitude = Double(cell.longitude) * cellDegrees - longitudePadding
            let maxLongitude = Double(cell.longitude + 1) * cellDegrees + longitudePadding
            func window(_ lower: Double, _ upper: Double) -> Window {
                Window(minLatitude: minLatitude, maxLatitude: maxLatitude, minLongitude: lower, maxLongitude: upper)
            }
            if maxLongitude - minLongitude >= 360 { return [window(-180, 180)] }
            if minLongitude < -180 { return [window(-180, maxLongitude), window(minLongitude + 360, 180)] }
            if maxLongitude > 180 { return [window(minLongitude, 180), window(-180, maxLongitude - 360)] }
            return [window(minLongitude, maxLongitude)]
        }
    }
}

enum SkiFeatureStoreError: LocalizedError {
    case unavailable(String)
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): "Ski reference data is unavailable. \(message)"
        case .invalidData(let message): "Ski reference data could not be read. \(message)"
        }
    }
}

private final class SkiDatabase {
    private let handle: OpaquePointer

    init(url: URL) throws {
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw SkiFeatureStoreError.unavailable("The package \(url.lastPathComponent) could not be opened.")
        }
        handle = connection
    }

    deinit { sqlite3_close(handle) }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw SkiFeatureStoreError.invalidData("A required ski data table or field is unavailable.")
        }
        return statement
    }

    func step(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: true
        case SQLITE_DONE: false
        default: throw SkiFeatureStoreError.invalidData("A ski data query failed.")
        }
    }

    func version() throws -> String {
        let statement = try prepare("SELECT key, value FROM sunoh_metadata WHERE key IN ('dataset_version', 'package_schema_version')")
        defer { sqlite3_finalize(statement) }
        var values: [String: String] = [:]
        while try step(statement) {
            if let key = sqlite3_column_text(statement, 0), let value = sqlite3_column_text(statement, 1) {
                values[String(cString: key)] = String(cString: value)
            }
        }
        guard values["package_schema_version"] == "1", let version = values["dataset_version"], !version.isEmpty else {
            throw SkiFeatureStoreError.invalidData("The ski package version is missing or unsupported.")
        }
        return version
    }
}

private enum SkiLineGeometry {
    static func decode(_ data: Data) throws -> [Coordinate] {
        var reader = Reader(bytes: Array(data))
        guard try reader.integer(2, littleEndian: false) == 0x4750, try reader.integer(1, littleEndian: false) == 0 else { throw invalid }
        let flags = try reader.integer(1, littleEndian: false)
        guard flags & 0xf0 == 0 else { throw invalid }
        let envelope = Int((flags >> 1) & 7)
        guard envelope <= 4, try reader.integer(4, littleEndian: flags & 1 == 1) == 4326 else { throw invalid }
        try reader.skip([0, 32, 48, 48, 64][envelope])
        let byteOrder = try reader.integer(1, littleEndian: false)
        guard byteOrder <= 1 else { throw invalid }
        let littleEndian = byteOrder == 1
        let rawType = try reader.integer(4, littleEndian: littleEndian)
        let baseType = rawType & 0x1fffffff
        let isoDimensions = baseType / 1_000
        guard baseType % 1_000 == 2, isoDimensions <= 3 else { throw invalid }
        let hasZ = rawType & 0x80000000 != 0 || isoDimensions == 1 || isoDimensions == 3
        let hasM = rawType & 0x40000000 != 0 || isoDimensions == 2 || isoDimensions == 3
        if rawType & 0x20000000 != 0 {
            guard try reader.integer(4, littleEndian: littleEndian) == 4326 else { throw invalid }
        }
        let count = Int(try reader.integer(4, littleEndian: littleEndian))
        let dimensions = 2 + (hasZ ? 1 : 0) + (hasM ? 1 : 0)
        guard count >= 2, count <= reader.remaining / (dimensions * 8) else { throw invalid }
        var coordinates: [Coordinate] = []
        coordinates.reserveCapacity(count)
        for _ in 0..<count {
            let longitude = Double(bitPattern: try reader.integer(8, littleEndian: littleEndian))
            let latitude = Double(bitPattern: try reader.integer(8, littleEndian: littleEndian))
            guard let coordinate = try? Coordinate(latitude: latitude, longitude: longitude) else { throw invalid }
            coordinates.append(coordinate)
            try reader.skip((dimensions - 2) * 8)
        }
        guard reader.remaining == 0 else { throw invalid }
        return coordinates
    }

    private static var invalid: SkiFeatureStoreError { .invalidData("A ski feature has an invalid line geometry.") }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var remaining: Int { bytes.count - offset }

        mutating func integer(_ count: Int, littleEndian: Bool) throws -> UInt64 {
            guard count <= remaining else { throw SkiLineGeometry.invalid }
            var value: UInt64 = 0
            for index in 0..<count {
                let shift = (littleEndian ? index : count - index - 1) * 8
                value |= UInt64(bytes[offset + index]) << shift
            }
            offset += count
            return value
        }

        mutating func skip(_ count: Int) throws {
            guard count <= remaining else { throw SkiLineGeometry.invalid }
            offset += count
        }
    }
}
