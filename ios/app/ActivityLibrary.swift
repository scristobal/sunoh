import Foundation
import Observation

@MainActor @Observable final class ActivityLibrary {
    private(set) var history: LoadState<[ActivitySummary]> = .loading
    private(set) var processingFailures: [ActivityID: String] = [:]
    let processor: ActivityProcessor
    private let repository: any ActivityPersistence
    @ObservationIgnored var onStorageFailure: (@MainActor (ActivityError) -> Void)?
    @ObservationIgnored private var historyRevision = 0
    @ObservationIgnored private var processingQueue: [ActivityID] = []
    @ObservationIgnored private var processingActivityID: ActivityID?
    @ObservationIgnored private(set) var processingTask: Task<Void, Never>?
    @ObservationIgnored private let thumbnails: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 64; cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()
    @ObservationIgnored private var thumbnailTasks: [ActivityID: Task<Data?, Never>] = [:]

    init(repository: any ActivityPersistence, processor: ActivityProcessor? = nil) {
        self.repository = repository; self.processor = processor ?? ActivityProcessor(repository: repository)
    }

    func reloadHistory() async {
        let revision = historyRevision
        do {
            let saved = try await repository.summaries()
            guard revision == historyRevision else { return }
            history = .loaded(saved)
            scheduleProcessing(saved.map(\.id))
        } catch {
            guard revision == historyRevision else { return }
            history = .failed(error.localizedDescription)
        }
    }

    func didComplete(_ activity: ActivitySummary) async {
        historyRevision += 1
        if case .loaded(let saved) = history {
            history = .loaded(([activity] + saved.filter { $0.id != activity.id }).sorted { $0.startedAt > $1.startedAt })
        } else { await reloadHistory() }
        scheduleProcessing([activity.id])
    }

    func details(id: ActivityID) async throws -> ActivityDetails { try await repository.details(id: id) }
    func analysis(id: ActivityID) async throws -> ActivityAnalysis { try await processor.process(id: id) }

    func thumbnail(id: ActivityID) async -> Data? {
        if let data = thumbnails.object(forKey: id.rawValue as NSString) { return data as Data }
        if let task = thumbnailTasks[id] { return await task.value }
        let task = Task { [processor] in
            let data = try? await processor.process(id: id).thumbnailPNG
            return Task.isCancelled ? nil : data
        }
        thumbnailTasks[id] = task
        let data = await task.value
        thumbnailTasks[id] = nil
        guard !task.isCancelled else { return nil }
        if let data { thumbnails.setObject(data as NSData, forKey: id.rawValue as NSString, cost: data.count) }
        return data
    }

    private func scheduleProcessing(_ ids: [ActivityID]) {
        for id in ids where id != processingActivityID && !processingQueue.contains(id) { processingQueue.append(id) }
        guard processingTask == nil, !processingQueue.isEmpty else { return }
        processingTask = Task(priority: .utility) {
            defer { processingTask = nil; processingActivityID = nil }
            while !processingQueue.isEmpty {
                let id = processingQueue.removeFirst(); processingActivityID = id
                do { _ = try await processor.process(id: id); processingFailures[id] = nil }
                catch {
                    if case .loaded(let saved) = history, saved.contains(where: { $0.id == id }) {
                        processingFailures[id] = error.localizedDescription
                    }
                }
            }
        }
    }

    func importGPX(from url: URL) async throws -> GPXImportResult { try await importTracks(GPXFiles.read(url)) }

    func importTracks(_ tracks: [GPXTrack]) async throws -> GPXImportResult {
        try Task.checkCancellation()
        do {
            let result = try await repository.importTracks(tracks)
            historyRevision += 1
            if case .loaded(let saved) = history { history = .loaded((saved + result.imported).sorted { $0.startedAt > $1.startedAt }) }
            else { await reloadHistory() }
            scheduleProcessing(result.imported.map(\.id))
            return result
        } catch {
            if let error = error as? ActivityError, case .storage = error { onStorageFailure?(error) }
            throw error
        }
    }

    func exportGPX(id: ActivityID) async throws -> GPXExportFile {
        guard try await repository.summary(id: id).status == .completed else { throw ActivityError.invalidTransition }
        return try await GPXFiles.write(repository.recordedTrack(id: id).gpx)
    }

    var canExportAllGPX: Bool {
        guard case .loaded(let saved) = history else { return false }
        return saved.contains { $0.pointCount > 0 }
    }

    func exportAllGPX() async throws -> GPXExportFile {
        let saved = try await repository.summaries().filter { $0.pointCount > 0 }
        return try await GPXFiles.writeAll(activityIDs: saved.map(\.id)) { [repository] id in
            try await repository.recordedTrack(id: id).gpx
        }
    }

    func delete(id: ActivityID) async throws {
        do { try await repository.delete(id: id) }
        catch {
            if let error = error as? ActivityError, case .storage = error { onStorageFailure?(error) }
            throw error
        }
        historyRevision += 1
        thumbnailTasks[id]?.cancel(); thumbnails.removeObject(forKey: id.rawValue as NSString)
        processingQueue.removeAll { $0 == id }; processingFailures[id] = nil
        if case .loaded(let saved) = history { history = .loaded(saved.filter { $0.id != id }) }
        await processor.cancel(id: id)
    }
}
