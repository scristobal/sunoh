import Foundation
import MapLibre

struct MapAccessCredentials: Sendable {
    let clientID: String
    let clientSecret: String

    init?(clientID: String, clientSecret: String) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard [clientID, clientSecret].allSatisfy({ value in
            !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains)
        }) else { return nil }
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

// MapLibre calls these delegates from background threads. All stored state is immutable.
final class MapRequestAuthorization: NSObject, MLNNetworkConfigurationDelegate,
    URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL
    private let credentials: MapAccessCredentials?

    init(origin: URL, credentials: MapAccessCredentials?) {
        self.origin = origin
        self.credentials = credentials
    }

    func authorized(_ request: URLRequest) -> URLRequest {
        var result = request
        result.setValue(nil, forHTTPHeaderField: "CF-Access-Client-Id")
        result.setValue(nil, forHTTPHeaderField: "CF-Access-Client-Secret")
        guard let url = request.url,
              origin.scheme?.lowercased() == "https",
              url.scheme?.lowercased() == "https",
              let host = origin.host?.lowercased(),
              url.host?.lowercased() == host,
              (url.port ?? 443) == (origin.port ?? 443),
              url.user == nil, url.password == nil,
              let credentials else { return result }
        result.setValue(credentials.clientID, forHTTPHeaderField: "CF-Access-Client-Id")
        result.setValue(credentials.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        return result
    }

    func willSend(_ request: NSMutableURLRequest) -> NSMutableURLRequest {
        (authorized(request as URLRequest) as NSURLRequest).mutableCopy() as! NSMutableURLRequest
    }

    func session(for configuration: MLNNetworkConfiguration) -> URLSession {
        URLSession(configuration: configuration.sessionConfiguration, delegate: self, delegateQueue: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(authorized(request))
    }
}

@MainActor enum MapService {
    // This retains MapLibre's weak delegate for the app lifetime.
    private static let authorization = MapRequestAuthorization(
        origin: styleURL,
        credentials: MapAccessCredentials(
            clientID: Bundle.main.object(forInfoDictionaryKey: "SunohMapAccessClientID") as? String ?? "",
            clientSecret: Bundle.main.object(forInfoDictionaryKey: "SunohMapAccessClientSecret") as? String ?? ""
        )
    )

    static let styleURL: URL = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "SunohMapStyleURL") as? String ?? ""
        if let url = URL(string: configured), url.scheme == "https", url.host != nil,
           url.user == nil, url.password == nil {
            return url
        }
        return URL(string: "https://tiles.samuel-cristobal.workers.dev/v1-rc/style.json")!
    }()

    static func configure() {
        MLNNetworkConfiguration.sharedManager.delegate = authorization
    }
}
