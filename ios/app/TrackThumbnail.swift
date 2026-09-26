import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A presentation-only route drawing, shared by activity rows and file previews.
/// No map tiles, statistics, or changes to the stored/exported observations.
enum TrackThumbnail {
    static let pixelSize = 512

    static func png(geometry: TrackGeometry) -> Data? {
        let size = CGFloat(pixelSize)
        let paths = paths(geometry: geometry, in: CGRect(x: 64, y: 64, width: size - 128, height: size - 128))
        guard !paths.isEmpty, !Task.isCancelled,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelSize, height: pixelSize,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        context.translateBy(x: 0, y: size)
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let routeColor = CGColor(gray: 0, alpha: 1)
        for points in paths {
            guard !Task.isCancelled else { return nil }
            let path = CGMutablePath()
            path.addLines(between: points)
            context.addPath(path)
            context.setStrokeColor(routeColor)
            context.setLineWidth(13)
            context.strokePath()
            // A one-point segment (or a stationary recording) still has a visible mark.
            if let point = points.first, points.allSatisfy({ $0 == point }) {
                context.setFillColor(routeColor)
                context.fillEllipse(in: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
            }
        }
        for point in [paths.first?.first, paths.last?.last].compactMap({ $0 }) {
            context.setFillColor(routeColor)
            context.fillEllipse(in: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18))
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Fits a north-up Mercator drawing without stretching, joining source segments, or wrapping a short antimeridian crossing around the world. This is only display geometry.
    static func paths(geometry: TrackGeometry, in bounds: CGRect) -> [[CGPoint]] {
        guard bounds.width > 0, bounds.height > 0,
              let origin = geometry.sections.lazy.flatMap(\.points).first else { return [] }
        var projected: [[CGPoint]] = []
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for section in geometry.sections {
            var path: [CGPoint] = []
            for point in section.points {
                guard !Task.isCancelled else { return [] }
                let projectedPoint = Geo.mercatorProjection(of: point.coordinate, relativeTo: origin.coordinate)
                let x = projectedPoint.x, y = projectedPoint.y
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                path.append(CGPoint(x: x, y: y))
            }
            if !path.isEmpty { projected.append(path) }
        }
        guard !projected.isEmpty else { return [] }
        let width = maxX - minX, height = maxY - minY
        let scale = min(width > 0 ? bounds.width / width : .infinity,
                        height > 0 ? bounds.height / height : .infinity)
        let fittingScale = scale.isFinite ? scale : 1
        return projected.map { path in
            path.map { point in
                CGPoint(x: min(bounds.maxX, max(bounds.minX, bounds.midX + (point.x - (minX + maxX) / 2) * fittingScale)),
                        y: min(bounds.maxY, max(bounds.minY, bounds.midY + (point.y - (minY + maxY) / 2) * fittingScale)))
            }
        }
    }
}
