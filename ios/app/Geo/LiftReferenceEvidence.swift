import Foundation

/// Reference geometry can add evidence for a lift ride; it cannot remove a lift detected from the recording alone.
enum LiftReferenceEvidence {
    static let minimumMovingSeconds = 60.0
    static let minimumMovingDistanceMeters = 150.0
    static let minimumMovingIntervals = 6
    static let minimumSpeedMetersPerSecond = 2.0
    static let maximumSpeedMetersPerSecond = 14.0
    static let maximumSpeedSpread = 0.6
    static let minimumReferenceFraction = 0.6
    static let minimumMatchingConfidence = 0.75
    static let maximumUnsupportedSeconds = 15.0
    static let maximumTotalUnsupportedSeconds = 20.0
    static let minimumSupportedFraction = 0.85
    static let maximumDipSeconds = 45.0
    static let maximumDipMeters = 25.0
    static let elevationNoiseMeters = 5.0

    static func passages(in points: [TrackPoint], features: [SkiFeature], baseline: [SkiActivityDetector.Passage]) -> [SkiActivityDetector.Passage] {
        let lifts = features.filter { $0.identity.kind == .lift }
        guard !lifts.isEmpty, let first = points.first, let last = points.last, first.recordedAt < last.recordedAt else { return [] }
        let geometry = TrackGeometry(activityID: "lift-evidence", sourceRevision: 0,
                                     sections: [TrackSection(sourceSegmentID: "lift-evidence", breakBefore: nil, points: points)])
        let timeline = ActivityTimeline(entries: [ActivityTimelineEntry(kind: .lift, startedAt: first.recordedAt, endedAt: last.recordedAt,
                                                                        distanceMeters: nil, elevationGainMeters: nil, elevationLossMeters: nil)])
        let matches = SkiFeatureMatcher.match(geometry: geometry, timeline: timeline, features: lifts, datasetVersion: "lift-evidence").entries[0]
        guard !matches.isEmpty else { return [] }
        let references = Dictionary(lifts.map { ($0.identity.id, Reference(coordinates: $0.coordinates)) }, uniquingKeysWith: { first, _ in first })
        let stops = Geo.stationarySpans(in: points)
        var offsetCache: [String: [Coordinate: Double]] = [:]
        var matchIndex = 0, stopIndex = 0
        var groups: [[Interval]] = []
        var current: [Interval] = []
        var pending: [Interval] = []
        var directions: [String: Double] = [:]
        var unsupportedSeconds = 0.0

        func finish() {
            if !current.isEmpty { groups.append(current) }
            current.removeAll(keepingCapacity: true)
            pending.removeAll(keepingCapacity: true)
            directions.removeAll(keepingCapacity: true)
            unsupportedSeconds = 0
        }
        func offset(_ coordinate: Coordinate, feature: String) -> Double {
            if let cached = offsetCache[feature]?[coordinate] { return cached }
            let value = references[feature]?.offset(of: coordinate) ?? 0
            offsetCache[feature, default: [:]][coordinate] = value
            return value
        }

        for (index, (start, end)) in zip(points, points.dropFirst()).enumerated() {
            let seconds = Double(end.timestampMilliseconds - start.timestampMilliseconds) / 1_000
            guard seconds > 0, seconds <= Double(SkiFeatureMatcher.maximumObservationIntervalMilliseconds) / 1_000 else {
                finish()
                continue
            }
            while matchIndex < matches.count && matches[matchIndex].endedAt <= start.recordedAt { matchIndex += 1 }
            let match = matchIndex < matches.count && matches[matchIndex].startedAt <= start.recordedAt && matches[matchIndex].endedAt >= end.recordedAt ? matches[matchIndex] : nil
            while stopIndex < stops.count && stops[stopIndex].pointIndices.upperBound <= index { stopIndex += 1 }
            let stopped = stopIndex < stops.count && stops[stopIndex].pointIndices.contains(index)
            let distance = Geo.distanceMeters(from: start.coordinate, to: end.coordinate)
            let speed = distance / seconds
            guard speed <= maximumSpeedMetersPerSecond else { finish(); continue }
            let moving = (minimumSpeedMetersPerSecond...maximumSpeedMetersPerSecond).contains(speed)
            let feature = match?.feature.id
            let isSupported = (match?.confidence ?? 0) >= minimumMatchingConfidence && (moving || stopped)
            let lower = feature.map { offset(start.coordinate, feature: $0) }
            let upper = feature.map { offset(end.coordinate, feature: $0) }
            let interval = Interval(start: start, end: end, seconds: seconds, distance: stopped ? 0 : distance,
                                    speed: speed, moving: moving && !stopped, feature: isSupported ? feature : nil, lowerOffset: lower, upperOffset: upper)
            guard isSupported else {
                // Observed travel along a matched line at walking or ski speed is not a missing-geometry bridge.
                if match != nil && !moving && !stopped { finish(); continue }
                if !current.isEmpty {
                    pending.append(interval)
                    if pending.reduce(0, { $0 + $1.seconds }) > maximumUnsupportedSeconds { finish() }
                }
                continue
            }
            if interval.moving, let feature, let lower, let upper {
                let delta = upper - lower
                guard abs(delta) >= distance * 0.6 else { finish(); continue }
                if let previous = directions[feature], previous * delta < 0 { finish() }
                if let previous = current.last(where: { $0.feature != nil && $0.moving }), previous.feature != feature,
                   !connected(previous, interval, references: references) { finish() }
            }
            if !pending.isEmpty {
                let seconds = pending.reduce(0) { $0 + $1.seconds }
                let gapStart = pending[0].start
                let gapEnd = pending[pending.count - 1].end
                let speed = Geo.distanceMeters(from: gapStart.coordinate, to: gapEnd.coordinate) / seconds
                let previousFeature = current.last(where: { $0.feature != nil })?.feature
                let progress = feature.map { offset(gapEnd.coordinate, feature: $0) - offset(gapStart.coordinate, feature: $0) } ?? 0
                let direction = feature.flatMap { directions[$0] } ?? 0
                if previousFeature == feature, progress * direction > 0,
                   unsupportedSeconds + seconds <= maximumTotalUnsupportedSeconds,
                   (minimumSpeedMetersPerSecond...maximumSpeedMetersPerSecond).contains(speed) {
                    current.append(contentsOf: pending)
                    unsupportedSeconds += seconds
                    pending.removeAll(keepingCapacity: true)
                } else {
                    finish()
                }
            }
            if interval.moving, let feature, let lower, let upper { directions[feature] = upper - lower }
            current.append(interval)
        }
        finish()
        return groups.compactMap { accepted($0, references: references, baseline: baseline) }
    }

