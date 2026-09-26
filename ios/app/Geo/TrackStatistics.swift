import Foundation

extension Geo {
    static func statistics(activity: ActivitySummary, geometry: TrackGeometry) -> ActivityStatistics {
        var statistics = ActivityStatistics()
        statistics.elapsedDurationMilliseconds = max(0, (activity.lastPointAt ?? activity.startedAt).millisecondsSince1970 - activity.startedAt.millisecondsSince1970)
        for section in geometry.sections {
            for elevation in section.points.compactMap(\.elevationMeters) {
                statistics.maximumElevationMeters = max(statistics.maximumElevationMeters ?? elevation, elevation)
                statistics.minimumElevationMeters = min(statistics.minimumElevationMeters ?? elevation, elevation)
            }
            for (a, b) in zip(section.points, section.points.dropFirst()) {
                statistics.distanceMeters += distanceMeters(from: a.coordinate, to: b.coordinate)
                if let previous = a.elevationMeters, let current = b.elevationMeters {
                    let delta = current - previous
                    if delta.isFinite {
                        statistics.elevationGainMeters += max(0, delta)
                        statistics.elevationLossMeters += max(0, -delta)
                    }
                }
            }
        }
        return statistics
    }
}

extension ActivityStatistics {
    init(activity: ActivitySummary, geometry: TrackGeometry) {
        self = Geo.statistics(activity: activity, geometry: geometry)
    }
}
