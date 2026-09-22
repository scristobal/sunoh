import CoreLocation
import MapLibre
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
        #expect(!map.showsUserLocation)
        store.updateUserLocation(hasPermission: true, coordinate: nil)
        #expect(abs(map.centerCoordinate.latitude - first.latitude) > 1)
        store.updateUserLocation(hasPermission: true, coordinate: first)
        expectCenter(map, first)
        #expect(map.userTrackingMode == .follow)

        store.updateUserLocation(hasPermission: false, coordinate: first)
        #expect(!map.showsUserLocation)
        store.updateUserLocation(hasPermission: true, coordinate: nil)
        expectCenter(map, first)
        store.updateUserLocation(hasPermission: true, coordinate: restored)
        expectCenter(map, restored)
        #expect(map.userTrackingMode == .follow)
        #expect(abs(map.zoomLevel - 14) < 0.001)
    }

    @Test func laterFixesRespectManualPanning() {
        let map = makeMap()
        let store = MapViewStore()
        store.mapView = map
        store.updateUserLocation(hasPermission: true,
                                 coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 11))
        let manuallyChosen = CLLocationCoordinate2D(latitude: 48, longitude: 12)
        map.setUserTrackingMode(.none, animated: false, completionHandler: nil)
        map.setCenter(manuallyChosen, animated: false)

        store.updateUserLocation(hasPermission: true,
                                 coordinate: CLLocationCoordinate2D(latitude: 47.1, longitude: 11.1))
        expectCenter(map, manuallyChosen)
        #expect(map.userTrackingMode == .none)
    }

    @Test func aFixBeforeMapCreationStillCentersTheAttachedMap() {
        let store = MapViewStore()
        let coordinate = CLLocationCoordinate2D(latitude: 47, longitude: 11)
        store.updateUserLocation(hasPermission: true, coordinate: coordinate)
        let map = makeMap()
        store.mapView = map
        store.updateUserLocation(hasPermission: true, coordinate: coordinate)
        expectCenter(map, coordinate)
        #expect(map.userTrackingMode == .follow)
    }

    private func makeMap() -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleJSON: #"{"version":8,"sources":{},"layers":[]}"#)
        map.locationManager = SilentMapLocationManager()
        map.zoomLevel = 14
        return map
    }

    private func expectCenter(_ map: MLNMapView, _ expected: CLLocationCoordinate2D) {
        #expect(abs(map.centerCoordinate.latitude - expected.latitude) < 0.00001)
        #expect(abs(map.centerCoordinate.longitude - expected.longitude) < 0.00001)
    }
}

/// Keeps real MapLibre camera behavior while avoiding GPS and permission prompts.
private final class SilentMapLocationManager: NSObject, MLNLocationManager {
    weak var delegate: (any MLNLocationManagerDelegate)?
    var authorizationStatus: CLAuthorizationStatus { .authorizedWhenInUse }
    var headingOrientation: CLDeviceOrientation = .portrait
    func requestAlwaysAuthorization() {}
    func requestWhenInUseAuthorization() {}
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}
    func startUpdatingHeading() {}
    func stopUpdatingHeading() {}
    func dismissHeadingCalibrationDisplay() {}
}
