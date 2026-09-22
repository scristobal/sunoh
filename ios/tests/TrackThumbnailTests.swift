import Foundation
import Testing
import UIKit
@testable import Sunoh

struct TrackThumbnailTests {
    private let bounds = CGRect(x: 64, y: 64, width: 384, height: 384)

    @Test(arguments: [GPXShareItem.Kind.activity, .allActivities]) @MainActor
    func shareItemSupportsObjectiveCRequestsFromABackgroundQueue(kind: GPXShareItem.Kind) async {
        let url = URL(fileURLWithPath: "/example/activity.gpx")
        let item = GPXShareItem(url: url, thumbnail: nil, kind: kind)
        let controller = UIActivityViewController(activityItems: ["Background callback test"], applicationActivities: nil)
        // iOS calls the Objective-C entry point from an NSItemProvider worker,
        // not necessarily from the main actor. Calling it only on MainActor
        // would miss the executor assertion that used to crash Export GPX.
        let received: URL? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                #expect(!Thread.isMainThread)
                let result = item.perform(NSSelectorFromString("activityViewController:itemForActivityType:"),
                                          with: controller, with: nil)
                continuation.resume(returning: result?.takeUnretainedValue() as? URL)
            }
        }
        #expect(received == url)
    }

    @Test(arguments: [GPXShareItem.Kind.activity, .allActivities]) @MainActor
    func actualShareSheetLoadsTheGPXItemAndRoutePreview(kind: GPXShareItem.Kind) async throws {
        let file = try await GPXFiles.write(GPXTrack(segments: syntheticRoute))
        let item = GPXShareItem(url: file.url, thumbnail: TrackThumbnail.png(geometry: fixtureGeometry(syntheticRoute)), kind: kind)
        let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        // Exercise UIKit's real extension discovery, including background item
        // requests, rather than just invoking our callbacks on the main actor.
        controller.loadViewIfNeeded()
        #expect(controller.isViewLoaded)
        #expect(FileManager.default.fileExists(atPath: file.url.path))
        // Keep this tiny synthetic export until test-host teardown: UIKit can
        // continue reading the file asynchronously after view loading finishes.
    }

    @Test @MainActor func fullHistoryPreviewUsesTheBundledPackageSymbol() throws {
        #expect(UIImage(systemName: "shippingbox") != nil)
        let url = URL(fileURLWithPath: "/example/Sunoh-activities.gpx")
        let item = GPXShareItem(url: url, thumbnail: nil, kind: .allActivities)
        let controller = UIActivityViewController(activityItems: ["Package preview test"], applicationActivities: nil)
        let metadata = try #require(item.activityViewControllerLinkMetadata(controller))
        #expect(metadata.title == "Sunō activities · GPX")
        #expect(metadata.url == url)
        #expect(metadata.iconProvider?.canLoadObject(ofClass: UIImage.self) == true)
        let preview = try #require(item.activityViewController(controller, thumbnailImageForActivityType: nil,
                                                               suggestedSize: CGSize(width: 96, height: 96)))
        #expect(preview.size.width > 0 && preview.size.height > 0)
        Attachment.record(try #require(preview.pngData()), named: "package-preview.png")
        #expect(item.activityViewController(controller, itemForActivityType: nil) as? URL == url)
    }

    @Test func keepsSegmentAndTimeGapsDisconnectedAndFitsNorthUp() {
        let paths = TrackThumbnail.paths(geometry: fixtureGeometry([
            GPXSegment(points: [point(0, 47, 11), point(10_000, 47.01, 11.01), point(60_000, 47.02, 11.02)]),
            GPXSegment(points: [point(70_000, 47.03, 11.03)])
        ]), in: bounds)
        #expect(paths.map(\.count) == [2, 1, 1])
        #expect(paths[0][0].y > paths[0][1].y)
        for point in paths.flatMap({ $0 }) {
            #expect(point.x >= bounds.minX && point.x <= bounds.maxX)
            #expect(point.y >= bounds.minY && point.y <= bounds.maxY)
        }
    }

    @Test func crossesAntimeridianLocallyWithoutFlatteningTheRoute() {
        let paths = TrackThumbnail.paths(geometry: fixtureGeometry([GPXSegment(points: [
            point(0, 0, 179.99), point(1_000, 0.01, -179.99)
        ])]), in: bounds)
        #expect(paths[0][1].x > paths[0][0].x)
        #expect(abs(paths[0][1].y - paths[0][0].y) > 100)
    }

    @Test func centersStationaryPointsAndHandlesPolarCoordinates() {
        for latitude in [0.0, 90, -90] {
            let segments = [GPXSegment(points: [point(0, latitude, 11), point(1_000, latitude, 11)])]
            let paths = TrackThumbnail.paths(geometry: fixtureGeometry(segments), in: bounds)
            #expect(paths[0] == [CGPoint(x: 256, y: 256), CGPoint(x: 256, y: 256)])
            #expect(TrackThumbnail.png(geometry: fixtureGeometry(segments)) != nil)
        }
        #expect(TrackThumbnail.png(geometry: fixtureGeometry([])) == nil)
    }

    @Test func cancellationSkipsPreviewWork() async {
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(TrackThumbnail.png(geometry: fixtureGeometry([GPXSegment(points: [point(0, 47, 11)])])) == nil)
        }.value
    }

    @Test @MainActor func previewIsAnImageButAllShareDestinationsStillReceiveOnlyGPX() async throws {
        let segments = syntheticRoute
        let data = try #require(TrackThumbnail.png(geometry: fixtureGeometry(segments)))
        let image = try #require(UIImage(data: data))
        #expect(image.size == CGSize(width: 512, height: 512))
        let pixels = try #require(CGContext(data: nil, width: 512, height: 512,
            bitsPerComponent: 8, bytesPerRow: 512 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        pixels.draw(try #require(image.cgImage), in: CGRect(x: 0, y: 0, width: 512, height: 512))
        let bytes = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
        var visiblePixels = 0
        for offset in stride(from: 0, to: 512 * 512 * 4, by: 4) {
            #expect(bytes[offset] == 0 && bytes[offset + 1] == 0 && bytes[offset + 2] == 0)
            if bytes[offset + 3] > 0 { visiblePixels += 1 }
        }
        #expect(bytes[3] == 0) // The corner/background is transparent.
        #expect(visiblePixels > 0 && visiblePixels < 512 * 512 / 4)
        Attachment.record(data, named: "route-thumbnail.png")

        let track = GPXTrack(segments: segments)
        let file = try await GPXFiles.write(track)
        defer { file.removeTemporaryFile() }
        let original = try Data(contentsOf: file.url)
        let item = GPXShareItem(url: file.url, thumbnail: data)
        // Exercise the item-source contract without starting UIKit's asynchronous
        // file inspection, which can outlive this test's temporary export.
        let controller = UIActivityViewController(activityItems: ["Preview metadata test"], applicationActivities: nil)
        #expect(item.activityViewControllerPlaceholderItem(controller) as? URL == file.url)
        for type: UIActivity.ActivityType? in [nil, .airDrop, .mail, .copyToPasteboard, .init(rawValue: "example.gpx-importer")] {
            #expect(item.activityViewController(controller, itemForActivityType: type) as? URL == file.url)
        }
        let metadata = try #require(item.activityViewControllerLinkMetadata(controller))
        #expect(metadata.url == file.url)
        #expect(metadata.title == "Sunō activity · GPX")
        #expect(metadata.iconProvider?.canLoadObject(ofClass: UIImage.self) == true)
        #expect(metadata.imageProvider?.canLoadObject(ofClass: UIImage.self) == true)
        #expect(try Data(contentsOf: file.url) == original)
        #expect(try GPX.decode(original) == [track])
    }

    @Test @MainActor func missingPreviewUsesAnIconWithoutChangingTheSharedItem() {
        let url = URL(fileURLWithPath: "/example/activity.gpx")
        let item = GPXShareItem(url: url, thumbnail: nil)
        let controller = UIActivityViewController(activityItems: ["Preview metadata test"], applicationActivities: nil)
        #expect(item.activityViewControllerLinkMetadata(controller)?.iconProvider != nil)
        #expect(item.activityViewController(controller, itemForActivityType: nil) as? URL == url)
    }

    private var syntheticRoute: [GPXSegment] {
        [GPXSegment(points: [point(0, 47.01, 11.001), point(1_000, 47.009, 11.004),
                        point(2_000, 47.008, 11.002), point(3_000, 47.007, 11.005),
                        point(4_000, 47.006, 11.003), point(5_000, 47.005, 11.006)]),
         GPXSegment(points: [point(60_000, 47.003, 11.006), point(61_000, 47.002, 11.004),
                        point(62_000, 47.001, 11.007)])]
    }

    private func point(_ time: Int64, _ latitude: Double, _ longitude: Double) -> TrackPoint {
        try! TrackPoint(timestampMilliseconds: time, latitude: latitude, longitude: longitude, elevationMeters: nil)
    }
}
