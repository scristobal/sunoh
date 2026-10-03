import MapboxMaps
import SwiftUI
import Turf

struct OfflineStatusMapView: View {
    var obscuredBottom: CGFloat = 0
    @Environment(OfflineMaps.self) private var offline
    @State private var mapIssue: String?

    var body: some View {
        Group {
            if let issue = MapService.configurationIssue {
                ContentUnavailableView("Map unavailable", systemImage: "map", description: Text(issue))
            } else {
                OfflineStatusMap(regions: offline.regions, downloads: offline.downloads,
                    focusedRegion: nil, obscuredBottom: obscuredBottom, onIssue: { mapIssue = $0 })
            }
        }
        .alert("Map unavailable", isPresented: Binding(get: { mapIssue != nil }, set: { if !$0 { mapIssue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(mapIssue ?? "") }
    }
}

struct OfflineStatusMap: UIViewRepresentable {
    let regions: [OfflineRegion]
    let downloads: [String: OfflineMapRecord]
    let focusedRegion: OfflineRegion?
    var obscuredBottom: CGFloat = 0
    let onIssue: (String?) -> Void
    var isPreview = false

    func makeCoordinator() -> Coordinator { Coordinator(focus: focusedRegion, isPreview: isPreview, onIssue: onIssue) }

    func makeUIView(context: Context) -> MapView {
        MapService.configure()
        let options = MapInitOptions(
            cameraOptions: CameraOptions(center: CLLocationCoordinate2D(latitude: 46.6, longitude: 10.4), zoom: 6, bearing: 0, pitch: 0), styleURI: MapService.styleURI)
        let map = CoverageMapView(frame: .zero, mapInitOptions: options)
        context.coordinator.map = map
        context.coordinator.update(regions: regions, records: downloads)
        context.coordinator.observation = map.mapboxMap.onStyleLoaded.observe { [weak coordinator = context.coordinator] _ in coordinator?.render() }
        map.onLayout = { [weak coordinator = context.coordinator] in coordinator?.render() }
        map.gestures.options.pitchEnabled = false
        map.gestures.options.rotateEnabled = false
        map.isUserInteractionEnabled = !isPreview
        if isPreview {
            map.ornaments.options.compass.visibility = .hidden
            map.ornaments.options.scaleBar.visibility = .hidden
        }
        return map
    }

    func updateUIView(_ uiView: MapView, context: Context) {
        context.coordinator.update(regions: regions, records: downloads)
        uiView.ornaments.options.logo.margins.y = obscuredBottom + 8
        uiView.ornaments.options.attributionButton.margins.y = obscuredBottom + 8
        context.coordinator.render()
    }

    @MainActor final class Coordinator {
        weak var map: MapView?
        var observation: AnyCancelable?
        let focus: OfflineRegion?
        let isPreview: Bool
        private var framedSize: CGSize?
        private var records: [String: OfflineMapRecord] = [:]
        private var features = FeatureCollection(features: [])
        private var resorts = FeatureCollection(features: [])
        private var renderedFeatures: FeatureCollection?
        private var renderedResorts: FeatureCollection?
        let onIssue: (String?) -> Void

        init(focus: OfflineRegion?, isPreview: Bool, onIssue: @escaping (String?) -> Void) {
            self.focus = focus
            self.isPreview = isPreview
            self.onIssue = onIssue
        }

        func update(regions: [OfflineRegion], records: [String: OfflineMapRecord]) {
            self.records = records
            let ordered = regions.sorted {
                let firstFocused = $0.id == focus?.id, secondFocused = $1.id == focus?.id
                if firstFocused != secondFocused { return firstFocused }
                if $0.approximateAreaSquareMeters != $1.approximateAreaSquareMeters {
                    return $0.approximateAreaSquareMeters > $1.approximateAreaSquareMeters
                }
                let nameOrder = $0.name.localizedStandardCompare($1.name)
                return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
            }
            resorts = FeatureCollection(features: ordered.enumerated().map { priority, region in
                var feature = Feature(geometry: .point(Point(region.center)))
                feature.identifier = .string(region.id)
                feature.properties = ["name": .string(region.name), "priority": .number(Double(priority))]
                return feature
            })
        }

        private func updateCoverage() {
            guard !isPreview else {
                features = FeatureCollection(features: [])
                return
            }
            let priorities = ["online": 0, "failed": 1, "queued": 2, "downloading": 2, "downloaded": 3]
            var states: [OfflineTile: String] = [:]
            for record in records.values {
                let state = record.hasSavedMap ? "downloaded" : record.phase.rawValue
                for tile in record.region.tileCoverage[OfflineTileGrid.coverageIndexZoom] ?? [] where priorities[state, default: 0] > priorities[states[tile] ?? "online", default: 0] {
                    states[tile] = state
                }
            }
            features = FeatureCollection(features: states.keys.sorted { $0.id < $1.id }.flatMap { pack in
                OfflineTileGrid.coverageTiles(for: pack).map { tile in
                    var feature = Feature(geometry: tile.geometry)
                    feature.identifier = .string(tile.id)
                    feature.properties = ["status": .string(states[pack] ?? "online")]
                    return feature
                }
            })
        }

        func render() {
            guard let map, map.mapboxMap.isStyleLoaded else { return }
            updateCoverage()
            do {
                if !map.mapboxMap.sourceExists(withId: "offline-tiles") {
                    map.mapboxMap.removeTerrain()
                    try map.mapboxMap.setProjection(StyleProjection(name: .mercator))
                    try map.mapboxMap.setCameraBounds(with: CameraBoundsOptions(maxPitch: 0, minPitch: 0))
                    for layer in map.mapboxMap.allLayerIdentifiers {
                        let sourceLayer = map.mapboxMap.layerPropertyValue(for: layer.id, property: "source-layer") as? String ?? ""
                        if layer.type == .symbol || layer.type == .fillExtrusion || layer.type.rawValue == "model" || sourceLayer.hasPrefix("ski_areas") {
                            try map.mapboxMap.removeLayer(withId: layer.id)
                        }
                    }
                    var source = GeoJSONSource(id: "offline-tiles")
                    source.data = .featureCollection(features)
                    try map.mapboxMap.addSource(source)
                    var fill = FillLayer(id: "offline-coverage", source: source.id)
                    fill.fillColor = .expression(Exp(.match) {
                        Exp(.get) { "status" }
                        "downloaded"; "#27AE60"
                        "failed"; "#E64949"
                        "queued"; "#F59B23"
                        "downloading"; "#F59B23"
                        "rgba(0,0,0,0)"
                    })
                    fill.fillOpacity = .constant(0.26)
                    fill.fillAntialias = .constant(false)
                    try map.mapboxMap.addLayer(fill)
                    var resortSource = GeoJSONSource(id: "offline-resorts")
                    resortSource.data = .featureCollection(resorts)
                    try map.mapboxMap.addSource(resortSource)
                    var names = SymbolLayer(id: "offline-resort-names", source: resortSource.id)
                    if !isPreview { names.minZoom = 10 }
                    names.textField = .expression(Exp(.get) { "name" })
                    names.textFont = .constant(["DIN Pro Medium", "Arial Unicode MS Regular"])
                    names.textSize = .constant(14)
                    names.textMaxWidth = .constant(10)
                    names.textPadding = .constant(6)
                    names.textAllowOverlap = .constant(false)
                    names.symbolSortKey = .expression(Exp(.get) { "priority" })
                    names.textColor = .constant(StyleColor(UIColor(red: 0.09, green: 0.23, blue: 0.30, alpha: 1)))
                    names.textHaloColor = .constant(StyleColor(.white))
                    names.textHaloWidth = .constant(1.5)
                    try map.mapboxMap.addLayer(names)
                    renderedFeatures = features
                    renderedResorts = resorts
                } else {
                    if renderedResorts != resorts {
                        map.mapboxMap.updateGeoJSONSource(withId: "offline-resorts", geoJSON: .featureCollection(resorts))
                        renderedResorts = resorts
                    }
                    if renderedFeatures != features {
                        map.mapboxMap.updateGeoJSONSource(withId: "offline-tiles", geoJSON: .featureCollection(features))
                        renderedFeatures = features
                    }
                }
            } catch {
                onIssue(isPreview ? "This resort preview could not be drawn." : "Coverage could not be drawn. Switch to the list and return to the map.")
            }
            if let focus, map.bounds.width > 0, map.bounds.height > 0, framedSize != map.bounds.size {
                do {
                    let camera = try map.mapboxMap.camera(for: focus.coordinates,
                        camera: CameraOptions(bearing: 0, pitch: 0), coordinatesPadding: UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24), maxZoom: 16, offset: nil)
                    framedSize = map.bounds.size
                    map.mapboxMap.setCamera(to: camera)
                } catch { onIssue("This resort could not be shown in the preview.") }
            }
        }
    }
}

private final class CoverageMapView: MapView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
