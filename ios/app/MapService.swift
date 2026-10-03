import Foundation
import MapboxMaps
import OSLog

@MainActor enum MapService {
    static let offlineStorageURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OfflineMaps", isDirectory: true)
    static let tileStorageURL = offlineStorageURL.appendingPathComponent("Tiles", isDirectory: true)
    static var diskCacheURL: URL { MapboxMapsOptions.dataPath.appendingPathComponent("map_data.db") }
    private static var storageIssue: String?
    private static var configured = false
    static let defaultStyleURI = StyleURI(rawValue: "mapbox://styles/el-tobal/cmuixgnck000h01s979mi0gyt")!

    static let styleURI = resolvedStyleURI(
        Bundle.main.object(forInfoDictionaryKey: "SunohMapStyleURL") as? String
    )

    private static let accessToken = publicAccessToken(
        Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String
    )

    static var configurationIssue: String? {
        accessToken == nil ? "Map access is not configured." : storageIssue
    }

    @discardableResult static func configure() -> Bool {
        guard let accessToken else { return false }
        guard !configured else { return true }
        do {
            try FileManager.default.createDirectory(at: tileStorageURL, withIntermediateDirectories: true)
            var directory = offlineStorageURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        } catch {
            storageIssue = "Map storage could not be opened. Free some space and reopen Sunō."
            return false
        }
        storageIssue = nil
        MapboxOptions.accessToken = accessToken
        TileStore.setRootPath(tileStorageURL)
        MapboxMapsOptions.tileStore = .default
        MapboxMapsOptions.tileStoreUsageMode = .readOnly
        configured = true
        return true
    }

    /// Replaces the style's fog with a blue haze that thickens with distance, so farther ridges
    /// separate from nearer ones on a tilted map. The range starts at the map center and scales
    /// with zoom and map size. Mapbox fades fog in between 45° and 65° of pitch, so flat maps
    /// are unchanged.
    static func applyAtmosphere(to mapboxMap: MapboxMap) {
        var atmosphere = Atmosphere()
        atmosphere.range = .constant([0, 6])
        atmosphere.color = .constant(StyleColor(rawValue: "rgb(196, 216, 238)"))
        atmosphere.highColor = .constant(StyleColor(rawValue: "rgb(98, 176, 240)"))
        atmosphere.horizonBlend = .constant(0.08)
        do {
            try mapboxMap.setAtmosphere(atmosphere)
            try hideLabelsInHaze(in: mapboxMap)
        } catch {
            Logger(subsystem: "com.samuel.sunoh", category: "map").error("Unable to set the map atmosphere.")
        }
    }

    /// Drops the style's labels where the haze already hides much of the terrain, so names don't
    /// float over ridges the map no longer shows. distance-from-center measures map heights beyond
    /// the center and works only in symbol filters. A flat map stays well below the cutoff; only a
    /// steeply tilted one reaches it.
    private static func hideLabelsInHaze(in mapboxMap: MapboxMap) throws {
        let cutoff: [Any] = ["<", ["distance-from-center"], 1.5]
        for layer in mapboxMap.allLayerIdentifiers where layer.type == .symbol {
            let filter = mapboxMap.layerProperty(for: layer.id, property: "filter")
            // The live map view is reused, so the same style can come through here twice.
            guard !"\(filter.value)".contains("distance-from-center") else { continue }
            let combined: [Any] = filter.kind == .undefined ? cutoff : ["all", cutoff, filter.value]
            try mapboxMap.setLayerProperty(for: layer.id, property: "filter", value: combined)
        }
    }

    static func publicAccessToken(_ value: String?) -> String? {
        guard let value,
              value.range(of: #"^pk\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              !value.contains(where: \.isNewline) else { return nil }
        return value
    }

    static func resolvedStyleURI(_ value: String?) -> StyleURI {
        guard let value,
              let url = URL(string: value),
              url.scheme == "mapbox", url.host == "styles",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.pathComponents.filter({ $0 != "/" }).count == 2,
              let styleURI = StyleURI(rawValue: value) else { return defaultStyleURI }
        return styleURI
    }
}
