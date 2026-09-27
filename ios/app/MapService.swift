import Foundation
import MapboxMaps

enum MapStyle: String, Identifiable {
    case blueSnow
    case sunoh
    case mapboxStandard
    case custom

    static let preferenceKey = "mapStyle"
    static let presets: [MapStyle] = [.blueSnow, .sunoh, .mapboxStandard]

    var id: String { rawValue }

    var name: String {
        switch self {
        case .blueSnow: "Blue Snow"
        case .sunoh: "Sunō"
        case .mapboxStandard: "Standard"
        case .custom: "Custom"
        }
    }

    @MainActor var styleURI: StyleURI {
        let id: String
        switch self {
        case .blueSnow: id = "cmuixgnck000h01s979mi0gyt"
        case .sunoh: id = "cmuirfc4w006y01s3c1cgboyz"
        case .mapboxStandard: id = "cmujk5k4i001a01s91xrxdmiz"
        case .custom: return MapService.styleURI
        }
        return StyleURI(rawValue: "mapbox://styles/el-tobal/\(id)")!
    }

    @MainActor static var defaultSelection: MapStyle {
        defaultSelection(for: MapService.styleURI)
    }

    @MainActor static func defaultSelection(for styleURI: StyleURI) -> MapStyle {
        presets.first { $0.styleURI == styleURI } ?? .custom
    }

    @MainActor static func options(including selection: MapStyle) -> [MapStyle] {
        presets + (defaultSelection == .custom || selection == .custom ? [.custom] : [])
    }
}

@MainActor enum MapService {
    static let defaultStyleURI = MapStyle.blueSnow.styleURI

    static let styleURI = resolvedStyleURI(
        Bundle.main.object(forInfoDictionaryKey: "SunohMapStyleURL") as? String
    )

    private static let accessToken = publicAccessToken(
        Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String
    )

    static var configurationIssue: String? {
        accessToken == nil ? "Map access is not configured." : nil
    }

    @discardableResult static func configure() -> Bool {
        guard let accessToken else { return false }
        MapboxOptions.accessToken = accessToken
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
