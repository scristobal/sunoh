import Foundation

/// Opens the bundled reference data separately from the recording store.
actor SkiDataCatalog {
    struct ReferenceData: Sendable {
        let datasetVersion: String?
        let features: [SkiFeature]
        var failure: String? = nil

        func match(geometry: TrackGeometry, timeline: ActivityTimeline) -> SkiTimelineMatches {
            guard failure == nil, let datasetVersion else {
                return SkiTimelineMatches(datasetVersion: datasetVersion,
                    entries: Array(repeating: [], count: timeline.entries.count), resorts: [], failure: failure)
            }
            return SkiFeatureMatcher.match(geometry: geometry, timeline: timeline,
                                           features: features, datasetVersion: datasetVersion)
        }
    }

    static let shared = SkiDataCatalog(directory: Bundle.main.resourceURL?.appendingPathComponent("SkiData", isDirectory: true))
    private let directory: URL?
    private var cachedStore: SkiFeatureStore?

    init(directory: URL?) { self.directory = directory }

    func store() throws -> SkiFeatureStore {
        if let cachedStore { return cachedStore }
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        let store = try SkiFeatureStore(directory: directory)
        cachedStore = store
        return store
    }

    nonisolated static func referenceData(for geometry: TrackGeometry,
                                         catalog: SkiDataCatalog = .shared) async throws -> ReferenceData {
        try Task.checkCancellation()
        var version: String?
        do {
            let store = try await catalog.store()
            version = store.datasetVersion
            try Task.checkCancellation()
            let features = try store.features(for: geometry)
            try Task.checkCancellation()
            return ReferenceData(datasetVersion: version, features: features)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return ReferenceData(datasetVersion: version, features: [],
                failure: "Lift and ski-area matching is unavailable. Your recording and statistics are still available.")
        }
    }

    nonisolated static func match(geometry: TrackGeometry, timeline: ActivityTimeline,
                                  catalog: SkiDataCatalog = .shared) async throws -> SkiTimelineMatches {
        try Task.checkCancellation()
        guard timeline.entries.contains(where: { $0.kind == .lift }) else {
            return SkiTimelineMatches(datasetVersion: nil,
                entries: Array(repeating: [], count: timeline.entries.count), resorts: [])
        }
        let reference = try await referenceData(for: geometry, catalog: catalog)
        try Task.checkCancellation()
        let result = reference.match(geometry: geometry, timeline: timeline)
        try Task.checkCancellation()
        return result
    }
}
