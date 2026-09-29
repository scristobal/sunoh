import CoreLocation
import MapboxMaps
import OSLog
import SwiftUI
import Turf

// MARK: - Inspect Map View (view a saved geometry, no user location)

struct InspectMapView: View {
    let geometry: TrackGeometry
    var passages: SkiActivityDetector.Result? = nil
    var maximumZoomLevel = 14.0
    var obscuredBottom: CGFloat = 0
    var safeTop: CGFloat = 0
    var contextPadding: CGFloat = 24
    var fliesToChanges = false

    @State private var map = MapViewStore()

    var body: some View {
        if let issue = MapService.configurationIssue {
            ContentUnavailableView("Map unavailable", systemImage: "map", description: Text(issue))
        } else {
            StaticMapViewRepresentable(map: map, geometry: geometry, passages: passages, maximumZoomLevel: maximumZoomLevel,
                                       obscuredBottom: obscuredBottom, safeTop: safeTop,
                                       contextPadding: contextPadding, fliesToChanges: fliesToChanges)
        }
    }
}

// MARK: - Record Map View (live recording with user location)

struct RecordMapView: View {
    let tracker: LocationTracker
    let recorder: RecordingController
    let map: MapViewStore

    var body: some View {
        if let issue = MapService.configurationIssue {
            ContentUnavailableView("Map unavailable", systemImage: "map", description: Text(issue))
        } else {
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
}

// MARK: - Static Map (inspect mode — no user location)

class ActivityMapView: MapView {
    var onLayout: ((ActivityMapView) -> Void)?

    var maximumZoomLevel: Double {
        get { mapboxMap.cameraBounds.maxZoom }
        set { try? mapboxMap.setCameraBounds(with: CameraBoundsOptions(maxZoom: newValue)) }
    }

    func fly(to camera: CameraOptions, duration: TimeInterval, completion: ((UIViewAnimatingPosition) -> Void)? = nil) {
        self.camera.fly(to: camera, duration: duration, completion: completion)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }
}

struct StaticMapViewRepresentable: UIViewRepresentable {
    @AppStorage(MapStyle.preferenceKey) private var selectedStyle = MapStyle.defaultSelection
    let map: MapViewStore
    let geometry: TrackGeometry
    let passages: SkiActivityDetector.Result?
    let maximumZoomLevel: Double
    var obscuredBottom: CGFloat = 0
    var safeTop: CGFloat = 0
    var contextPadding: CGFloat = 24
    var fliesToChanges = false

    func makeUIView(context: Context) -> ActivityMapView {
        let mapView = ActivityMapView(frame: .zero, mapInitOptions: mapInitOptions(style: selectedStyle))
        mapView.maximumZoomLevel = maximumZoomLevel
        mapView.location.options.puckType = nil
        mapView.ornaments.options.compass.visibility = .hidden
        mapView.ornaments.options.scaleBar.visibility = .hidden
        map.mapView = mapView
        context.coordinator.observeStyle(in: mapView)
        mapView.onLayout = { [weak coordinator = context.coordinator] mapView in
            coordinator?.fitTrackIfNeeded(in: mapView)
        }
        return mapView
    }

    func updateUIView(_ mapView: ActivityMapView, context: Context) {
        mapView.maximumZoomLevel = maximumZoomLevel
        if mapView.mapboxMap.styleURI != selectedStyle.styleURI {
            context.coordinator.prepareForStyleChange()
            mapView.mapboxMap.styleURI = selectedStyle.styleURI
        }
        context.coordinator.update(geometry: geometry, passages: passages, obscuredBottom: obscuredBottom, safeTop: safeTop,
                                   contextPadding: contextPadding, fliesToChanges: fliesToChanges)
        context.coordinator.fitTrackIfNeeded(in: mapView)
    }

    static func dismantleUIView(_ mapView: ActivityMapView, coordinator: Coordinator) {
        coordinator.cancelPendingFit()
        mapView.onLayout = nil
        coordinator.styleObservation = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(map: map, geometry: geometry, passages: passages, obscuredBottom: obscuredBottom, safeTop: safeTop,
                    contextPadding: contextPadding, fliesToChanges: fliesToChanges)
    }

    @MainActor final class Coordinator {
        let map: MapViewStore
        private var geometry: TrackGeometry
        private var passages: SkiActivityDetector.Result?
        private var obscuredBottom: CGFloat
        private var safeTop: CGFloat
        private var contextPadding: CGFloat
        private var fliesToChanges: Bool
        private var hasLoadedStyle = false
        private var hasFittedTrack = false
        private var geometryRevision = 0
        private var fittedRequest: FitRequest?
        private var pendingRequest: FitRequest?
        private var pendingFit: Task<Void, Never>?

        private struct FitRequest: Equatable {
            let geometryRevision: Int
            let size: CGSize
            let padding: UIEdgeInsets
            let maximumZoom: Double
        }

        init(map: MapViewStore, geometry: TrackGeometry, passages: SkiActivityDetector.Result?, obscuredBottom: CGFloat = 0,
             safeTop: CGFloat = 0, contextPadding: CGFloat = 24, fliesToChanges: Bool = false) {
            self.map = map
            self.geometry = geometry
            self.passages = passages
            self.obscuredBottom = obscuredBottom
            self.safeTop = safeTop
            self.contextPadding = contextPadding
            self.fliesToChanges = fliesToChanges
        }

        func update(geometry: TrackGeometry, passages: SkiActivityDetector.Result?, obscuredBottom: CGFloat, safeTop: CGFloat,
                    contextPadding: CGFloat = 24, fliesToChanges: Bool = false) {
            let trackChanged = geometry != self.geometry || passages != self.passages
            if geometry != self.geometry { geometryRevision += 1 }
            self.geometry = geometry
            self.passages = passages
            self.obscuredBottom = obscuredBottom
            self.safeTop = safeTop
            self.contextPadding = contextPadding
            self.fliesToChanges = fliesToChanges
            if !fliesToChanges { cancelPendingFit() }
            if trackChanged, hasLoadedStyle { map.updateSessionTrack(geometry, passages: passages) }
        }

        var styleObservation: AnyCancelable?

        func observeStyle(in mapView: ActivityMapView) {
            styleObservation = mapView.mapboxMap.onStyleLoaded.observe { [weak self, weak mapView] _ in
                guard let mapView else { return }
                self?.styleDidLoad(in: mapView)
            }
            if mapView.mapboxMap.isStyleLoaded { styleDidLoad(in: mapView) }
        }

        func prepareForStyleChange() {
            hasLoadedStyle = false
            cancelPendingFit()
        }

        func styleDidLoad(in mapView: ActivityMapView) {
            map.updateSessionTrack(geometry, passages: passages)
            hasLoadedStyle = true
            // Style loading can finish before SwiftUI gives the map a frame.
            mapView.setNeedsLayout()
        }

        func fitTrackIfNeeded(in mapView: ActivityMapView) {
            let padding = ActivityMapViewport.padding(safeTop: max(safeTop, mapView.safeAreaInsets.top),
                                                     safeBottom: mapView.safeAreaInsets.bottom, obscuredBottom: obscuredBottom,
                                                     contextPadding: contextPadding)
            guard hasLoadedStyle else { return }
            guard mapView.bounds.width > padding.left + padding.right,
                  mapView.bounds.height > padding.top + padding.bottom else {
                cancelPendingFit()
                return
            }
            let request = FitRequest(geometryRevision: geometryRevision, size: mapView.bounds.size,
                                     padding: padding, maximumZoom: mapView.maximumZoomLevel)
            guard request != pendingRequest else { return }
            guard request != fittedRequest else {
                cancelPendingFit()
                return
            }
            cancelPendingFit()
            if fliesToChanges, hasFittedTrack {
                pendingRequest = request
                // Wait for the sheet or layout to settle before starting one native flight.
                pendingFit = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(120)) }
                    catch { return }
                    guard let self, self.pendingRequest == request else { return }
                    self.pendingRequest = nil
                    self.pendingFit = nil
                    self.fit(request, fly: true)
                }
            } else {
                fit(request, fly: false)
            }
        }

