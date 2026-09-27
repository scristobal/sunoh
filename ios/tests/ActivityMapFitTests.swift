import CoreLocation
import MapboxMaps
import Testing
import UIKit
@testable import Sunoh

@MainActor @Suite(.serialized) struct ActivityMapFitTests {
    @Test func fitsTheSelectedTrackAboveBothSheetHeightsAndTopSafeArea() throws {
        let view = mapView()
        let store = MapViewStore()
        store.mapView = view
        let geometry = try track(latitude: 47, longitude: 11)
        for sheetHeight in [CGFloat(120), 430] {
            let padding = ActivityMapViewport.padding(safeTop: 59, safeBottom: 34, obscuredBottom: sheetHeight)
            #expect(padding.top == 83)
            #expect(padding.bottom == sheetHeight + 24)
            #expect(store.fitTrack(geometry, padding: padding))
            expectInsideVisibleMap(geometry, in: view, padding: padding)
        }
    }

    @Test func pitchedMapsKeepTheTrackAboveBothSheetHeights() throws {
        let view = mapView()
        view.mapboxMap.setCamera(to: CameraOptions(bearing: 25, pitch: 45))
        let store = MapViewStore()
        store.mapView = view
        let geometry = try track(latitude: 47, longitude: 11)
        for sheetHeight in [CGFloat(120), 430] {
            let padding = ActivityMapViewport.padding(safeTop: 59, safeBottom: 34, obscuredBottom: sheetHeight)
            #expect(store.fitTrack(geometry, padding: padding))
            #expect(abs(view.mapboxMap.cameraState.pitch - 45) < 0.001)
            #expect(abs(view.mapboxMap.cameraState.bearing - 25) < 0.001)
            expectInsideVisibleMap(geometry, in: view, padding: padding)
        }
    }

    @Test func selectionChangesBeforeAndAfterStyleLoadingReplaceAndRefitTheGeometry() async throws {
        let view = mapView()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = view.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        window.layoutIfNeeded()
        view.layoutIfNeeded()
        let store = MapViewStore()
        store.mapView = view
        let first = try track(latitude: 47, longitude: 11)
        let second = try track(latitude: 48, longitude: 12)
        let coordinator = StaticMapViewRepresentable.Coordinator(map: store, geometry: first, passages: .init(), obscuredBottom: 120, safeTop: 59)
        coordinator.update(geometry: second, passages: .init(), obscuredBottom: 430, safeTop: 59)
        try await waitForStyle(in: view)
        coordinator.styleDidLoad(in: view)
        coordinator.fitTrackIfNeeded(in: view)
        expectInsideVisibleMap(second, in: view, padding: ActivityMapViewport.padding(safeTop: 59, safeBottom: 0, obscuredBottom: 430))
        #expect(abs(view.mapboxMap.cameraState.center.latitude - 48) < 0.02)
        coordinator.update(geometry: first, passages: .init(), obscuredBottom: 120, safeTop: 59)
        coordinator.fitTrackIfNeeded(in: view)
        expectInsideVisibleMap(first, in: view, padding: ActivityMapViewport.padding(safeTop: 59, safeBottom: 0, obscuredBottom: 120))
        #expect(abs(view.mapboxMap.cameraState.center.latitude - 47) < 0.02)
        let coordinates = try await waitForTrackCoordinates(in: view, nearLatitude: 47)
        #expect(!coordinates.isEmpty)
        #expect(coordinates.allSatisfy { abs($0.latitude - 47) < 0.02 })
    }

