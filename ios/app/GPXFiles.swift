import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
}

struct GPXImportResult: Sendable {
    let imported: [ActivitySummary]
    let skipped: Int

    var message: String {
        let added = imported.count == 1 ? "Imported 1 activity." : "Imported \(imported.count) activities."
        guard skipped > 0 else { return added }
        let existing = skipped == 1 ? "1 identical activity was already saved." : "\(skipped) identical activities were already saved."
        return "\(added) \(existing)"
    }
}

struct GPXExportFile: Sendable {
    let url: URL

    func removeTemporaryFile() {
        // Each export owns this one temporary directory, created by write below.
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

enum GPXFiles {
    static func writeAll(activityIDs: [ActivityID], temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                         loadTrack: @escaping @Sendable (ActivityID) async throws -> GPXTrack) async throws -> GPXExportFile {
        try Task.checkCancellation()
        guard !activityIDs.isEmpty else {
            throw GPXError.invalid("There are no saved activities with recorded points to export.")
        }
        let task = Task.detached(priority: .userInitiated) {
            let directory = temporaryDirectory.appendingPathComponent("Sunoh-GPX-\(UUID().uuidString)")
            let url = directory.appendingPathComponent("Sunoh-activities.gpx")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.write(contentsOf: GPX.documentStart)
                for id in activityIDs {
                    try Task.checkCancellation()
                    let track = try await loadTrack(id)
                    try handle.write(contentsOf: GPX.encodeTrack(track))
                }
                try Task.checkCancellation()
                try handle.write(contentsOf: GPX.documentEnd)
                try handle.close()
                try Task.checkCancellation()
                return GPXExportFile(url: url)
            } catch {
                // Never offer a partial export, including when a selected activity
                // was deleted while the file was being prepared.
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    static func read(_ url: URL) async throws -> [GPXTrack] {
        let task = Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var result: Result<[GPXTrack], Error>?
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                result = Result {
                    let handle = try FileHandle(forReadingFrom: readable)
                    defer { try? handle.close() }
                    // Bound reads even when a provider does not report a file size.
                    let data = try handle.read(upToCount: GPX.maximumBytes + 1) ?? Data()
                    return try GPX.decode(data)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw GPXError.invalid("The selected file could not be read.") }
            return try result.get()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    static func write(_ track: GPXTrack) async throws -> GPXExportFile {
        let task = Task.detached(priority: .userInitiated) {
            let data = try GPX.encode(track)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sunoh-GPX-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Sunoh-activity.gpx")
            do {
                try data.write(to: url, options: .atomic)
                return GPXExportFile(url: url)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
}
