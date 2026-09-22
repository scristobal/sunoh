import SwiftUI
import UIKit
import UniformTypeIdentifiers
import LinkPresentation

struct GPXImportButton: View {
    let library: ActivityLibrary
    @State private var showPicker = false
    @State private var importing = false
    @State private var message: GPXMessage?

    var body: some View {
        Button { showPicker = true } label: {
            if importing {
                HStack { ProgressView(); Text("Importing…") }
            } else {
                Label("Import GPX", systemImage: "square.and.arrow.down")
            }
        }
        .disabled(importing)
        .accessibilityIdentifier("import-gpx")
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.gpx, .xml], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importing = true
                Task {
                    defer { importing = false }
                    do {
                        let result = try await library.importGPX(from: url)
                        message = GPXMessage(title: "Import Complete", text: result.message)
                    } catch is CancellationError {
                        // Dismissing the file picker does not change any recordings.
                    } catch {
                        message = GPXMessage(title: "Unable to Import GPX", text: error.localizedDescription)
                    }
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    message = GPXMessage(title: "Unable to Open File", text: error.localizedDescription)
                }
            }
        }
        .alert(item: $message) { message in
            Alert(title: Text(message.title), message: Text(message.text), dismissButton: .default(Text("OK")))
        }
    }
}

struct GPXExportButton: View {
    let activityID: ActivityID
    let library: ActivityLibrary
    @State private var preparing = false
    @State private var file: GPXExportFile?
    @State private var thumbnail: Data?
    @State private var showShare = false
    @State private var message: GPXMessage?

    var body: some View {
        Button { preparing = true } label: {
            if preparing { ProgressView().accessibilityLabel("Preparing GPX") }
            else { Label("Export GPX", systemImage: "square.and.arrow.up") }
        }
        .disabled(preparing)
        .accessibilityIdentifier("export-gpx")
        .task(id: preparing) {
            guard preparing else { return }
            defer { preparing = false }
            var exported: GPXExportFile?
            do {
                exported = try await library.exportGPX(id: activityID)
                try Task.checkCancellation()
                let preview = await library.thumbnail(id: activityID)
                try Task.checkCancellation()
                file = exported
                thumbnail = preview
                showShare = true
            } catch is CancellationError {
                exported?.removeTemporaryFile()
            } catch {
                exported?.removeTemporaryFile()
                message = GPXMessage(title: "Unable to Export GPX", text: error.localizedDescription)
            }
        }
        .sheet(isPresented: $showShare, onDismiss: {
            file?.removeTemporaryFile()
            file = nil
            thumbnail = nil
        }) {
            if let file { GPXShareSheet(url: file.url, thumbnail: thumbnail) }
        }
        .alert(item: $message) { message in
            Alert(title: Text(message.title), message: Text(message.text), dismissButton: .default(Text("OK")))
        }
    }
}

struct GPXExportAllButton: View {
    let library: ActivityLibrary
    @State private var preparing = false
    @State private var file: GPXExportFile?
    @State private var showShare = false
    @State private var message: GPXMessage?

    var body: some View {
        Button { preparing = true } label: {
            if preparing { HStack { ProgressView(); Text("Preparing export…") } }
            else { Label("Export All", systemImage: "square.and.arrow.up") }
        }
        .disabled(preparing || !library.canExportAllGPX)
        .accessibilityIdentifier("export-all-gpx")
        .task(id: preparing) {
            guard preparing else { return }
            defer { preparing = false }
            do {
                let exported = try await library.exportAllGPX()
                guard !Task.isCancelled else {
                    exported.removeTemporaryFile()
                    throw CancellationError()
                }
                file = exported
                showShare = true
            } catch is CancellationError {
                // Leaving Profile cancels preparation, not the recording.
            } catch {
                message = GPXMessage(title: "Unable to Export Activities", text: error.localizedDescription)
            }
        }
        .sheet(isPresented: $showShare, onDismiss: {
            file?.removeTemporaryFile()
            file = nil
        }) {
            if let file { GPXShareSheet(url: file.url, thumbnail: nil, kind: .allActivities) }
        }
        .alert(item: $message) { message in
            Alert(title: Text(message.title), message: Text(message.text), dismissButton: .default(Text("OK")))
        }
    }
}

private struct GPXMessage: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

private struct GPXShareSheet: UIViewControllerRepresentable {
    let url: URL
    let thumbnail: Data?
    var kind: GPXShareItem.Kind = .activity

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [GPXShareItem(url: url, thumbnail: thumbnail, kind: kind)], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The route image is metadata only. Every destination still receives one GPX URL.
/// UIKit also invokes these Objective-C callbacks from NSItemProvider workers.
/// Keep the source immutable and nonisolated: hopping synchronously to MainActor
/// would deadlock while the share sheet waits for its item on the main thread.
nonisolated final class GPXShareItem: NSObject, UIActivityItemSource, Sendable {
    enum Kind: Sendable { case activity, allActivities }
    let url: URL
    private let image: UIImage?
    private let title: String

    init(url: URL, thumbnail: Data?, kind: Kind = .activity) {
        self.url = url
        switch kind {
        case .activity:
            image = thumbnail.flatMap(UIImage.init(data:)) ?? UIImage(systemName: "map")
            title = "Sunō activity · GPX"
        case .allActivities:
            image = UIImage(systemName: "shippingbox", withConfiguration: UIImage.SymbolConfiguration(pointSize: 96))?
                .withTintColor(.black, renderingMode: .alwaysOriginal)
            title = "Sunō activities · GPX"
        }
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { url }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { url }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = title
        if let image {
            metadata.iconProvider = NSItemProvider(object: image)
            metadata.imageProvider = NSItemProvider(object: image)
        }
        return metadata
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                thumbnailImageForActivityType activityType: UIActivity.ActivityType?,
                                suggestedSize size: CGSize) -> UIImage? { image }
}
