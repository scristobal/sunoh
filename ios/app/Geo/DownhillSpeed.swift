import Foundation

extension Geo {
    /// Total observed moving distance divided by moving time within the detector's ordered, disjoint runs.
    static func averageDownhillSpeedMetersPerSecond(in geometry: TrackGeometry, runs: [SkiActivityDetector.Passage]) -> Double? {
        skiStatistics(in: geometry, passages: SkiActivityDetector.Result(runs: runs)).averageDownhillSpeedMetersPerSecond
    }
}
