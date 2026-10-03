import Foundation
import MapboxMaps
import Network
import Observation
import Turf
import UIKit

@MainActor @Observable
final class OfflineMaps {
    private(set) var catalog: [OfflineRegion] = []
    private(set) var downloads: [String: OfflineMapRecord] = [:]
    private(set) var allowsMobileData = false
    private(set) var storageBytes: Int64 = 0
    private(set) var isReady = false
    private(set) var catalogError: String?
    private(set) var issue: String?
    private(set) var removing = Set<String>()
    private(set) var connection: Connection = .checking

    enum Connection { case checking, offline, wifiRequired, ready }
    private struct Snapshot: Codable {
        var allowsMobileData: Bool
        var format: String
        var records: [String: OfflineMapRecord]
    }
    private struct Active { let id: String; let token: UUID }
    private static let persistenceIssue = "Download requests could not be saved. Free some space and reopen Sunō before requesting another map."
    @ObservationIgnored private var manager: OfflineManager?
    @ObservationIgnored private var tileStore: TileStore?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var networkSatisfied = false
    @ObservationIgnored private var networkExpensive = false
    @ObservationIgnored private var networkCellular = false
    @ObservationIgnored private var active: Active?
    @ObservationIgnored private var operation: (any Cancelable)?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var storageTask: Task<Void, Never>?
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastProgressSave = Date.distantPast
    private var snapshotURL: URL { MapService.offlineStorageURL.appendingPathComponent("requests.json") }

    var selectedRegions: [OfflineRegion] {
        downloads.values.map(\.region).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var regions: [OfflineRegion] {
        var byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        for request in downloads.values { byID[request.region.id] = request.region }
        return byID.values.sorted {
            let firstSaved = downloads[$0.id] != nil, secondSaved = downloads[$1.id] != nil
            if firstSaved != secondSaved { return firstSaved }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var storageText: String { Self.formatBytes(storageBytes) }
    var canRequest: Bool { isReady && MapService.configurationIssue == nil && issue == nil && removing.isEmpty }

    func start() async {
        guard !started else { return }
        started = true
        do { catalog = try await Task.detached { try OfflineRegion.loadCatalog() }.value }
        catch { catalogError = error.localizedDescription }
        guard MapService.configure() else {
            issue = MapService.configurationIssue
            return
        }
        manager = OfflineManager()
        tileStore = .default
        do {
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                let data = try Data(contentsOf: snapshotURL)
                if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.format == "resort-regions" {
                    downloads = snapshot.records
                    allowsMobileData = snapshot.allowsMobileData
                } else if let old = try JSONSerialization.jsonObject(with: data) as? [String: Any], old["cells"] != nil {
                    allowsMobileData = old["allowsMobileData"] as? Bool ?? false
                    try await resetGridDownloads()
                } else { throw CocoaError(.fileReadCorruptFile) }
            }
        } catch {
            issue = "Saved map requests could not be read. Reopen Sunō to try again. Existing map data is still on this iPhone."
            isReady = true
            refreshStorage()
            return
        }
        do { try await reconcile() }
        catch { issue = "Offline map storage could not be read. Reopen Sunō to try again." }
        for id in downloads.keys where downloads[id]?.phase == .downloading { downloads[id]?.phase = .queued }
        isReady = true
        _ = persist()
        refreshStorage()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let expensive = path.isExpensive
            let cellular = path.usesInterfaceType(.cellular)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.networkSatisfied = satisfied
                self.networkExpensive = expensive
                self.networkCellular = cellular
                self.updateConnection()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.samuel.sunoh.offline-network"))
    }

    func setMobileDataAllowed(_ allowed: Bool) {
        let previous = allowsMobileData
        allowsMobileData = allowed
        guard persist() else { allowsMobileData = previous; return }
        updateConnection()
    }

    func setForeground(_ value: Bool) {
        foreground = value
        if value {
            endBackgroundTask()
            refreshStorage()
            Task { [weak self] in
                guard let self, self.isReady else { return }
                do { try await self.reconcile() }
                catch { self.issue = "Offline map storage could not be read. Reopen Sunō to try again." }
                _ = self.persist()
                self.pump()
            }
        } else if active != nil && backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish offline map download") { [weak self] in
                Task { @MainActor [weak self] in self?.interrupt(); self?.endBackgroundTask() }
            }
        }
    }

