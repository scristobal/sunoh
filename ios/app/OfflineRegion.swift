import CoreLocation
import Foundation
import Turf

struct OfflineRegion: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let location: String
    let area: String
    let centerLatitude: Double
    let centerLongitude: Double
    let approximateAreaSquareMeters: Double
    let geometry: Geometry
    let tileCoverage: [Int: [OfflineTile]]
    var tileRegionID: String { "sunoh-resort-\(id)" }

    var center: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude) }

    var coordinates: [CLLocationCoordinate2D] {
        switch geometry {
        case .polygon(let polygon): polygon.coordinates.flatMap { $0 }
        case .multiPolygon(let polygons): polygons.coordinates.flatMap { $0.flatMap { $0 } }
        default: []
        }
    }

    static func loadCatalog() throws -> [OfflineRegion] {
        guard let url = Bundle.main.url(forResource: "offline-regions", withExtension: "geojson", subdirectory: "SkiData") else {
            throw CatalogError.missing
        }
        let collection = try JSONDecoder().decode(FeatureCollection.self, from: Data(contentsOf: url))
        var seen = Set<String>()
        return try collection.features.map { feature in
            guard case .string(let id) = feature.properties?["id"],
                  case .string(let name) = feature.properties?["name"],
                  case .string(let area) = feature.properties?["area"],
                  case .string(let location) = feature.properties?["location"],
                  case .array(let center) = feature.properties?["center"], center.count == 2,
                  case .number(let longitude) = center[0], case .number(let latitude) = center[1],
                  CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)),
                  case .number(let approximateArea) = feature.properties?["approximateAreaSquareMeters"],
                  approximateArea.isFinite, approximateArea >= 0,
                  let geometry = feature.geometry,
                  case .object(let coverage) = feature.properties?["tileCoverage"],
                  seen.insert(id).inserted else { throw CatalogError.invalid }
            var tileCoverage: [Int: [OfflineTile]] = [:]
            for zoom in OfflineTileGrid.indexZooms {
                guard case .array(let identifiers) = coverage[String(zoom)] else { throw CatalogError.invalid }
                let tiles = try identifiers.map { value in
                    guard case .string(let identifier) = value, let tile = OfflineTile(id: identifier), tile.zoom == zoom else { throw CatalogError.invalid }
                    return tile
                }
                guard !tiles.isEmpty, Set(tiles).count == tiles.count else { throw CatalogError.invalid }
                tileCoverage[zoom] = tiles
            }
            let region = OfflineRegion(id: id, name: name, location: location, area: area,
                centerLatitude: latitude, centerLongitude: longitude, approximateAreaSquareMeters: approximateArea,
                geometry: geometry, tileCoverage: tileCoverage)
            guard region.coordinates.count >= 4,
                  region.coordinates.allSatisfy({ CLLocationCoordinate2DIsValid($0) }) else { throw CatalogError.invalid }
            return region
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private enum CatalogError: LocalizedError {
        case missing, invalid
        var errorDescription: String? { "The offline map catalog could not be opened. Reinstall the latest Sunō build to restore it." }
    }
}

enum OfflineMapPhase: String, Codable {
    case queued, downloading, downloaded, failed
}

struct OfflineMapRecord: Codable {
    let region: OfflineRegion
    let styleURI: String
    var phase: OfflineMapPhase = .queued
    var requestedAt = Date()
    var mapVersion: String?
    var completedResources: UInt64 = 0
    var requiredResources: UInt64 = 0
    var error: String?
    var retryAfter: Date?
    var hasSavedMap = false
    var isPending: Bool { phase == .queued || phase == .downloading }
}
