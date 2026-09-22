import Foundation
import MapLibre
import Testing
@testable import Sunoh

struct MapRequestAuthorizationTests {
    private let origin = URL(string: "https://tiles.example.test/v1/style.json")!
    private let credentials = MapAccessCredentials(clientID: "test.access", clientSecret: "cfast_test-secret")!

    @Test(arguments: ["style.json", "tiles.json", "0/0/0.mvt", "assets/font.pbf", "assets/sprite.json", "assets/sprite.png"])
    func authorizesEveryResourceType(_ path: String) {
        let authorizer = MapRequestAuthorization(origin: origin, credentials: credentials)
        let request = URLRequest(url: origin.deletingLastPathComponent().appendingPathComponent(path))
        let result = authorizer.willSend((request as NSURLRequest).mutableCopy() as! NSMutableURLRequest)
        #expect(result.value(forHTTPHeaderField: "CF-Access-Client-Id") == credentials.clientID)
        #expect(result.value(forHTTPHeaderField: "CF-Access-Client-Secret") == credentials.clientSecret)
    }

    @Test(arguments: [
        "https://other.example.test/style.json",
        "https://tiles.example.test.attacker.test/style.json",
        "http://tiles.example.test/style.json",
        "https://tiles.example.test:444/style.json",
        "https://user@tiles.example.test/style.json",
        "file:///tmp/style.json",
    ])
    func stripsCredentialsOutsideTheExactHTTPSOrigin(_ url: String) {
        let authorizer = MapRequestAuthorization(origin: origin, credentials: credentials)
        var request = URLRequest(url: URL(string: url)!)
        request.setValue(credentials.clientID, forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue(credentials.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let result = authorizer.authorized(request)
        #expect(result.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
        #expect(result.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
        #expect(result.value(forHTTPHeaderField: "Range") == "bytes=0-1023")
    }

    @Test func redirectsUseTheSameCredentialBoundary() async throws {
        let authorizer = MapRequestAuthorization(origin: origin, credentials: credentials)
        let network = MLNNetworkConfiguration.sharedManager
        let session = authorizer.session(for: network)
        defer { session.invalidateAndCancel() }
        #expect(session.delegate === authorizer)
        #expect(authorizer.responds(to: NSSelectorFromString("sessionForNetworkConfiguration:")))
        #expect(authorizer.responds(to: NSSelectorFromString("willSendRequest:")))
        let task = session.dataTask(with: origin)
        let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var redirected = authorizer.authorized(URLRequest(url: origin))
        redirected.url = URL(string: "https://other.example.test/redirected")!
        let result: URLRequest? = await withCheckedContinuation { continuation in
            authorizer.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) {
                continuation.resume(returning: $0)
            }
        }
        #expect(result?.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
        #expect(result?.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
    }

    @Test func absentOrMalformedCredentialsAreNotSent() {
        #expect(MapAccessCredentials(clientID: "", clientSecret: "secret") == nil)
        #expect(MapAccessCredentials(clientID: "test.access", clientSecret: "$(UNRESOLVED)") == nil)
        #expect(MapAccessCredentials(clientID: "test.access", clientSecret: "secret\r\nInjected: true") == nil)
        let result = MapRequestAuthorization(origin: origin, credentials: nil).authorized(URLRequest(url: origin))
        #expect(result.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
        #expect(result.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
    }
}
