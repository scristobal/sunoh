import Foundation

/// Classifies observations without changing them or reading storage. All thresholds use seconds and meters.
enum SkiActivityDetector {
    struct Passage: Codable, Equatable, Sendable {
        let startedAt: Timestamp
        let endedAt: Timestamp
    }

    struct Result: Codable, Equatable, Sendable {
        var runs: [Passage] = []
        var lifts: [Passage] = []
        var runCount: Int { runs.count }
        var liftCount: Int { lifts.count }
    }

    // Tuned against Slopes exports using only the observations retained in GPX.
    private static let sampleInterval = 10.0
    private static let maximumObservationGap = 60.0
    private static let minimumLiftDuration = 45.0
    private static let minimumLiftGain = 30.0
    private static let minimumLiftSpeed = Geo.minimumMovingSpeedMetersPerSecond
    private static let maximumLiftSpeed = 14.0
    private static let minimumClimbRate = 0.18
    private static let maximumLiftInterruption = 90.0
    private static let maximumLiftDescent = 15.0
    private static let maximumSpeedSpread = 1.0

    static func analyze(_ geometry: TrackGeometry, liftFeatures: [SkiFeature] = []) -> Result {
        var result = Result()
        var points: [TrackPoint] = []
        var sourceSegmentID: SegmentID?
        for section in geometry.sections {
            // Sampling gaps do not start another run. Explicit source boundaries do.
            if sourceSegmentID != section.sourceSegmentID || section.breakBefore == .sourceBoundary {
                appendPassages(points, liftFeatures: liftFeatures, to: &result)
                points.removeAll(keepingCapacity: true)
            }
            sourceSegmentID = section.sourceSegmentID
            for point in section.points {
                if points.last.map({ $0.recordedAt >= point.recordedAt }) == true {
                    appendPassages(points, liftFeatures: liftFeatures, to: &result)
                    points.removeAll(keepingCapacity: true)
                }
                points.append(point)
            }
        }
        appendPassages(points, liftFeatures: liftFeatures, to: &result)
        return result
    }

    private struct Sample {
        let time: Double
        let coordinate: Coordinate
        var elevation: Double
        let boundaryElevation: Double
        let hasLocation: Bool
        let observed: Bool
        var speed = 0.0
        var climbRate = 0.0
    }

    private static func appendPassages(_ points: [TrackPoint], liftFeatures: [SkiFeature], to result: inout Result) {
        guard points.count >= 2, let first = points.first, let last = points.last, first.recordedAt < last.recordedAt else { return }
        let stops = Geo.stationarySpans(in: points)
        let samples = resample(points, stops: stops)
        let detectedLifts = liftRanges(samples, stops: stops).map {
            passage(samples, from: $0.lowerBound, through: $0.upperBound)
        }
        let baseline = Geo.liftsWithInternalStops(detectedLifts, stops: stops)
        let extra = liftFeatures.isEmpty ? [] : LiftReferenceEvidence.passages(in: points, features: liftFeatures, baseline: baseline)
        let lifts = extra.isEmpty ? baseline : mergedLifts(baseline + extra)
        var runStart = first.recordedAt
        for lift in lifts {
            if runStart < lift.startedAt {
                result.runs.append(Passage(startedAt: runStart, endedAt: lift.startedAt))
            }
            result.lifts.append(lift)
            runStart = lift.endedAt
        }
        if runStart < last.recordedAt {
            result.runs.append(Passage(startedAt: runStart, endedAt: last.recordedAt))
        }
    }

    private static func mergedLifts(_ lifts: [Passage]) -> [Passage] {
        var result: [Passage] = []
        for lift in lifts.sorted(by: { $0.startedAt < $1.startedAt }) {
            if let previous = result.last, lift.startedAt < previous.endedAt {
                result[result.count - 1] = Passage(startedAt: previous.startedAt, endedAt: max(previous.endedAt, lift.endedAt))
            } else {
                result.append(lift)
            }
        }
        return result
    }

    private static func passage(_ samples: [Sample], from start: Int, through end: Int) -> Passage {
        Passage(startedAt: Timestamp(millisecondsSince1970: Int64((samples[start].time * 1_000).rounded())),
                endedAt: Timestamp(millisecondsSince1970: Int64((samples[end].time * 1_000).rounded())))
    }