    private struct Interval {
        let start: TrackPoint
        let end: TrackPoint
        let seconds: Double
        let distance: Double
        let speed: Double
        let moving: Bool
        let feature: String?
        let lowerOffset: Double?
        let upperOffset: Double?
    }

    private static func accepted(_ intervals: [Interval], references: [String: Reference], baseline: [SkiActivityDetector.Passage]) -> SkiActivityDetector.Passage? {
        guard let first = intervals.firstIndex(where: { $0.feature != nil && $0.moving }),
              let last = intervals.lastIndex(where: { $0.feature != nil && $0.moving }) else { return nil }
        let ride = intervals[first...last]
        let moving = ride.filter { $0.feature != nil && $0.moving }
        let movingSeconds = moving.reduce(0) { $0 + $1.seconds }
        let supportedDistance = moving.reduce(0) { $0 + $1.distance }
        let unsupportedSeconds = ride.filter { $0.feature == nil }.reduce(0) { $0 + $1.seconds }
        guard moving.count >= minimumMovingIntervals, movingSeconds >= minimumMovingSeconds, supportedDistance >= minimumMovingDistanceMeters,
              movingSeconds / (movingSeconds + unsupportedSeconds) >= minimumSupportedFraction else { return nil }
        let speeds = moving.map(\.speed).sorted()
        let median = percentile(speeds, 0.5)
        guard (percentile(speeds, 0.9) - percentile(speeds, 0.1)) / median <= maximumSpeedSpread else { return nil }
        let start = intervals[first].start.recordedAt, end = intervals[last].end.recordedAt
        let baselineSeconds = baseline.reduce(0.0) { total, passage in
            total + max(0, Double(min(end, passage.endedAt).millisecondsSince1970 - max(start, passage.startedAt).millisecondsSince1970) / 1_000)
        }
        let elevations = smoothedElevation([intervals[first].start] + ride.map(\.end))
        let anchored = baselineSeconds >= 30
        guard acceptableElevation(elevations, anchored: anchored) else { return nil }
        if !anchored {
            var extents: [String: ClosedRange<Double>] = [:]
            for interval in moving {
                guard let feature = interval.feature, let a = interval.lowerOffset, let b = interval.upperOffset else { continue }
                let previous = extents[feature]
                extents[feature] = min(previous?.lowerBound ?? a, a, b)...max(previous?.upperBound ?? a, a, b)
            }
            let traversed = extents.values.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
            let referenceLength = extents.keys.reduce(0) { $0 + (references[$1]?.length ?? 0) }
            guard referenceLength > 0, traversed / referenceLength >= minimumReferenceFraction else { return nil }
        }
        return SkiActivityDetector.Passage(startedAt: start, endedAt: end)
    }

