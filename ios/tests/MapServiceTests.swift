import Testing
@testable import Sunoh

@MainActor struct MapServiceTests {
    @Test func acceptsPublicRuntimeTokens() {
        #expect(MapService.publicAccessToken("pk.test_payload.test-signature") == "pk.test_payload.test-signature")
    }

    @Test(arguments: [nil, "", "sk.secret.signature", "$(SUNOH_MAPBOX_ACCESS_TOKEN)", "pk.incomplete",
                      "pk.payload.signature\n", "pk.payload.signature\r\nInjected: true"] as [String?])
    func rejectsMissingSecretAndMalformedTokens(_ token: String?) {
        #expect(MapService.publicAccessToken(token) == nil)
    }

    @Test func acceptsAnotherMapboxStyle() {
        let custom = MapService.resolvedStyleURI("mapbox://styles/el-tobal/another-style")
        #expect(custom.rawValue == "mapbox://styles/el-tobal/another-style")
        #expect(MapStyle.defaultSelection(for: custom) == .custom)
        #expect(MapStyle.custom.styleURI == MapService.styleURI)
    }

    @Test(arguments: [nil, "", "$(SUNOH_MAP_STYLE_URL)", "https://tiles.example.test/style.json",
                      "mapbox://styles/el-tobal", "mapbox://user@styles/el-tobal/style",
                      "mapbox://styles/el-tobal/style?access_token=secret"] as [String?])
    func fallsBackToBlueSnowForInvalidStyles(_ style: String?) {
        #expect(MapService.resolvedStyleURI(style) == MapService.defaultStyleURI)
        #expect(MapService.defaultStyleURI.rawValue == "mapbox://styles/el-tobal/cmuixgnck000h01s979mi0gyt")
    }
}
