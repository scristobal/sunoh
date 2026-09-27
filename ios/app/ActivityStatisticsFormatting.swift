import Foundation

// The view formats measurements calculated by the activity processor.
extension ActivityStatistics {
    var formattedDuration: String {
        Self.duration(elapsedDurationMilliseconds)
    }

    var formattedRunDuration: String { Self.duration(runDurationMilliseconds) }
    var formattedRunDistance: String { Self.distance(runDistanceMeters) }
    var formattedLongestRunDistance: String { longestRunDistanceMeters.map(Self.distance) ?? "—" }
    var formattedMaximumRunSpeed: String { Self.speed(maximumRunSpeedMetersPerSecond) }
    var formattedAverageRunSteepness: String { Self.steepness(averageRunSteepnessPercent) }
    var formattedMaximumRunSteepness: String { Self.steepness(maximumRunSteepnessPercent) }

    private static func duration(_ milliseconds: Int64) -> String {
        let totalMinutes = milliseconds / 60_000
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var formattedDistance: String {
        Self.distance(distanceMeters)
    }

    var formattedAverageRunSpeed: String {
        Self.speed(averageDownhillSpeedMetersPerSecond)
    }

    static func distance(_ meters: Double) -> String {
        if meters >= 1_000 {
            return "\((meters / 1_000).formatted(.number.precision(.fractionLength(1)))) km"
        }
        return "\(meters.formatted(.number.precision(.fractionLength(0)))) m"
    }

    private static func speed(_ metersPerSecond: Double?) -> String {
        guard let speed = metersPerSecond else { return "—" }
        return "\((speed * 3.6).formatted(.number.precision(.fractionLength(1)))) km/h"
    }

    private static func steepness(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        return (percent / 100).formatted(.percent.precision(.fractionLength(1)))
    }
}