        func cancelPendingFit() {
            pendingFit?.cancel()
            pendingFit = nil
            pendingRequest = nil
        }

        private func fit(_ request: FitRequest, fly: Bool) {
            let previousRequest = fittedRequest
            // Layout callbacks during a flight must not restart the same transition.
            fittedRequest = request
            if map.fitTrack(geometry, padding: request.padding, fly: fly) {
                hasFittedTrack = hasFittedTrack || geometry.sections.contains { !$0.points.isEmpty }
            } else {
                fittedRequest = previousRequest
            }
        }
    }
}

enum ActivityMapViewport {
    static func padding(safeTop: CGFloat, safeBottom: CGFloat, obscuredBottom: CGFloat, contextPadding: CGFloat = 24) -> UIEdgeInsets {
        let margin = max(0, contextPadding)
        return UIEdgeInsets(top: max(0, safeTop) + margin, left: margin,
                            bottom: max(0, safeBottom, obscuredBottom) + margin, right: margin)
    }
}

// MARK: - Live Map (record mode — with user location + following)

struct MapViewRepresentable: UIViewRepresentable {
    @AppStorage(MapStyle.preferenceKey) private var selectedStyle = MapStyle.defaultSelection
    let map: MapViewStore
    let hasLocationPermission: Bool
    let userCoordinate: CLLocationCoordinate2D?

