import Foundation
import MapboxMaps

@MainActor enum MapService {
    static let offlineStorageURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OfflineMaps", isDirectory: true)
    static let tileStorageURL = offlineStorageURL.appendingPathComponent("Tiles", isDirectory: true)
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