    @Test func styleReloadRestoresTheTrackWithoutResettingTheChosenCamera() async throws {
        let view = mapView()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = view.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        window.layoutIfNeeded()
        view.layoutIfNeeded()

        let store = MapViewStore()
        store.mapView = view
        let geometry = try track(latitude: 47, longitude: 11)
        let coordinator = StaticMapViewRepresentable.Coordinator(map: store, geometry: geometry, passages: nil,
                                                                obscuredBottom: 120, safeTop: 59)
        try await waitForStyle(in: view)
        coordinator.observeStyle(in: view)
        coordinator.fitTrackIfNeeded(in: view)
        let fitted = view.mapboxMap.cameraState
        view.mapboxMap.setCamera(to: CameraOptions(
            center: CLLocationCoordinate2D(latitude: fitted.center.latitude + 0.001, longitude: fitted.center.longitude + 0.001),
            zoom: fitted.zoom - 0.5, bearing: 30, pitch: 0
        ))
        let chosen = view.mapboxMap.cameraState

        coordinator.prepareForStyleChange()
        var replacementStyleLoaded = false
        let observation = view.mapboxMap.onStyleLoaded.observeNext { _ in replacementStyleLoaded = true }
        defer { observation.cancel() }
        view.mapboxMap.loadStyle(#"{"version":8,"pitch":70,"sources":{},"layers":[{"id":"test-background","type":"background","paint":{"background-color":"white"}}]}"#)
        for _ in 0..<100 {
            if replacementStyleLoaded { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(replacementStyleLoaded)
        coordinator.fitTrackIfNeeded(in: view)

        let reloaded = view.mapboxMap.cameraState
        #expect(abs(reloaded.center.latitude - chosen.center.latitude) < 0.00001)
        #expect(abs(reloaded.center.longitude - chosen.center.longitude) < 0.00001)
        #expect(abs(reloaded.zoom - chosen.zoom) < 0.001)
        #expect(abs(reloaded.bearing - chosen.bearing) < 0.001)
        #expect(abs(reloaded.pitch - chosen.pitch) < 0.001)
        #expect(reloaded.padding == chosen.padding)
        #expect(view.mapboxMap.sourceExists(withId: "user-track"))
        for layer in ["test-background", "user-track-casing", "user-track-run", "user-track-lift", "user-track-pending", "user-track-live"] {
            #expect(view.mapboxMap.layerExists(withId: layer))
        }
        let coordinates = try await waitForTrackCoordinates(in: view, nearLatitude: 47)
        #expect(!coordinates.isEmpty)
        #expect(coordinates.allSatisfy { abs($0.latitude - 47) < 0.02 })
    }

    @Test func fitsDateLineAndStationarySectionsInTheUnobscuredViewport() throws {
        let view = mapView()
        let store = MapViewStore()
        store.mapView = view
        let padding = ActivityMapViewport.padding(safeTop: 59, safeBottom: 34, obscuredBottom: 430)
        let dateLine = try fixtureGeometry([GPXSegment(points: [
            TrackPoint(timestampMilliseconds: 0, latitude: 47, longitude: 179.998, elevationMeters: nil),
            TrackPoint(timestampMilliseconds: 10_000, latitude: 47.002, longitude: -179.998, elevationMeters: nil)
        ])])
        #expect(store.fitTrack(dateLine, padding: padding))
        expectInsideVisibleMap(dateLine, in: view, padding: padding)
        #expect(view.mapboxMap.cameraState.zoom > 10)
        let stationary = try fixtureGeometry([GPXSegment(points: [
            TrackPoint(timestampMilliseconds: 0, latitude: 47, longitude: 11, elevationMeters: nil),
            TrackPoint(timestampMilliseconds: 10_000, latitude: 47, longitude: 11, elevationMeters: nil)
        ])])
        #expect(store.fitTrack(stationary, padding: padding))
        expectInsideVisibleMap(stationary, in: view, padding: padding)
    }

    @Test func shortTracksKeepContextAtTheMaximumZoomAboveEitherSheetHeight() throws {
        let view = mapView()
        view.maximumZoomLevel = 16
        let store = MapViewStore()
        store.mapView = view
        let geometry = try track(latitude: 47, longitude: 11, extent: 0.00002)
        for height in [CGFloat(120), 430] {
            let padding = ActivityMapViewport.padding(safeTop: 59, safeBottom: 34, obscuredBottom: height, contextPadding: 40)
            #expect(padding.top == 99)
            #expect(padding.left == 40)
            #expect(padding.bottom == height + 40)
            #expect(store.fitTrack(geometry, padding: padding))
            #expect(abs(view.mapboxMap.cameraState.zoom - 16) < 0.001)
            expectInsideVisibleMap(geometry, in: view, padding: padding)
            expectCentered(geometry, in: view, padding: padding)
        }
    }

    @Test func flightsCoalesceLayoutChangesAndFinishAtTheLatestSelection() async throws {
        let view = mapView()
        view.maximumZoomLevel = 16
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = view.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        window.layoutIfNeeded()
        view.layoutIfNeeded()

        let store = MapViewStore()
        store.mapView = view
        let first = try track(latitude: 47, longitude: 11)
        let second = try track(latitude: 47.02, longitude: 11.02)
        let latest = try track(latitude: 47.03, longitude: 11.03, extent: 0.00002)
        let coordinator = StaticMapViewRepresentable.Coordinator(map: store, geometry: first, passages: nil,
                                                                obscuredBottom: 120, safeTop: 59,
                                                                contextPadding: 40, fliesToChanges: true)
        try await waitForStyle(in: view)
        coordinator.styleDidLoad(in: view)
        coordinator.fitTrackIfNeeded(in: view)
        #expect(view.flightCount == 0)
        expectInsideVisibleMap(first, in: view, padding: ActivityMapViewport.padding(safeTop: max(59, view.safeAreaInsets.top),
                               safeBottom: view.safeAreaInsets.bottom, obscuredBottom: 120, contextPadding: 40))

        for height in [CGFloat(180), 250, 320, 430] {
            coordinator.update(geometry: second, passages: nil, obscuredBottom: height, safeTop: 59,
                               contextPadding: 40, fliesToChanges: true)
            coordinator.fitTrackIfNeeded(in: view)
        }
        #expect(view.flightCount == 0)
        // Repeated layout callbacks must neither postpone nor restart the pending flight.
        for _ in 0..<150 {
            coordinator.fitTrackIfNeeded(in: view)
            if view.flightCount == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(view.flightCount == 1)
        #expect(!view.completedFlights.contains(1))

        coordinator.update(geometry: latest, passages: nil, obscuredBottom: 430, safeTop: 59,
                           contextPadding: 40, fliesToChanges: true)
        coordinator.fitTrackIfNeeded(in: view)
        for _ in 0..<150 {
            coordinator.fitTrackIfNeeded(in: view)
            if view.completedFlights.contains(2) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(view.flightCount == 2)
        #expect(view.completedFlights.contains(2))
        let padding = ActivityMapViewport.padding(safeTop: max(59, view.safeAreaInsets.top), safeBottom: view.safeAreaInsets.bottom,
                                                 obscuredBottom: 430, contextPadding: 40)
        #expect(abs(view.mapboxMap.cameraState.zoom - 16) < 0.001)
        expectInsideVisibleMap(latest, in: view, padding: padding)
        expectCentered(latest, in: view, padding: padding)
        coordinator.cancelPendingFit()
    }

    private func mapView() -> FlightObservingMapView {
        let options = MapInitOptions(cameraOptions: CameraOptions(pitch: 0), styleURI: nil,
                                     styleJSON: #"{"version":8,"sources":{},"layers":[]}"#)
        let view = FlightObservingMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), mapInitOptions: options)
        view.maximumZoomLevel = 20
        view.layoutIfNeeded()
        return view
    }

    private func track(latitude: Double, longitude: Double, extent: Double = 0.004) throws -> TrackGeometry {
        try fixtureGeometry([GPXSegment(points: [
            TrackPoint(timestampMilliseconds: 0, latitude: latitude, longitude: longitude, elevationMeters: nil),
            TrackPoint(timestampMilliseconds: 10_000, latitude: latitude + extent, longitude: longitude + extent * 0.75, elevationMeters: nil)
        ])])
    }

    private func expectInsideVisibleMap(_ geometry: TrackGeometry, in view: ActivityMapView, padding: UIEdgeInsets) {
        let visible = view.bounds.inset(by: padding).insetBy(dx: -1, dy: -1)
        for point in geometry.sections.flatMap(\.points) {
            let projected = view.mapboxMap.point(for: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
            #expect(visible.contains(projected))
        }
    }

    private func expectCentered(_ geometry: TrackGeometry, in view: ActivityMapView, padding: UIEdgeInsets) {
        let projected = geometry.sections.flatMap(\.points).map {
            view.mapboxMap.point(for: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
        }
        let visible = view.bounds.inset(by: padding)
        let center = CGPoint(x: projected.reduce(0) { $0 + $1.x } / CGFloat(projected.count),
                             y: projected.reduce(0) { $0 + $1.y } / CGFloat(projected.count))
        #expect(abs(center.x - visible.midX) < 1)
        #expect(abs(center.y - visible.midY) < 1)
    }

    private func waitForTrackCoordinates(in view: ActivityMapView, nearLatitude latitude: Double) async throws -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        for _ in 0..<100 {
            let features: [Feature] = try await withCheckedThrowingContinuation { continuation in
                view.mapboxMap.querySourceFeatures(for: "user-track", options: SourceQueryOptions(sourceLayerIds: nil, filter: true)) { result in
                    continuation.resume(with: result.map { $0.map { $0.queriedFeature.feature } })
                }
            }
            coordinates = features.flatMap { feature -> [CLLocationCoordinate2D] in
                guard case .lineString(let line) = feature.geometry else { return [] }
                return line.coordinates
            }
            if !coordinates.isEmpty, coordinates.allSatisfy({ abs($0.latitude - latitude) < 0.02 }) { return coordinates }
            try await Task.sleep(for: .milliseconds(20))
        }
        return coordinates
    }

    private func waitForStyle(in view: ActivityMapView) async throws {
        for _ in 0..<100 {
            if view.mapboxMap.isStyleLoaded { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(view.mapboxMap.isStyleLoaded)
    }
}

@MainActor private final class FlightObservingMapView: ActivityMapView {
    private(set) var flightCount = 0
    private(set) var completedFlights: Set<Int> = []

    override func fly(to camera: CameraOptions, duration: TimeInterval,
                      completion: ((UIViewAnimatingPosition) -> Void)? = nil) {
        flightCount += 1
        let flight = flightCount
        super.fly(to: camera, duration: duration) { [weak self] position in
            if position == .end { self?.completedFlights.insert(flight) }
            completion?(position)
        }
    }
}