    private static func connected(_ previous: Interval, _ next: Interval, references: [String: Reference]) -> Bool {
        guard let previousID = previous.feature, let nextID = next.feature,
              let previousOffset = previous.upperOffset, let nextOffset = next.lowerOffset,
              let previousLength = references[previousID]?.length, let nextLength = references[nextID]?.length,
              min(previousOffset, previousLength - previousOffset) <= 30,
              min(nextOffset, nextLength - nextOffset) <= 30 else { return false }
        let previousVector = displacement(from: previous.start.coordinate, to: previous.end.coordinate)
        let nextVector = displacement(from: next.start.coordinate, to: next.end.coordinate)
        let denominator = hypot(previousVector.x, previousVector.y) * hypot(nextVector.x, nextVector.y)
        return denominator > 0 && (previousVector.x * nextVector.x + previousVector.y * nextVector.y) / denominator >= 0.5
    }

    private struct Elevation {
        let time: Timestamp
        let value: Double
    }

    private static func smoothedElevation(_ points: [TrackPoint]) -> [Elevation] {
        let known = points.compactMap { point in point.elevationMeters.map { Elevation(time: point.recordedAt, value: $0) } }
        guard known.count >= 3 else { return known }
        let medians = known.indices.map { index in
            let lower = min(max(0, index - 1), known.count - 3)
            let neighbors = known[lower...(lower + 2)]
            guard known[lower + 2].time.millisecondsSince1970 - known[lower].time.millisecondsSince1970 <= 60_000 else { return known[index] }
            return Elevation(time: known[index].time, value: neighbors.map(\.value).sorted()[1])
        }
        return medians.indices.map { index in
            let lower = max(0, index - 1), upper = min(medians.count - 1, index + 1)
            guard medians[upper].time.millisecondsSince1970 - medians[lower].time.millisecondsSince1970 <= 60_000 else { return medians[index] }
            let neighbors = medians[lower...upper]
            let mean = neighbors.reduce(0) { $0 + $1.value / Double(neighbors.count) }
            return Elevation(time: medians[index].time, value: mean)
        }
    }

    private static func acceptableElevation(_ points: [Elevation], anchored: Bool) -> Bool {
        guard let first = points.first else { return true }
        var peak = first.value
        var peakTime = first.time
        var dipping = false
        for point in points.dropFirst() {
            let elevation = point.value
            if elevation >= peak - elevationNoiseMeters {
                peak = max(peak, elevation)
                peakTime = point.time
                dipping = false
            } else {
                dipping = true
                let seconds = Double(point.time.millisecondsSince1970 - peakTime.millisecondsSince1970) / 1_000
                guard anchored, peak - elevation <= maximumDipMeters, seconds <= maximumDipSeconds else { return false }
            }
        }
        return !dipping
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        let index = Double(sorted.count - 1) * fraction
        let lower = Int(index), upper = min(sorted.count - 1, lower + 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (index - Double(lower))
    }

    private static func displacement(from start: Coordinate, to end: Coordinate) -> (x: Double, y: Double) {
        var longitude = end.longitude - start.longitude
        if longitude > 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }
        let meters = 6_371_000 * Double.pi / 180
        return (longitude * cos(start.latitude * .pi / 180) * meters, (end.latitude - start.latitude) * meters)
    }

    private struct Reference {
        struct Edge {
            let start: Coordinate
            let end: Coordinate
            let offset: Double
            let length: Double
        }
        let edges: [Edge]
        let length: Double

        init(coordinates: [Coordinate]) {
            var edges: [Edge] = []
            var length = 0.0
            for (start, end) in zip(coordinates, coordinates.dropFirst()) {
                let meters = Geo.distanceMeters(from: start, to: end)
                if meters > 0 { edges.append(Edge(start: start, end: end, offset: length, length: meters)) }
                length += meters
            }
            self.edges = edges
            self.length = length
        }

        func offset(of coordinate: Coordinate) -> Double {
            var nearest = Double.infinity, result = 0.0
            for edge in edges {
                let a = displacement(from: coordinate, to: edge.start), b = displacement(from: coordinate, to: edge.end)
                let dx = b.x - a.x, dy = b.y - a.y
                let squaredLength = dx * dx + dy * dy
                let fraction = squaredLength > 0 ? min(1, max(0, -(a.x * dx + a.y * dy) / squaredLength)) : 0
                let distance = pow(a.x + fraction * dx, 2) + pow(a.y + fraction * dy, 2)
                if distance < nearest { nearest = distance; result = edge.offset + fraction * edge.length }
            }
            return result
        }

    }
}
