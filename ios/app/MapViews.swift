import CoreLocation
import MapLibre
import SwiftUI

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
        StaticMapViewRepresentable(map: map, geometry: geometry, passages: passages, maximumZoomLevel: maximumZoomLevel,
                                   obscuredBottom: obscuredBottom, safeTop: safeTop,
                                   contextPadding: contextPadding, fliesToChanges: fliesToChanges)
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
    let passages: SkiActivityDetector.Result?
    let maximumZoomLevel: Double
    var obscuredBottom: CGFloat = 0
    var safeTop: CGFloat = 0
    var contextPadding: CGFloat = 24
    var fliesToChanges = false

    func makeUIView(context: Context) -> ActivityMapView {
        let mapView = ActivityMapView(frame: .zero, styleURL: Self.resolvedStyleURL())
        mapView.maximumZoomLevel = maximumZoomLevel
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

    func updateUIView(_ mapView: ActivityMapView, context: Context) {
        mapView.maximumZoomLevel = maximumZoomLevel
        context.coordinator.update(geometry: geometry, passages: passages, obscuredBottom: obscuredBottom, safeTop: safeTop,
                                   contextPadding: contextPadding, fliesToChanges: fliesToChanges)
        context.coordinator.fitTrackIfNeeded(in: mapView)
    }

    static func dismantleUIView(_ mapView: ActivityMapView, coordinator: Coordinator) {
        coordinator.cancelPendingFit()
        mapView.onLayout = nil
        mapView.delegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(map: map, geometry: geometry, passages: passages, obscuredBottom: obscuredBottom, safeTop: safeTop,
                    contextPadding: contextPadding, fliesToChanges: fliesToChanges)
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
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

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            map.updateSessionTrack(geometry, passages: passages)
            hasLoadedStyle = true
            fittedRequest = nil
            // Style loading can finish before SwiftUI gives the map a frame.
            mapView.setNeedsLayout()
        }

        func fitTrackIfNeeded(in mapView: MLNMapView) {
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

    static func resolvedStyleURL() -> URL {
        mapStyleURL()
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
    private var needsLocationCenter = true

    private var trackFeatures: [MLNPolylineFeature] = []

    private static let trackColours: [(kind: String, colour: UIColor)] = [
        (TrackClassification.run.rawValue, .systemBlue),
        (TrackClassification.lift.rawValue, .systemGreen),
        ("pending", .systemGray),
        ("live", .systemPurple)
    ]

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

    func followUser(zoom: Double? = nil) {
        guard let mapView else { return }
        mapView.showsUserLocation = true
        if let zoom {
            mapView.setZoomLevel(zoom, animated: false)
        }
        mapView.setUserTrackingMode(.follow, animated: false, completionHandler: nil)
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
        let coordinateBounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: bounds.minLat, longitude: bounds.minLon),
            ne: CLLocationCoordinate2D(latitude: bounds.maxLat, longitude: bounds.maxLon)
        )
        let camera = mapView.cameraThatFitsCoordinateBounds(coordinateBounds, edgePadding: padding)
        if fly {
            mapView.fly(to: camera, edgePadding: padding, withDuration: 0.6, completionHandler: nil)
        } else {
            // Apply padding even when the zoom cap leaves the fitted camera unchanged.
            mapView.setCamera(camera, withDuration: 0, animationTimingFunction: nil,
                              edgePadding: padding, completionHandler: nil)
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

    private static func feature(points: [TrackPoint], kind: String) -> MLNPolylineFeature? {
        guard points.count >= 2 else { return nil }
        var coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let feature = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
        feature.attributes = ["classification": kind]
        return feature
    }

    /// Both live and inspected maps preserve recording and GPS-gap segments.
    func renderTrack() {
        guard let style = mapView?.style else { return }
        let shape: MLNShape? = trackFeatures.isEmpty ? nil : MLNShapeCollectionFeature(shapes: trackFeatures)
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

            style.addLayer(casing)
            for (kind, colour) in Self.trackColours {
                let line = MLNLineStyleLayer(identifier: "user-track-\(kind)", source: source)
                line.predicate = NSPredicate(format: "classification == %@", kind)
                line.lineColor = NSExpression(forConstantValue: colour)
                line.lineWidth = NSExpression(forConstantValue: 3)
                line.lineCap = NSExpression(forConstantValue: "round")
                line.lineJoin = NSExpression(forConstantValue: "round")
                line.lineDashPattern = NSExpression(forConstantValue: [2, 1.5])
                style.addLayer(line)
            }
        }
    }
}