    func makeUIView(context: Context) -> ActivityMapView {
        let mapView = map.mapView ?? ActivityMapView(frame: .zero, mapInitOptions: mapInitOptions(style: selectedStyle))
        mapView.maximumZoomLevel = 14
        mapView.ornaments.options.compass.visibility = .hidden
        mapView.ornaments.options.scaleBar.visibility = .hidden
        map.mapView = mapView
        context.coordinator.observeStyle(in: mapView)
        updateStyle(in: mapView)
        map.updateUserLocation(hasPermission: hasLocationPermission, coordinate: userCoordinate)
        return mapView
    }

    func updateUIView(_ mapView: ActivityMapView, context: Context) {
        updateStyle(in: mapView)
        map.updateUserLocation(hasPermission: hasLocationPermission, coordinate: userCoordinate)
    }

    private func updateStyle(in mapView: ActivityMapView) {
        if mapView.mapboxMap.styleURI != selectedStyle.styleURI {
            mapView.mapboxMap.styleURI = selectedStyle.styleURI
        }
    }

    static func dismantleUIView(_ mapView: ActivityMapView, coordinator: Coordinator) {
        coordinator.styleObservation = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(map: map)
    }

    @MainActor final class Coordinator {
        let map: MapViewStore
        var styleObservation: AnyCancelable?

        init(map: MapViewStore) {
            self.map = map
        }

        func observeStyle(in mapView: ActivityMapView) {
            styleObservation = mapView.mapboxMap.onStyleLoaded.observe { [weak self] _ in
                self?.map.renderTrack()
            }
            if mapView.mapboxMap.isStyleLoaded { map.renderTrack() }
        }
    }
}

@MainActor private func mapInitOptions(style: MapStyle) -> MapInitOptions {
    MapService.configure()
    return MapInitOptions(cameraOptions: CameraOptions(zoom: 14, bearing: 0, pitch: 0), styleURI: style.styleURI)
}

// MARK: - Map state

@MainActor @Observable
final class MapViewStore {
    var mapView: ActivityMapView?
    private var needsLocationCenter = true

    private var trackFeatures: [Feature] = []

    private static let trackKinds = [
        TrackClassification.run.rawValue,
        TrackClassification.lift.rawValue,
        "pending",
        "live"
    ]

    /// Center once on the first usable fix, and again after permission is restored.
    /// Subsequent fixes use the selected viewport state, including free panning.
    func updateUserLocation(hasPermission: Bool, coordinate: CLLocationCoordinate2D?) {
        if !hasPermission { needsLocationCenter = true }
        guard let mapView else { return }
        if hasPermission {
            if mapView.location.options.puckType == nil {
                mapView.location.options.puckType = .puck2D()
            }
        } else {
            mapView.location.options.puckType = nil
            mapView.viewport.idle()
        }
        guard hasPermission, needsLocationCenter, let coordinate,
              CLLocationCoordinate2DIsValid(coordinate) else { return }
        needsLocationCenter = false
        mapView.mapboxMap.setCamera(to: CameraOptions(center: coordinate))
        followUser()
    }

    func followUser(zoom: Double? = nil) {
        guard let mapView else { return }
        mapView.location.options.puckType = .puck2D()
        if let zoom {
            mapView.mapboxMap.setCamera(to: CameraOptions(zoom: zoom))
        }
        let state = mapView.viewport.makeFollowPuckViewportState(options: FollowPuckViewportStateOptions(
            zoom: nil, bearing: nil, pitch: nil
        ))
        mapView.viewport.transition(to: state, transition: mapView.viewport.makeImmediateViewportTransition())
    }

