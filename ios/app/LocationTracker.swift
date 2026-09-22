import CoreLocation
import Observation

/// Platform location delivery and permissions. RecordingController decides what to persist.
@MainActor
@Observable
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    private(set) var currentLocation: CLLocationCoordinate2D?
    private(set) var locationMessage: String?
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    var hasLocationPermission: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    var isLocationReady: Bool { hasLocationPermission && hasUsableFix }

    private var hasUsableFix = false
    private let manager: CLLocationManager
    private let onPoints: ([TrackPoint]) -> Void
    private let maximumHorizontalError: CLLocationAccuracy = 30
    private var activated = false

    init(manager: CLLocationManager = CLLocationManager(), onPoints: @escaping ([TrackPoint]) -> Void) {
        self.manager = manager
        self.onPoints = onPoints
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        authorizationStatus = manager.authorizationStatus
    }

    func activate() {
        activated = true
        updateAuthorization(manager.authorizationStatus)
    }

    private func startLocationUpdatesIfAuthorized() {
        guard activated else { return }
        switch authorizationStatus {
        case .notDetermined:
            locationMessage = "Allow location access to record your route."
            manager.requestWhenInUseAuthorization()
        case .denied:
            locationMessage = "Location access is unavailable. You can enable it in Settings."
        case .restricted:
            locationMessage = "Location access is restricted on this device. Check Screen Time or device management restrictions."
        case .authorizedAlways, .authorizedWhenInUse:
            locationMessage = nil
            manager.startUpdatingLocation()
        @unknown default:
            locationMessage = "Location authorization is unavailable."
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateAuthorization(manager.authorizationStatus)
    }

    private func updateAuthorization(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        if !hasLocationPermission { hasUsableFix = false }
        startLocationUpdatesIfAuthorized()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        hasUsableFix = false
        if let error = error as? CLError, error.code == .locationUnknown {
            locationMessage = "Waiting for a location fix…"
        } else {
            locationMessage = error.localizedDescription
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let accurate = locations.filter {
            $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= maximumHorizontalError
                && CLLocationCoordinate2DIsValid($0.coordinate)
        }.sorted { $0.timestamp < $1.timestamp }
        hasUsableFix = !accurate.isEmpty
        if let latest = accurate.last {
            currentLocation = latest.coordinate
            locationMessage = nil
        }
        onPoints(accurate.compactMap {
            try? TrackPoint(
                timestampMilliseconds: Int64($0.timestamp.timeIntervalSince1970 * 1_000),
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude,
                elevationMeters: $0.verticalAccuracy >= 0 && $0.altitude.isFinite ? $0.altitude : nil
            )
        })
    }
}
