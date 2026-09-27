import Combine
import CoreLocation
import MapboxMaps
import Testing
@testable import Sunoh

@MainActor struct MapLocationTests {
    @Test func permissionRestorationCentersOnTheFirstUsableFix() {
        let map = makeMap()
        let store = MapViewStore()
        store.mapView = map
        let first = CLLocationCoordinate2D(latitude: 47, longitude: 11)
        let restored = CLLocationCoordinate2D(latitude: 48, longitude: 12)

        store.updateUserLocation(hasPermission: false, coordinate: first)
        #expect(map.location.options.puckType == nil)
        store.updateUserLocation(hasPermission: true, coordinate: nil)
        #expect(abs(map.mapboxMap.cameraState.center.latitude - first.latitude) > 1)
        store.updateUserLocation(hasPermission: true, coordinate: first)
        expectCenter(map, first)
        #expect(isFollowingUser(map))

        store.updateUserLocation(hasPermission: false, coordinate: first)
        #expect(map.location.options.puckType == nil)
        store.updateUserLocation(hasPermission: true, coordinate: nil)
        expectCenter(map, first)
        store.updateUserLocation(hasPermission: true, coordinate: restored)
        expectCenter(map, restored)
        #expect(isFollowingUser(map))
        #expect(abs(map.mapboxMap.cameraState.zoom - 14) < 0.001)
    }

    @Test func laterFixesRespectManualPanning() {
        let map = makeMap()
        let store = MapViewStore()
        store.mapView = map
        store.updateUserLocation(hasPermission: true,
                                 coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 11))
        let manuallyChosen = CLLocationCoordinate2D(latitude: 48, longitude: 12)
        map.viewport.idle()
        map.mapboxMap.setCamera(to: CameraOptions(center: manuallyChosen))

        store.updateUserLocation(hasPermission: true,
                                 coordinate: CLLocationCoordinate2D(latitude: 47.1, longitude: 11.1))
        expectCenter(map, manuallyChosen)
        #expect(map.viewport.status == .idle)
    }

    @Test func aFixBeforeMapCreationStillCentersTheAttachedMap() {
        let store = MapViewStore()
        let coordinate = CLLocationCoordinate2D(latitude: 47, longitude: 11)
        store.updateUserLocation(hasPermission: true, coordinate: coordinate)
        let map = makeMap()
        store.mapView = map
        store.updateUserLocation(hasPermission: true, coordinate: coordinate)
        expectCenter(map, coordinate)
        #expect(isFollowingUser(map))
    }

    private func makeMap() -> ActivityMapView {
        let location = LocationDataModel(location: Empty<[Location], Never>().eraseToAnyPublisher())
        let options = MapInitOptions(cameraOptions: CameraOptions(center: CLLocationCoordinate2D(latitude: 0, longitude: 0), zoom: 14),
                                     styleURI: nil, styleJSON: #"{"version":8,"sources":{},"layers":[]}"#,
                                     locationDataModel: location)
        return ActivityMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), mapInitOptions: options)
    }

    private func isFollowingUser(_ map: ActivityMapView) -> Bool {
        switch map.viewport.status {
        case .state(let state), .transition(_, toState: let state):
            return state is FollowPuckViewportState
        case .idle:
            return false
        @unknown default:
            return false
        }
    }

    private func expectCenter(_ map: ActivityMapView, _ expected: CLLocationCoordinate2D) {
        #expect(abs(map.mapboxMap.cameraState.center.latitude - expected.latitude) < 0.00001)
        #expect(abs(map.mapboxMap.cameraState.center.longitude - expected.longitude) < 0.00001)
    }
}
