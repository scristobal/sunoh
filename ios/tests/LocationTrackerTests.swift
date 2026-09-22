import CoreLocation
import Testing
@testable import Sunoh

@MainActor struct LocationTrackerTests {
    @Test func mapAccessChecksRequestPermissionWheneverItIsUndetermined() {
        let manager = AuthorizationLocationManager(.notDetermined)
        let tracker = LocationTracker(manager: manager) { _ in }
        tracker.activate()
        tracker.activate()
        #expect(manager.permissionRequests == 2)
        #expect(manager.locationStarts == 0)
        #expect(!tracker.isLocationReady)
    }

    @Test(arguments: [CLAuthorizationStatus.denied, .restricted])
    func deniedOrRestrictedAccessDoesNotIssueAnIneffectiveSystemRequest(_ status: CLAuthorizationStatus) {
        let manager = AuthorizationLocationManager(status)
        let tracker = LocationTracker(manager: manager) { _ in }
        tracker.activate()
        #expect(tracker.authorizationStatus == status)
        #expect(manager.permissionRequests == 0)
        #expect(manager.locationStarts == 0)
        #expect(tracker.locationMessage != nil)
    }

    @Test func accessChecksReadPermissionChangesFromSettings() {
        let manager = AuthorizationLocationManager(.authorizedWhenInUse)
        let tracker = LocationTracker(manager: manager) { _ in }
        tracker.activate()
        tracker.locationManager(manager, didUpdateLocations: [fix(accuracy: 10)])
        #expect(tracker.isLocationReady)

        manager.reportedStatus = .denied
        tracker.activate()
        #expect(!tracker.hasLocationPermission)
        #expect(!tracker.isLocationReady)

        manager.reportedStatus = .authorizedWhenInUse
        tracker.activate()
        #expect(tracker.hasLocationPermission)
        #expect(!tracker.isLocationReady)
        #expect(manager.locationStarts == 2)
        tracker.locationManager(manager, didUpdateLocations: [fix(accuracy: 10)])
        #expect(tracker.isLocationReady)
    }

    @Test func permissionAloneDoesNotMakeLocationReady() {
        var received: [TrackPoint] = []
        let tracker = LocationTracker { received.append(contentsOf: $0) }
        let manager = AuthorizationLocationManager(.authorizedWhenInUse)
        tracker.locationManagerDidChangeAuthorization(manager)
        #expect(!tracker.isLocationReady)
        #expect(RecordingStatus.ready.withLocationReadiness(tracker.isLocationReady) == .locationNotReady)

        tracker.locationManager(manager, didUpdateLocations: [fix(accuracy: 100)])
        #expect(!tracker.isLocationReady)
        #expect(received.isEmpty)

        tracker.locationManager(manager, didUpdateLocations: [fix(accuracy: 10)])
        #expect(tracker.isLocationReady)
        #expect(received.count == 1)
        #expect(RecordingStatus.ready.withLocationReadiness(tracker.isLocationReady) == .ready)

        tracker.locationManager(manager, didUpdateLocations: [fix(accuracy: -1)])
        #expect(!tracker.isLocationReady)
        #expect(received.count == 1)
    }

    @Test func locationFailureClearsReadinessAndANewFixRestoresIt() {
        let tracker = LocationTracker { _ in }
        let manager = AuthorizationLocationManager(.authorizedAlways)
        tracker.locationManagerDidChangeAuthorization(manager)
        tracker.locationManager(manager, didUpdateLocations: [fix(accuracy: 10)])
        #expect(tracker.isLocationReady)

        tracker.locationManager(manager, didFailWithError: CLError(.locationUnknown))
        #expect(!tracker.isLocationReady)
        tracker.locationManager(manager, didUpdateLocations: [fix(accuracy: 10)])
        #expect(tracker.isLocationReady)
        #expect(tracker.locationMessage == nil)
    }

    @Test(arguments: [CLAuthorizationStatus.denied, .restricted, .notDetermined])
    func restoringPermissionRequiresANewFix(_ deniedStatus: CLAuthorizationStatus) {
        let tracker = LocationTracker { _ in }
        let authorized = AuthorizationLocationManager(.authorizedWhenInUse)
        tracker.locationManagerDidChangeAuthorization(authorized)
        tracker.locationManager(authorized, didUpdateLocations: [fix(accuracy: 10)])
        #expect(tracker.isLocationReady)

        tracker.locationManagerDidChangeAuthorization(AuthorizationLocationManager(deniedStatus))
        #expect(!tracker.isLocationReady)
        tracker.locationManagerDidChangeAuthorization(authorized)
        #expect(!tracker.isLocationReady)
        tracker.locationManager(authorized, didUpdateLocations: [fix(accuracy: 10)])
        #expect(tracker.isLocationReady)
    }

    @Test(arguments: [RecordingStatus.recording, .paused, .working(.saving), .working(.starting), .unavailable])
    func locationReadinessPreservesExistingRecordingStates(_ status: RecordingStatus) {
        #expect(status.withLocationReadiness(false) == status)
        #expect(status.withLocationReadiness(true) == status)
    }
}

private func fix(accuracy: CLLocationAccuracy) -> CLLocation {
    CLLocation(coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 11),
               altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
               timestamp: Date())
}

/// Supplies authorization changes without changing Simulator permissions or starting GPS.
private final class AuthorizationLocationManager: CLLocationManager {
    var reportedStatus: CLAuthorizationStatus
    private(set) var permissionRequests = 0
    private(set) var locationStarts = 0

    init(_ status: CLAuthorizationStatus) {
        reportedStatus = status
        super.init()
    }

    override var authorizationStatus: CLAuthorizationStatus { reportedStatus }
    override func requestWhenInUseAuthorization() { permissionRequests += 1 }
    override func startUpdatingLocation() { locationStarts += 1 }
}
