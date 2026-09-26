import CoreLocation
import MapLibre
import Testing
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

    @Test func selectionChangesBeforeAndAfterStyleLoadingReplaceAndRefitTheGeometry() async throws {
        let view = mapView()
        let store = MapViewStore()
        store.mapView = view
        let first = try track(latitude: 47, longitude: 11)
        let second = try track(latitude: 48, longitude: 12)
        let coordinator = StaticMapViewRepresentable.Coordinator(map: store, geometry: first, passages: .init(), obscuredBottom: 120, safeTop: 59)
        coordinator.update(geometry: second, passages: .init(), obscuredBottom: 430, safeTop: 59)
        let style = try await waitForStyle(in: view)
        coordinator.mapView(view, didFinishLoading: style)
        coordinator.fitTrackIfNeeded(in: view)
        expectInsideVisibleMap(second, in: view, padding: ActivityMapViewport.padding(safeTop: 59, safeBottom: 0, obscuredBottom: 430))
        #expect(abs(view.centerCoordinate.latitude - 48) < 0.02)
        // Keep the Objective-C source wrapper alive to inspect the next shape assignment.
        let source = try #require(style.source(withIdentifier: "user-track") as? MLNShapeSource)
        coordinator.update(geometry: first, passages: .init(), obscuredBottom: 120, safeTop: 59)
        coordinator.fitTrackIfNeeded(in: view)
        expectInsideVisibleMap(first, in: view, padding: ActivityMapViewport.padding(safeTop: 59, safeBottom: 0, obscuredBottom: 120))
        #expect(abs(view.centerCoordinate.latitude - 47) < 0.02)
        let shape = try #require(source.shape as? MLNShapeCollectionFeature)
        let line = try #require(shape.shapes.first as? MLNPolylineFeature)
        #expect(abs(line.coordinate.latitude - 47) < 0.02)
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
        #expect(view.zoomLevel > 10)
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
            #expect(abs(view.zoomLevel - 16) < 0.001)
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
        let style = try await waitForStyle(in: view)
        coordinator.mapView(view, didFinishLoading: style)
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
        #expect(abs(view.zoomLevel - 16) < 0.001)
        expectInsideVisibleMap(latest, in: view, padding: padding)
        expectCentered(latest, in: view, padding: padding)
        coordinator.cancelPendingFit()
    }

    private func mapView() -> FlightObservingMapView {
        let view = FlightObservingMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), styleJSON: #"{"version":8,"sources":{},"layers":[]}"#)
        view.automaticallyAdjustsContentInset = false
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

    private func expectInsideVisibleMap(_ geometry: TrackGeometry, in view: MLNMapView, padding: UIEdgeInsets) {
        let visible = view.bounds.inset(by: padding).insetBy(dx: -1, dy: -1)
        for point in geometry.sections.flatMap(\.points) {
            let projected = view.convert(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude), toPointTo: view)
            #expect(visible.contains(projected))
        }
    }

    private func expectCentered(_ geometry: TrackGeometry, in view: MLNMapView, padding: UIEdgeInsets) {
        let projected = geometry.sections.flatMap(\.points).map {
            view.convert(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude), toPointTo: view)
        }
        let visible = view.bounds.inset(by: padding)
        let center = CGPoint(x: projected.reduce(0) { $0 + $1.x } / CGFloat(projected.count),
                             y: projected.reduce(0) { $0 + $1.y } / CGFloat(projected.count))
        #expect(abs(center.x - visible.midX) < 1)
        #expect(abs(center.y - visible.midY) < 1)
    }

    private func waitForStyle(in view: MLNMapView) async throws -> MLNStyle {
        for _ in 0..<100 {
            if let style = view.style { return style }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(view.style)
    }
}

@MainActor private final class FlightObservingMapView: MLNMapView {
    private(set) var flightCount = 0
    private(set) var completedFlights: Set<Int> = []

    override func fly(to camera: MLNMapCamera, edgePadding insets: UIEdgeInsets, withDuration duration: TimeInterval,
                      completionHandler completion: (() -> Void)?) {
        flightCount += 1
        let flight = flightCount
        super.fly(to: camera, edgePadding: insets, withDuration: duration) { [weak self] in
            self?.completedFlights.insert(flight)
            completion?()
        }
    }
}