    func isSelected(_ region: OfflineRegion) -> Bool { downloads[region.id] != nil }

    func error(for region: OfflineRegion) -> String? { downloads[region.id]?.error }

    @discardableResult func request(_ region: OfflineRegion) -> Bool {
        guard canRequest, !isSelected(region) else { return false }
        let record = OfflineMapRecord(region: region, styleURI: MapService.styleURI.rawValue)
        downloads[region.id] = record
        guard persist() else { downloads.removeValue(forKey: region.id); return false }
        pump()
        return true
    }

    func delete(_ region: OfflineRegion) async {
        guard let tileStore, let record = downloads[region.id], removing.isEmpty else { return }
        removing.insert(region.id)
        defer { removing.remove(region.id); refreshStorage(); pump() }
        if active?.id == region.id { interrupt() }
        do {
            let identifiers = Set(try await allTileRegions().map(\.id))
            if identifiers.contains(region.tileRegionID) {
                let _: TileRegion = try await withCheckedThrowingContinuation { continuation in
                    tileStore.removeRegion(forId: region.tileRegionID) { continuation.resume(with: $0) }
                }
            }
            downloads.removeValue(forKey: region.id)
            guard persist() else { downloads[region.id] = record; return }
            if downloads.isEmpty, let manager, let uri = StyleURI(rawValue: record.styleURI) {
                let packs = try await allStylePacks()
                if packs.contains(where: { $0.styleURI == record.styleURI }) {
                    let _: StylePack = try await withCheckedThrowingContinuation { continuation in
                        manager.removeStylePack(for: uri) { continuation.resume(with: $0) }
                    }
                }
            }
            let _: UInt32 = try await withCheckedThrowingContinuation { continuation in
                tileStore.clearAmbientCache { continuation.resume(with: $0) }
            }
        } catch {
            if downloads[region.id] != nil {
                downloads[region.id]?.error = "The map could not be deleted. Try again after reopening Sunō."
                _ = persist()
            } else { issue = "The map was removed, but some cached data could not be cleared. Reopen Sunō to reclaim the space." }
        }
    }

