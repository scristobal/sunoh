import Foundation

enum Geo {
    struct ProjectedPoint: Equatable, Sendable {
        let x: Double
        let y: Double
    }

    /// Great-circle distance on a sphere with the mean Earth radius, excluding elevation.
    static func distanceMeters(from start: Coordinate, to end: Coordinate) -> Double {
        let latitudeDelta = (end.latitude - start.latitude) * .pi / 180
        let longitudeDelta = (end.longitude - start.longitude) * .pi / 180
        let h = min(1, max(0, pow(sin(latitudeDelta / 2), 2)
            + cos(start.latitude * .pi / 180) * cos(end.latitude * .pi / 180) * pow(sin(longitudeDelta / 2), 2)))
        return 6_371_000 * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    /// North-up display projection with local longitude wrapping around the supplied origin.
    static func mercatorProjection(of coordinate: Coordinate, relativeTo origin: Coordinate) -> ProjectedPoint {
        var x = coordinate.longitude - origin.longitude
        if x > 180 { x -= 360 }
        if x < -180 { x += 360 }
        let latitude = min(85.05112878, max(-85.05112878, coordinate.latitude)) * .pi / 180
        let y = -asinh(tan(latitude)) * 180 / .pi
        return ProjectedPoint(x: x, y: y)
    }
}
