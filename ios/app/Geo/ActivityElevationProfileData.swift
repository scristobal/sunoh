/// Display samples preserve recorded elevations and source gaps while limiting the work needed to draw a full activity.
struct ActivityElevationProfileData: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        let elapsedSeconds: Double
        let elevationMeters: Double
    }

    let startedAt: Timestamp?
    let endedAt: Timestamp?
    let sections: [[Sample]]
    let durationSeconds: Double
    let minimumElevationMeters: Double?
    let maximumElevationMeters: Double?

    init(geometry: TrackGeometry, maximumSamples: Int = 1_200) {
        var firstTime: Timestamp?
        var lastTime: Timestamp?
        for section in geometry.sections {
            for point in section.points {
                firstTime = min(firstTime ?? point.recordedAt, point.recordedAt)
                lastTime = max(lastTime ?? point.recordedAt, point.recordedAt)
            }
        }
        startedAt = firstTime
        endedAt = lastTime
        guard let firstTime, let lastTime else {
            sections = []
            durationSeconds = 0
            minimumElevationMeters = nil
            maximumElevationMeters = nil
            return
        }
        durationSeconds = Double(lastTime.millisecondsSince1970 - firstTime.millisecondsSince1970) / 1_000
        var paths: [[Sample]] = []
        var minimum: Double?
        var maximum: Double?
        for section in geometry.sections {
            var path: [Sample] = []
            var previousTime: Timestamp?
            func finish() {
                if !path.isEmpty { paths.append(path) }
                path.removeAll(keepingCapacity: true)
            }
            for point in section.points {
                if let previousTime, point.recordedAt <= previousTime { finish() }
                previousTime = point.recordedAt
                guard let elevation = point.elevationMeters, elevation.isFinite else {
                    finish()
                    continue
                }
                minimum = min(minimum ?? elevation, elevation)
                maximum = max(maximum ?? elevation, elevation)
                path.append(Sample(elapsedSeconds: Double(point.timestampMilliseconds - firstTime.millisecondsSince1970) / 1_000,
                                   elevationMeters: elevation))
            }
            finish()
        }
        minimumElevationMeters = minimum
        maximumElevationMeters = maximum
        // Each section keeps its endpoints and extrema even when many source gaps require more than the requested budget.
        let required = paths.reduce(0) { $0 + min(4, $1.count) }
        let remainingCapacity = paths.reduce(0) { $0 + max(0, $1.count - 4) }
        let extraBudget = min(remainingCapacity, max(0, max(0, maximumSamples) - required))
        sections = paths.map { path in
            let extra = remainingCapacity > 0 ? Int(Double(extraBudget) * Double(max(0, path.count - 4)) / Double(remainingCapacity)) : 0
            return Self.reduced(path, maximumSamples: min(4, path.count) + extra)
        }
    }

    private static func reduced(_ samples: [Sample], maximumSamples: Int) -> [Sample] {
        guard samples.count > maximumSamples, samples.count > 4 else { return samples }
        let bucketCount = max(1, (maximumSamples - 2) / 2)
        let interiorCount = samples.count - 2
        var result = [samples[0]]
        for bucket in 0..<bucketCount {
            let start = 1 + bucket * interiorCount / bucketCount
            let end = 1 + (bucket + 1) * interiorCount / bucketCount
            var lowest = start, highest = start
            for index in start..<end {
                if samples[index].elevationMeters < samples[lowest].elevationMeters { lowest = index }
                if samples[index].elevationMeters > samples[highest].elevationMeters { highest = index }
            }
            result.append(samples[min(lowest, highest)])
            if lowest != highest { result.append(samples[max(lowest, highest)]) }
        }
        result.append(samples[samples.count - 1])
        return result
    }
}
