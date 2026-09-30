import Foundation
import MapboxMaps

@MainActor enum MapService {
    static let defaultStyleURI = StyleURI(rawValue: "mapbox://styles/el-tobal/cmuixgnck000h01s979mi0gyt")!

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