    func refreshStorage() {
        guard storageTask == nil else { return }
        let directory = MapService.offlineStorageURL
        storageTask = Task { [weak self] in
            let bytes = await Task.detached(priority: .utility) {
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
                guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { return Int64(0) }
                return files.compactMap { $0 as? URL }.reduce(Int64(0)) { total, url in
                    guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return total }
                    return total + Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                }
            }.value
            self?.storageBytes = bytes
            self?.storageTask = nil
        }
    }

    static func formatBytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private func updateConnection() {
        connection = !networkSatisfied ? .offline : (!allowsMobileData && (networkExpensive || networkCellular) ? .wifiRequired : .ready)
        if connection != .ready { interrupt() }
        else {
            for id in downloads.keys where downloads[id]?.isPending == true { downloads[id]?.retryAfter = nil }
            pump()
        }
    }

    private func pump() {
        guard foreground, isReady, issue == nil, connection == .ready, active == nil, removing.isEmpty else { return }
        let pending = downloads.values.filter(\.isPending).sorted { $0.requestedAt < $1.requestedAt }
        guard !pending.isEmpty else { return }
        guard let record = pending.first(where: { ($0.retryAfter ?? .distantPast) <= Date() }) else {
            retryTask?.cancel()
            let date = pending.compactMap(\.retryAfter).min() ?? Date()
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
                if !Task.isCancelled { self?.pump() }
            }
            return
        }
        guard let manager, let uri = StyleURI(rawValue: record.styleURI),
              let options = StylePackLoadOptions(glyphsRasterizationMode: .ideographsRasterizedLocally,
                  acceptExpired: true, extraOptions: ["network-restriction-disallow-expensive": !allowsMobileData]) else {
            issue = "The map download service could not be prepared. Reopen Sunō to try again."
            return
        }
        let work = Active(id: record.region.id, token: UUID())
        active = work
        downloads[work.id]?.phase = .downloading
        downloads[work.id]?.retryAfter = nil
        _ = persist()
        operation = manager.loadStylePack(for: uri, loadOptions: options) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.active?.token == work.token else { return }
                switch result {
                case .success(let pack):
                    guard pack.requiredResourceCount > 0, pack.completedResourceCount == pack.requiredResourceCount else {
                        self.finish(work, error: CocoaError(.fileReadCorruptFile))
                        return
                    }
                    self.loadTiles(work)
                case .failure(let error): self.finish(work, error: error)
                }
            }
        }
    }

    private func loadTiles(_ work: Active) {
        guard let tileStore, let record = downloads[work.id] else { return }
        var metadata = ["resortID": record.region.id, "name": record.region.name, "styleURI": record.styleURI]
        if let version = record.mapVersion { metadata["mapVersion"] = version }
        guard let options = loadOptions(geometry: record.region.geometry, styleURI: record.styleURI, metadata: metadata) else { return }
        operation = tileStore.loadTileRegion(forId: record.region.tileRegionID, loadOptions: options, progress: { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.active?.token == work.token else { return }
                self.downloads[work.id]?.completedResources = progress.completedResourceCount
                self.downloads[work.id]?.requiredResources = progress.requiredResourceCount
                if Date().timeIntervalSince(self.lastProgressSave) > 2 {
                    self.lastProgressSave = Date()
                    _ = self.persist()
                    self.refreshStorage()
                }
            }
        }) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.active?.token == work.token else { return }
                switch result {
                case .success(let region):
                    self.downloads[work.id]?.completedResources = region.completedResourceCount
                    self.downloads[work.id]?.requiredResources = region.requiredResourceCount
                    let complete = region.requiredResourceCount > 0 && region.completedResourceCount == region.requiredResourceCount
                    self.downloads[work.id]?.hasSavedMap = complete
                    self.finish(work, error: complete ? nil : CocoaError(.fileReadCorruptFile))
                case .failure(let error): self.finish(work, error: error)
                }
            }
        }
    }

    private func loadOptions(geometry: Geometry, styleURI: String, metadata: [String: String]? = nil) -> TileRegionLoadOptions? {
        guard let manager, let uri = StyleURI(rawValue: styleURI) else { return nil }
        let styleOptions = StylePackLoadOptions(glyphsRasterizationMode: .ideographsRasterizedLocally,
            acceptExpired: true, extraOptions: ["network-restriction-disallow-expensive": !allowsMobileData])
        let descriptor = manager.createTilesetDescriptor(for: TilesetDescriptorOptions(styleURI: uri,
            zoomRange: 0...16, tilesets: nil, stylePackOptions: styleOptions))
        return TileRegionLoadOptions(geometry: geometry, descriptors: [descriptor], metadata: metadata,
            acceptExpired: true, networkRestriction: allowsMobileData ? .none : .disallowExpensive)
    }

    private func finish(_ work: Active, error: (any Error)?) {
        guard active?.token == work.token else { return }
        active = nil
        operation = nil
        endBackgroundTask()
        if let error {
            if connection != .ready || isTransient(error) {
                downloads[work.id]?.phase = .queued
                downloads[work.id]?.retryAfter = Date().addingTimeInterval(30)
            } else {
                downloads[work.id]?.phase = .failed
                downloads[work.id]?.error = friendlyError(error)
            }
        } else {
            downloads[work.id]?.phase = .downloaded
            downloads[work.id]?.error = nil
            downloads[work.id]?.retryAfter = nil
        }
        _ = persist()
        refreshStorage()
        pump()
    }

    private func interrupt() {
        guard let work = active else { return }
        active = nil
        operation?.cancel()
        operation = nil
        downloads[work.id]?.phase = .queued
        _ = persist()
        refreshStorage()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func friendlyError(_ error: any Error) -> String {
        if case .diskFull = error as? StylePackError {
            return "There is not enough space on this iPhone. Free some space or delete an offline map, then retry."
        }
        if let error = error as? TileRegionError {
            switch error {
            case .diskFull: return "There is not enough space on this iPhone. Free some space or delete an offline map, then retry."
            case .tileCountExceeded: return "The offline map limit has been reached. Delete an offline map, then retry."
            case .tilesetDescriptor: return "Blue Snow 3D map data could not be loaded. Try again later."
            default: break
            }
        }
        return "The map could not be downloaded. Check your connection and retry. If it keeps failing, try again later."
    }

    private func isTransient(_ error: any Error) -> Bool {
        if let error = error as? TileRegionError {
            switch error {
            case .diskFull, .tileCountExceeded, .tilesetDescriptor, .doesNotExist: return false
            case .canceled: return true
            case .other: break
            @unknown default: return false
            }
        }
        if let error = error as? StylePackError {
            switch error {
            case .diskFull, .doesNotExist: return false
            case .canceled: return true
            case .other: break
            @unknown default: return false
            }
        }
        return ["network", "connection", "timed out", "timeout", "resolve host"].contains {
            error.localizedDescription.localizedCaseInsensitiveContains($0)
        }
    }

    @discardableResult private func persist() -> Bool {
        do {
            let data = try JSONEncoder().encode(Snapshot(allowsMobileData: allowsMobileData, format: "resort-regions", records: downloads))
            try data.write(to: snapshotURL, options: .atomic)
            if issue == Self.persistenceIssue { issue = nil }
            return true
        } catch {
            issue = Self.persistenceIssue
            return false
        }
    }

    private func allTileRegions() async throws -> [TileRegion] {
        guard let tileStore else { return [] }
        return try await withCheckedThrowingContinuation { continuation in tileStore.allTileRegions { continuation.resume(with: $0) } }
    }

    private func allStylePacks() async throws -> [StylePack] {
        guard let manager else { return [] }
        return try await withCheckedThrowingContinuation { continuation in manager.allStylePacks { continuation.resume(with: $0) } }
    }

    private func resetGridDownloads() async throws {
        guard let tileStore else { return }
        for region in try await allTileRegions() where region.id.hasPrefix("sunoh-") {
            let _: TileRegion = try await withCheckedThrowingContinuation { continuation in
                tileStore.removeRegion(forId: region.id) { continuation.resume(with: $0) }
            }
        }
        let _: UInt32 = try await withCheckedThrowingContinuation { continuation in
            tileStore.clearAmbientCache { continuation.resume(with: $0) }
        }
        downloads = [:]
    }

    private func reconcile() async throws {
        guard let manager, let tileStore else { return }
        let regions = try await allTileRegions()
        let byID = Dictionary(uniqueKeysWithValues: regions.map { ($0.id, $0) })
        let styles = Set(try await allStylePacks().filter { $0.completedResourceCount == $0.requiredResourceCount && $0.requiredResourceCount > 0 }.map(\.styleURI))
        let owned = Set(downloads.values.map { $0.region.tileRegionID })
        for region in regions where region.id.hasPrefix("sunoh-resort-") && !owned.contains(region.id) {
            let _: TileRegion = try await withCheckedThrowingContinuation { continuation in
                tileStore.removeRegion(forId: region.id) { continuation.resume(with: $0) }
            }
        }
        for id in downloads.keys where active?.id != id {
            guard var record = downloads[id] else { continue }
            if let region = byID[record.region.tileRegionID] {
                record.completedResources = region.completedResourceCount
                record.requiredResources = region.requiredResourceCount
                var complete = region.requiredResourceCount > 0 && region.completedResourceCount == region.requiredResourceCount && styles.contains(record.styleURI)
                if complete, let uri = StyleURI(rawValue: record.styleURI) {
                    let styleOptions = StylePackLoadOptions(glyphsRasterizationMode: .ideographsRasterizedLocally,
                        acceptExpired: true, extraOptions: ["network-restriction-disallow-expensive": !allowsMobileData])
                    let descriptor = manager.createTilesetDescriptor(for: TilesetDescriptorOptions(styleURI: uri,
                        zoomRange: 0...16, tilesets: nil, stylePackOptions: styleOptions))
                    complete = try await withCheckedThrowingContinuation { continuation in
                        tileStore.tileRegionContainsDescriptors(forId: record.region.tileRegionID, descriptors: [descriptor]) { continuation.resume(with: $0) }
                    }
                }
                record.hasSavedMap = complete
                if complete {
                    record.phase = .downloaded
                    record.error = nil
                    record.retryAfter = nil
                } else if !record.isPending {
                    record.phase = .failed
                    record.error = "This map is incomplete. Delete it and download it again."
                }
            } else {
                record.hasSavedMap = false
                if !record.isPending {
                    record.phase = .failed
                    record.error = "Saved map data is missing. Delete this map and download it again."
                }
            }
            downloads[id] = record
        }
    }
}