    private static func resample(_ points: [TrackPoint], stops: [Geo.StationarySpan]) -> [Sample] {
        guard points.count >= 2, let first = points.first, let last = points.last else { return [] }
        var samples: [Sample] = []
        var right = 1
        var stopIndex = 0
        var time = Double(first.timestampMilliseconds) / 1_000
        let origin = time
        let end = Double(last.timestampMilliseconds) / 1_000
        while time <= end {
            while right < points.count - 1 && Double(points[right].timestampMilliseconds) / 1_000 < time { right += 1 }
            let a = points[right - 1], b = points[right]
            let aTime = Double(a.timestampMilliseconds) / 1_000
            let duration = Double(b.timestampMilliseconds - a.timestampMilliseconds) / 1_000
            guard duration > 0 else { return [] }
            let hasLocation = duration <= maximumObservationGap
            let observed = hasLocation && a.elevationMeters != nil && b.elevationMeters != nil
            while stopIndex < stops.count && stops[stopIndex].pointIndices.upperBound < right { stopIndex += 1 }
            let stationary = stopIndex < stops.count && stops[stopIndex].pointIndices.contains(right - 1)
            let stationaryElevation = stationary ? points[stops[stopIndex].pointIndices.lowerBound].elevationMeters : nil
            let aElevation = stationaryElevation ?? a.elevationMeters ?? 0
            let bElevation = stationaryElevation ?? b.elevationMeters ?? 0
            let fraction = min(1, max(0, (time - aTime) / duration))
            var longitudeDelta = b.longitude - a.longitude
            if longitudeDelta > 180 { longitudeDelta -= 360 }
            if longitudeDelta < -180 { longitudeDelta += 360 }
            var longitude = a.longitude + fraction * longitudeDelta
            if longitude > 180 { longitude -= 360 }
            if longitude < -180 { longitude += 360 }
            guard let coordinate = try? Coordinate(latitude: a.latitude + fraction * (b.latitude - a.latitude), longitude: longitude) else { return [] }
            let elevation = aElevation + fraction * (bElevation - aElevation)
            samples.append(Sample(time: time, coordinate: coordinate, elevation: elevation, boundaryElevation: elevation,
                                  hasLocation: hasLocation, observed: observed))
            // Keep a gap marker, but do not allocate samples for hours or days without observations.
            if duration > maximumObservationGap {
                let next = Double(b.timestampMilliseconds) / 1_000
                time = max(time + sampleInterval, origin + ceil((next - origin) / sampleInterval) * sampleInterval)
            } else {
                time += sampleInterval
            }
        }
        guard samples.count >= 3 else { return samples }
        let elevations = samples.map(\.elevation)
        for index in 1..<(samples.count - 1) where samples[(index - 1)...(index + 1)].allSatisfy(\.observed) {
            samples[index].elevation = [elevations[index - 1], elevations[index], elevations[index + 1]].sorted()[1]
        }
        for index in 1..<samples.count {
            if samples[index - 1].hasLocation && samples[index].hasLocation {
                samples[index].speed = Geo.distanceMeters(from: samples[index - 1].coordinate, to: samples[index].coordinate) / sampleInterval
            }
            if index < samples.count - 1 && samples[(index - 1)...(index + 1)].allSatisfy(\.observed) {
                samples[index].climbRate = (samples[index + 1].elevation - samples[index - 1].elevation) / (2 * sampleInterval)
            }
        }
        return samples
    }

    private static func liftRanges(_ samples: [Sample], stops: [Geo.StationarySpan]) -> [ClosedRange<Int>] {
        let seeds = samples.indices.filter { index in
            let sample = samples[index]
            return sample.observed && sample.climbRate >= minimumClimbRate && (minimumLiftSpeed...maximumLiftSpeed).contains(sample.speed)
        }
        guard let first = seeds.first else { return [] }
        var groups: [ClosedRange<Int>] = []
        var start = first, last = first
        for index in seeds.dropFirst() {
            let stoppedSeconds = stops.reduce(0.0) { total, stop in
                let lower = max(samples[last].time, Double(stop.startedAt.millisecondsSince1970) / 1_000)
                let upper = min(samples[index].time, Double(stop.endedAt.millisecondsSince1970) / 1_000)
                return total + max(0, upper - lower)
            }
            let interruption = samples[index].time - samples[last].time - stoppedSeconds
            let lowest = samples[last...index].filter(\.observed).map(\.elevation).min() ?? samples[last].elevation
            if interruption > maximumLiftInterruption || samples[last].elevation - lowest > maximumLiftDescent
                || !samples[last...index].allSatisfy(\.hasLocation) {
                groups.append(start...last)
                start = index
            }
            last = index
        }
        groups.append(start...last)
        return groups.compactMap { group in
            let lower = max(0, group.lowerBound - 1), upper = min(samples.count - 1, group.upperBound + 1)
            let movingAscent = ((lower + 1)...upper).filter { index in
                samples[index - 1].observed && samples[index].observed
                    && (minimumLiftSpeed...maximumLiftSpeed).contains(samples[index].speed)
                    && samples[index].boundaryElevation > samples[index - 1].boundaryElevation
            }
            guard let first = movingAscent.first, let last = movingAscent.last else { return nil }
            let start = first - 1, end = last
            guard samples[end].time - samples[start].time >= minimumLiftDuration,
                  samples[end].elevation - samples[start].elevation >= minimumLiftGain else { return nil }
            let movingSpeeds = samples[(start + 1)...end].map(\.speed).filter { $0 >= minimumLiftSpeed }.sorted()
            guard movingSpeeds.count >= 4 else { return nil }
            let median = percentile(movingSpeeds, 0.5)
            let spread = (percentile(movingSpeeds, 0.9) - percentile(movingSpeeds, 0.1)) / median
            guard median <= maximumLiftSpeed, spread <= maximumSpeedSpread else { return nil }
            return start...end
        }
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        let index = Double(sorted.count - 1) * fraction
        let lower = Int(index), upper = min(sorted.count - 1, Int(index) + 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (index - Double(lower))
    }

}