    func fitTrack(_ geometry: TrackGeometry, padding: UIEdgeInsets = UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40),
                  fly: Bool = false) -> Bool {
        guard let mapView,
              mapView.bounds.width > padding.left + padding.right,
              mapView.bounds.height > padding.top + padding.bottom
        else { return false }
        let points = geometry.sections.flatMap(\.points)
        guard let first = points.first else { return true }
        var bounds = points.reduce(
            into: (minLat: first.latitude, maxLat: first.latitude,
                   minLon: first.longitude, maxLon: first.longitude)
        ) { bounds, point in
            var longitude = point.longitude
            if longitude - first.longitude > 180 { longitude -= 360 }
            if longitude - first.longitude < -180 { longitude += 360 }
            bounds.minLat = min(bounds.minLat, point.latitude)
            bounds.maxLat = max(bounds.maxLat, point.latitude)
            bounds.minLon = min(bounds.minLon, longitude)
            bounds.maxLon = max(bounds.maxLon, longitude)
        }
        if bounds.minLat == bounds.maxLat && bounds.minLon == bounds.maxLon {
            // Fit a small area so a stopped section also centers above the sheet.
            bounds.minLat = max(-90, bounds.minLat - 0.0005)
            bounds.maxLat = min(90, bounds.maxLat + 0.0005)
            bounds.minLon -= 0.0005
            bounds.maxLon += 0.0005
        }
        let coordinates = [
            CLLocationCoordinate2D(latitude: bounds.minLat, longitude: bounds.minLon),
            CLLocationCoordinate2D(latitude: bounds.minLat, longitude: bounds.maxLon),
            CLLocationCoordinate2D(latitude: bounds.maxLat, longitude: bounds.minLon),
            CLLocationCoordinate2D(latitude: bounds.maxLat, longitude: bounds.maxLon)
        ]
        do {
            let reference = CameraOptions(padding: padding, bearing: mapView.mapboxMap.cameraState.bearing,
                                          pitch: mapView.mapboxMap.cameraState.pitch)
            var camera = try mapView.mapboxMap.camera(for: coordinates, camera: reference, coordinatesPadding: .zero,
                                                     maxZoom: mapView.maximumZoomLevel, offset: nil)
            camera.padding = padding
            if fly {
                mapView.fly(to: camera, duration: 0.6)
            } else {
                mapView.camera.cancelAnimations()
                mapView.mapboxMap.setCamera(to: camera)
            }
        } catch {
            return false
        }
        return true
    }

    func updateTrack(_ geometry: TrackGeometry?) {
        trackFeatures = geometry?.sections.compactMap { Self.feature(points: $0.points, kind: "live") } ?? []
        renderTrack()
    }

    func updateSessionTrack(_ geometry: TrackGeometry, passages: SkiActivityDetector.Result?) {
        if let passages {
            trackFeatures = Geo.classifiedSections(in: geometry, passages: passages).compactMap {
                Self.feature(points: $0.points, kind: $0.classification.rawValue)
            }
        } else {
            trackFeatures = geometry.sections.compactMap { Self.feature(points: $0.points, kind: "pending") }
        }
        renderTrack()
    }

    private static func feature(points: [TrackPoint], kind: String) -> Feature? {
        guard points.count >= 2 else { return nil }
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        var feature = Feature(geometry: .lineString(LineString(coordinates)))
        feature.properties = ["classification": .string(kind)]
        return feature
    }

    /// Both live and inspected maps preserve recording and GPS-gap segments.
    func renderTrack() {
        guard let mapboxMap = mapView?.mapboxMap, mapboxMap.isStyleLoaded else { return }
        let collection = FeatureCollection(features: trackFeatures)
        if mapboxMap.sourceExists(withId: "user-track") {
            mapboxMap.updateGeoJSONSource(withId: "user-track", geoJSON: .featureCollection(collection))
            return
        }
        do {
            var source = GeoJSONSource(id: "user-track")
            source.data = .featureCollection(collection)
            try mapboxMap.addSource(source)

            var casing = LineLayer(id: "user-track-casing", source: source.id)
            casing.lineColor = .constant(StyleColor(ActivityTrackStyle.outlineColor))
            casing.lineWidth = .constant(4.5)
            casing.lineCap = .constant(.round)
            casing.lineJoin = .constant(.round)
            try mapboxMap.addLayer(casing)

            for kind in Self.trackKinds {
                var line = LineLayer(id: "user-track-\(kind)", source: source.id)
                line.filter = Exp(.eq) { Exp(.get) { "classification" }; kind }
                line.lineColor = .constant(StyleColor(ActivityTrackStyle.color))
                line.lineWidth = .constant(2.5)
                line.lineCap = .constant(.round)
                line.lineJoin = .constant(.round)
                try mapboxMap.addLayer(line)
            }
        } catch {
            // Route rendering cannot interrupt recording or saved activity inspection.
            Logger(subsystem: "com.samuel.sunoh", category: "map").error("Unable to add the activity route layers.")
        }
    }
}
