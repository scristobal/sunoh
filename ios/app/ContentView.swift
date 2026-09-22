import CoreLocation
import MapLibre
import SwiftUI

// MARK: - Inspect Map View (view a saved geometry, no user location)

struct InspectMapView: View {
    let geometry: TrackGeometry

    @State private var map = MapViewStore()

    var body: some View {
        StaticMapViewRepresentable(map: map, geometry: geometry)
    }
}

// MARK: - Record Map View (live recording with user location)

struct RecordMapView: View {
    let tracker: LocationTracker
    let recorder: RecordingController
    let map: MapViewStore

    var body: some View {
        MapViewRepresentable(map: map, hasLocationPermission: tracker.hasLocationPermission,
                             userCoordinate: tracker.isLocationReady ? tracker.currentLocation : nil)
            .onChange(of: recorder.geometryValue, initial: true) {
                map.updateTrack(recorder.geometryValue)
            }
            .onAppear {
                if tracker.hasLocationPermission { map.followUser(zoom: 14) }
            }
    }
}

// MARK: - Recording controls

struct RecordControls: View {
    let tracker: LocationTracker
    let recorder: RecordingController

    var body: some View {
        VStack(alignment: .leading) {
            RecordingSummary(tracker: tracker, recorder: recorder)
            RecordingMessages(tracker: tracker, recorder: recorder)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RecordingSummary: View {
    let tracker: LocationTracker
    let recorder: RecordingController

    private var status: RecordingStatus {
        recorder.recordingStatus.withLocationReadiness(tracker.isLocationReady)
    }

    var body: some View {
        RecordingActionRow(recorder: recorder, status: status)
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RecordingMessages: View {
    let tracker: LocationTracker
    let recorder: RecordingController

    var body: some View {
        VStack(alignment: .leading) {
            if let message = tracker.locationMessage {
                Text(message).font(.callout).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = recorder.storageError {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if recorder.requiresRestart {
                    Text("Restart Sunō to reopen storage. Pending points have not been saved.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button("Retry") { Task { await recorder.refresh() } }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
        }
    }
}

// MARK: - Static Map (inspect mode — no user location)

final class ActivityMapView: MLNMapView {
    var onLayout: ((MLNMapView) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        // MapLibre updates its own viewport size in super.layoutSubviews().
        onLayout?(self)
    }
}

struct StaticMapViewRepresentable: UIViewRepresentable {
    let map: MapViewStore
    let geometry: TrackGeometry

    func makeUIView(context: Context) -> ActivityMapView {
        let mapView = ActivityMapView(frame: .zero, styleURL: Self.resolvedStyleURL())
        mapView.maximumZoomLevel = 14
        mapView.showsUserLocation = false
        mapView.showsCompassView = false

        mapView.automaticallyAdjustsContentInset = false
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = true
        mapView.delegate = context.coordinator
        mapView.onLayout = { [weak coordinator = context.coordinator] mapView in
            coordinator?.fitTrackIfNeeded(in: mapView)
        }
        map.mapView = mapView
        return mapView
    }

    func updateUIView(_ mapView: ActivityMapView, context: Context) {}

    static func dismantleUIView(_ mapView: ActivityMapView, coordinator: Coordinator) {
        mapView.onLayout = nil
        mapView.delegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(map: map, geometry: geometry)
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        let map: MapViewStore
        let geometry: TrackGeometry
        private var hasLoadedStyle = false
        private var fittedSize: CGSize?

        init(map: MapViewStore, geometry: TrackGeometry) {
            self.map = map
            self.geometry = geometry
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            map.updateTrack(geometry)
            hasLoadedStyle = true
            fittedSize = nil
            // Style loading can finish before SwiftUI gives the map a frame.
            mapView.setNeedsLayout()
        }

        func fitTrackIfNeeded(in mapView: MLNMapView) {
            guard hasLoadedStyle, mapView.bounds.size != fittedSize else { return }
            if map.fitTrack(geometry) {
                fittedSize = mapView.bounds.size
            }
        }
    }

    static func resolvedStyleURL() -> URL {
        mapStyleURL()
    }
}

// MARK: - Live Map (record mode — with user location + following)

struct MapViewRepresentable: UIViewRepresentable {
    let map: MapViewStore
    let hasLocationPermission: Bool
    let userCoordinate: CLLocationCoordinate2D?

    func makeUIView(context: Context) -> MLNMapView {
        let mapView: MLNMapView
        if let existing = map.mapView {
            mapView = existing
        } else {
            mapView = MLNMapView(frame: .zero, styleURL: Self.resolvedStyleURL())
            mapView.zoomLevel = 14
            map.mapView = mapView
        }
        mapView.maximumZoomLevel = 14
        mapView.automaticallyAdjustsContentInset = false
        mapView.showsCompassView = false
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = true
        mapView.delegate = context.coordinator
        map.updateUserLocation(hasPermission: hasLocationPermission, coordinate: userCoordinate)
        if mapView.style != nil, hasLocationPermission {
            map.followUser()
        }
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        map.updateUserLocation(hasPermission: hasLocationPermission, coordinate: userCoordinate)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(map: map)
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        let map: MapViewStore

        init(map: MapViewStore) {
            self.map = map
        }

        func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
            map.trackingMode = mode
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            if mapView.showsUserLocation { map.followUser() }
            map.renderTrack()
        }
    }

    static func resolvedStyleURL() -> URL {
        mapStyleURL()
    }
}

// MARK: - Shared style URL resolution

@MainActor private func mapStyleURL() -> URL {
    MapService.configure()
    return MapService.styleURL
}

// MARK: - Map state

@MainActor @Observable
final class MapViewStore {
    var mapView: MLNMapView?
    var trackingMode: MLNUserTrackingMode = .none
    private var needsLocationCenter = true

    var trackingIcon: String {
        switch trackingMode {
        case .follow: "location.fill"
        case .followWithHeading: "location.north.line.fill"
        default: "location"
        }
    }
    var trackingLabel: String {
        switch trackingMode {
        case .follow: "Following location"
        case .followWithHeading: "Following heading"
        default: "Free map"
        }
    }

    private var trackGeometry: TrackGeometry?

    /// Center once on the first usable fix, and again after permission is restored.
    /// Subsequent fixes use MapLibre's selected tracking mode, including free panning.
    func updateUserLocation(hasPermission: Bool, coordinate: CLLocationCoordinate2D?) {
        if !hasPermission { needsLocationCenter = true }
        guard let mapView else { return }
        if mapView.showsUserLocation != hasPermission {
            mapView.showsUserLocation = hasPermission
        }
        guard hasPermission, needsLocationCenter, let coordinate,
              CLLocationCoordinate2DIsValid(coordinate) else { return }
        needsLocationCenter = false
        mapView.setCenter(coordinate, animated: false)
        followUser()
    }

    func clearTrack() {
        guard let style = mapView?.style else { return }
        if let layer = style.layer(withIdentifier: "user-track-line") {
            style.removeLayer(layer)
        }
        if let layer = style.layer(withIdentifier: "user-track-casing") {
            style.removeLayer(layer)
        }
        if let source = style.source(withIdentifier: "user-track") {
            style.removeSource(source)
        }
        if let layer = style.layer(withIdentifier: "user-track-dots") {
            style.removeLayer(layer)
        }
        if let source = style.source(withIdentifier: "user-track-singletons") {
            style.removeSource(source)
        }
    }

    func followUser(zoom: Double? = nil) {
        guard let mapView else { return }
        mapView.showsUserLocation = true
        if let zoom {
            mapView.setZoomLevel(zoom, animated: false)
        }
        mapView.setUserTrackingMode(.follow, animated: false, completionHandler: nil)
    }

    func cycleTrackingMode() {
        guard let mapView else { return }
        mapView.showsUserLocation = true
        let next: MLNUserTrackingMode = switch trackingMode {
        case .none: .follow
        case .follow: .followWithHeading
        default: .none
        }
        mapView.setUserTrackingMode(next, animated: true, completionHandler: nil)
    }

    func fitTrack(_ geometry: TrackGeometry) -> Bool {
        let padding = UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40)
        guard let mapView,
              mapView.bounds.width > padding.left + padding.right,
              mapView.bounds.height > padding.top + padding.bottom
        else { return false }
        let points = geometry.sections.flatMap(\.points)
        guard let first = points.first else { return true }
        let bounds = points.reduce(
            into: (minLat: first.latitude, maxLat: first.latitude,
                   minLon: first.longitude, maxLon: first.longitude)
        ) { bounds, point in
            bounds.minLat = min(bounds.minLat, point.latitude)
            bounds.maxLat = max(bounds.maxLat, point.latitude)
            bounds.minLon = min(bounds.minLon, point.longitude)
            bounds.maxLon = max(bounds.maxLon, point.longitude)
        }
        if bounds.minLat == bounds.maxLat && bounds.minLon == bounds.maxLon {
            mapView.centerCoordinate = CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude)
            mapView.zoomLevel = 14
            return true
        }
        let camera = mapView.cameraThatFitsCoordinateBounds(
            MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: bounds.minLat, longitude: bounds.minLon),
                ne: CLLocationCoordinate2D(latitude: bounds.maxLat, longitude: bounds.maxLon)
            ),
            edgePadding: padding
        )
        mapView.setCamera(camera, animated: false)
        return true
    }

    func updateTrack(_ geometry: TrackGeometry?) {
        trackGeometry = geometry
        renderTrack()
    }

    /// Both live and inspected maps preserve recording and GPS-gap segments.
    func renderTrack() {
        guard let style = mapView?.style else { return }
        let sections = trackGeometry?.sections ?? []
        let polylines = sections.compactMap { section -> MLNPolyline? in
            var coordinates = section.points.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            guard coordinates.count >= 2 else { return nil }
            return MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
        }
        let shape: MLNShape? = polylines.isEmpty ? nil : MLNMultiPolyline(polylines: polylines)
        if let source = style.source(withIdentifier: "user-track") as? MLNShapeSource {
            source.shape = shape
        } else {
            let source = MLNShapeSource(identifier: "user-track", shape: shape)
            style.addSource(source)

            let casing = MLNLineStyleLayer(identifier: "user-track-casing", source: source)
            casing.lineColor = NSExpression(forConstantValue: UIColor.white)
            casing.lineWidth = NSExpression(forConstantValue: 5)
            casing.lineCap = NSExpression(forConstantValue: "round")
            casing.lineJoin = NSExpression(forConstantValue: "round")

            let line = MLNLineStyleLayer(identifier: "user-track-line", source: source)
            line.lineColor = NSExpression(forConstantValue: UIColor.systemPurple)
            line.lineWidth = NSExpression(forConstantValue: 3)
            line.lineCap = NSExpression(forConstantValue: "round")
            line.lineJoin = NSExpression(forConstantValue: "round")
            line.lineDashPattern = NSExpression(forConstantValue: [2, 1.5])
            style.addLayer(casing)
            style.addLayer(line)
        }

        var singletons = sections.filter { $0.points.count == 1 }.compactMap { $0.points.first }.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        let dots: MLNShape? = singletons.isEmpty ? nil
            : MLNPointCollection(coordinates: &singletons, count: UInt(singletons.count))
        if let source = style.source(withIdentifier: "user-track-singletons") as? MLNShapeSource {
            source.shape = dots
        } else {
            let source = MLNShapeSource(identifier: "user-track-singletons", shape: dots)
            style.addSource(source)
            let layer = MLNCircleStyleLayer(identifier: "user-track-dots", source: source)
            layer.circleRadius = NSExpression(forConstantValue: 4)
            layer.circleColor = NSExpression(forConstantValue: UIColor.systemPurple)
            layer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
            layer.circleStrokeWidth = NSExpression(forConstantValue: 2)
            style.addLayer(layer)
        }
    }
}
