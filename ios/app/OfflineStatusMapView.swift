import MapboxMaps
import SwiftUI
import Turf

struct OfflineStatusMapView: View {
    @Environment(OfflineMaps.self) private var offline
    @State private var mapIssue: String?

    var body: some View {
        Group {
            if let issue = MapService.configurationIssue {
                ContentUnavailableView("Map unavailable", systemImage: "map", description: Text(issue))
            } else {
                OfflineStatusMap(regions: offline.regions, downloads: offline.downloads,
                    focusedRegion: nil, onIssue: { mapIssue = $0 })
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
        map.ornaments.options.scaleBar.visibility = .hidden
        if isPreview {
            map.ornaments.options.compass.visibility = .hidden
        }
        return map
    }

    func updateUIView(_ uiView: MapView, context: Context) {
        context.coordinator.update(regions: regions, records: downloads)
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
        private var outlines = FeatureCollection(features: [])
        private var resorts = FeatureCollection(features: [])
        private var renderedFeatures: FeatureCollection?
        private var renderedOutlines: FeatureCollection?
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

        // Areas without offline data are veiled. Downloaded areas show the map at full intensity inside an outline,
        // and areas still downloading lose their veil as the download progresses.
        private func updateCoverage() {
            guard !isPreview else {
                features = FeatureCollection(features: [])
                outlines = FeatureCollection(features: [])
                return
            }
            var completion: [OfflineTile: Double] = [:]
            for record in records.values {
                let completed: Double
                if record.hasSavedMap {
                    completed = 1
                } else if record.isPending, record.requiredResources > 0 {
                    // Steps of 5% keep progress updates from redrawing the coverage for every resource.
                    completed = min(1, (Double(record.completedResources) / Double(record.requiredResources) * 20).rounded(.down) / 20)
                } else {
                    continue
                }
                guard completed > 0 else { continue }
                for pack in record.region.tileCoverage[OfflineTileGrid.coverageIndexZoom] ?? [] {
                    completion[pack] = max(completion[pack] ?? 0, completed)
                }
            }
            let veiled = OfflineTileGrid.complement(of: Set(completion.keys)).map { ($0, 1.0) }
                + completion.filter { $0.value < 1 }.sorted { $0.key.id < $1.key.id }.map { ($0.key, 1 - $0.value) }
            features = FeatureCollection(features: veiled.map { tile, veil in
                var feature = Feature(geometry: tile.geometry)
                feature.identifier = .string(tile.id)
                feature.properties = ["opacity": .number(Self.veilOpacity * veil)]
                return feature
            })
            // Line layers draw polygon rings as closed lines, so the corner where a ring starts gets a proper join.
            let downloaded = Set(completion.filter { $0.value >= 1 }.keys)
            outlines = FeatureCollection(features: OfflineTileGrid.outline(of: downloaded).map { ring in
                Feature(geometry: .polygon(Polygon([ring.map(\.coordinate)])))
            })
        }

        private static let veilOpacity = 0.8

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
                    fill.fillColor = .constant(StyleColor(.white))
                    fill.fillOpacity = .expression(Exp(.get) { "opacity" })
                    fill.fillAntialias = .constant(false)
                    try map.mapboxMap.addLayer(fill)
                    var outlineSource = GeoJSONSource(id: "offline-outlines")
                    outlineSource.data = .featureCollection(outlines)
                    try map.mapboxMap.addSource(outlineSource)
                    var outline = LineLayer(id: "offline-coverage-outline", source: outlineSource.id)
                    outline.lineColor = .constant(StyleColor(UIColor(white: 0.3, alpha: 1)))
                    outline.lineWidth = .expression(Exp(.interpolate) {
                        Exp(.linear)
                        Exp(.zoom)
                        6
                        0.75
                        12
                        2
                    })
                    outline.lineJoin = .constant(.miter)
                    try map.mapboxMap.addLayer(outline)
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
                    renderedOutlines = outlines
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
                    if renderedOutlines != outlines {
                        map.mapboxMap.updateGeoJSONSource(withId: "offline-outlines", geoJSON: .featureCollection(outlines))
                        renderedOutlines = outlines
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
