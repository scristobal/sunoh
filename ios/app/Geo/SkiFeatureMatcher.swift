import Foundation

/// Identifies lifts without changing recorded run/lift classification or geometry.
enum SkiFeatureMatcher {
    // Matching evidence thresholds are independent of timeline sampling-quality ratings.
    static let maximumDistanceMeters = 25.0
    static let maximumAcceptedScoreMeters = 15.0
    static let ambiguityMarginMeters = 6.0
    static let maximumObservationIntervalMilliseconds: Int64 = 30_000
    static let maximumObservedSpeedMetersPerSecond = 45.0
    static let minimumMovementMeters = 1.0
    static let minimumMatchedDistanceMeters = 20.0
    static let minimumMovingIntervals = 2
    static let minimumDirectionCosine = 0.65
    static let minimumProgressRatio = 0.6
    static let maximumProgressRatio = 1.8
    static let maximumTransitionDistanceMeters = 20.0

    static func match(geometry: TrackGeometry, timeline: ActivityTimeline, features: [SkiFeature], datasetVersion: String) -> SkiTimelineMatches {
        let index = SegmentIndex(features: features)
        var matches = Array(repeating: [SkiFeatureMatch](), count: timeline.entries.count)
        var coveredThrough: Timestamp?
        // A span can never cross a source boundary, even if a caller supplies one timeline entry across it.
        for section in geometry.sections {
            if let first = section.points.first { coveredThrough = max(coveredThrough ?? first.recordedAt, first.recordedAt) }
            var builders: [Int: SpanBuilder] = [:]
            for (start, end) in zip(section.points, section.points.dropFirst()) {
                guard end.recordedAt > start.recordedAt else {
                    for entryIndex in builders.keys { builders[entryIndex]?.finish(into: &matches[entryIndex], features: features) }
                    continue
                }
                let sourceLower = max(start.recordedAt, coveredThrough ?? start.recordedAt)
                guard end.recordedAt > sourceLower else { continue }
                let sampleInterval = end.timestampMilliseconds - start.timestampMilliseconds
                let speed = Geo.distanceMeters(from: start.coordinate, to: end.coordinate) / (Double(sampleInterval) / 1_000)
                // Check original observations so clipping at a timeline boundary cannot conceal sparse or implausible evidence.
                let supported = sampleInterval <= maximumObservationIntervalMilliseconds && speed <= maximumObservedSpeedMetersPerSecond
                var entryIndex = firstEntry(endingAfter: sourceLower, in: timeline.entries)
                while entryIndex < timeline.entries.count {
                    let entry = timeline.entries[entryIndex]
                    if entry.startedAt >= end.recordedAt { break }
                    guard entry.kind == .lift else {
                        entryIndex += 1
                        continue
                    }
                    let lower = max(sourceLower, entry.startedAt)
                    let upper = min(end.recordedAt, entry.endedAt)
                    if lower < upper {
                        let a = interpolated(at: lower, from: start, to: end)
                        let b = interpolated(at: upper, from: start, to: end)
                        let crossesBreak = timeline.breaks.contains { $0.startedAt < upper && $0.endedAt > lower }
                        let candidate = supported && !crossesBreak ? bestCandidate(from: a, to: b, kind: entry.kind, index: index, features: features) : nil
                        var builder = builders[entryIndex] ?? SpanBuilder()
                        builder.append(candidate, from: lower, to: upper, distance: Geo.distanceMeters(from: a, to: b), into: &matches[entryIndex], features: features)
                        builders[entryIndex] = builder
                    }
                    entryIndex += 1
                }
                coveredThrough = end.recordedAt
            }
            for entryIndex in builders.keys { builders[entryIndex]?.finish(into: &matches[entryIndex], features: features) }
        }
        var resortIDs = Set<String>()
        let resorts = matches.flatMap { $0 }.flatMap { $0.feature.resorts }.filter { resortIDs.insert($0.id).inserted }
        return SkiTimelineMatches(datasetVersion: datasetVersion, entries: matches, resorts: resorts)
    }

    private static func firstEntry(endingAfter time: Timestamp, in entries: [ActivityTimelineEntry]) -> Int {
        var lower = 0, upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].endedAt <= time { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }

    private static func interpolated(at time: Timestamp, from start: TrackPoint, to end: TrackPoint) -> Coordinate {
        let fraction = Double(time.millisecondsSince1970 - start.timestampMilliseconds) / Double(end.timestampMilliseconds - start.timestampMilliseconds)
        return coordinate(from: start.coordinate, to: end.coordinate, fraction: fraction)
    }

    private static func coordinate(from start: Coordinate, to end: Coordinate, fraction: Double) -> Coordinate {
        let longitude = wrappedLongitude(start.longitude + wrappedLongitude(end.longitude - start.longitude) * fraction)
        return try! Coordinate(latitude: min(90, max(-90, start.latitude + (end.latitude - start.latitude) * fraction)), longitude: longitude)
    }

    private static func wrappedLongitude(_ longitude: Double) -> Double {
        if longitude > 180 { return longitude - 360 }
        if longitude < -180 { return longitude + 360 }
        return longitude
    }

    private struct Candidate {
        let featureIndex: Int
        let start: Projection
        let end: Projection
        let score: Double
        let confidence: Double
    }

    private static func bestCandidate(from start: Coordinate, to end: Coordinate, kind: ActivityTimelineKind, index: SegmentIndex, features: [SkiFeature]) -> Candidate? {
        let middle = coordinate(from: start, to: end, fraction: 0.5)
        let starts = index.projections(near: start, kind: kind, features: features)
        let ends = index.projections(near: end, kind: kind, features: features)
        let middles = index.projections(near: middle, kind: kind, features: features)
        let movement = Geo.distanceMeters(from: start, to: end)
        let observed = vector(from: start, to: end)
        var candidates: [Candidate] = []
        for (featureIndex, a) in starts {
            guard let b = ends[featureIndex], let m = middles[featureIndex] else { continue }
            var directionPenalty = 0.0
            if movement >= minimumMovementMeters {
                let progress = abs(b.offset - a.offset)
                guard progress >= movement * minimumProgressRatio,
                      progress <= movement * maximumProgressRatio else { continue }
                let projected = vector(from: a.coordinate, to: b.coordinate)
                let denominator = hypot(observed.x, observed.y) * hypot(projected.x, projected.y)
                guard denominator > 0 else { continue }
                let cosine = (observed.x * projected.x + observed.y * projected.y) / denominator
                guard cosine >= minimumDirectionCosine else { continue }
                directionPenalty = (1 - min(1, cosine)) * maximumDistanceMeters
            }
            let score = (a.distance + b.distance + 2 * m.distance) / 4 + directionPenalty
            // This is an evidence score, not a calibrated probability or positional-accuracy estimate.
            let confidence = max(0, 1 - score / (maximumDistanceMeters * 1.5))
            candidates.append(Candidate(featureIndex: featureIndex, start: a, end: b, score: score, confidence: confidence))
        }
        candidates.sort { $0.score < $1.score }
        guard let best = candidates.first, best.score <= maximumAcceptedScoreMeters else { return nil }
        if candidates.count > 1, candidates[1].score - best.score < ambiguityMarginMeters { return nil }
        return best
    }

    private struct SpanBuilder {
        var current: Candidate?
        var startedAt: Timestamp?
        var endedAt: Timestamp?
        var distance = 0.0
        var movingIntervals = 0
        var confidenceSum = 0.0
        var intervalCount = 0
        var minimumOffset = Double.infinity
        var maximumOffset = -Double.infinity

        mutating func append(_ next: Candidate?, from start: Timestamp, to end: Timestamp, distance movement: Double, into matches: inout [SkiFeatureMatch], features: [SkiFeature]) {
            guard let next else {
                finish(into: &matches, features: features)
                return
            }
            if let current {
                let connected = endedAt == start && Geo.distanceMeters(from: current.end.coordinate, to: next.start.coordinate) <= maximumTransitionDistanceMeters
                if !connected || current.featureIndex != next.featureIndex { finish(into: &matches, features: features) }
                // A jump between nearby but disconnected lines must leave an unsupported interval.
                if !connected { return }
            }
            if startedAt == nil { startedAt = start }
            current = next
            endedAt = end
            distance += movement
            if movement >= minimumMovementMeters { movingIntervals += 1 }
            confidenceSum += next.confidence
            intervalCount += 1
            minimumOffset = min(minimumOffset, next.start.offset, next.end.offset)
            maximumOffset = max(maximumOffset, next.start.offset, next.end.offset)
        }

        mutating func finish(into matches: inout [SkiFeatureMatch], features: [SkiFeature]) {
            if let current, let startedAt, let endedAt, movingIntervals >= minimumMovingIntervals, distance >= minimumMatchedDistanceMeters, maximumOffset - minimumOffset >= minimumMatchedDistanceMeters {
                matches.append(SkiFeatureMatch(feature: features[current.featureIndex].identity, startedAt: startedAt, endedAt: endedAt, confidence: confidenceSum / Double(intervalCount)))
            }
            self = SpanBuilder()
        }
    }

    private static func vector(from start: Coordinate, to end: Coordinate) -> (x: Double, y: Double) {
        let metersPerDegree = 6_371_000 * Double.pi / 180
        return (wrappedLongitude(end.longitude - start.longitude) * cos(start.latitude * .pi / 180) * metersPerDegree,
                (end.latitude - start.latitude) * metersPerDegree)
    }

    private struct Projection {
        let coordinate: Coordinate
        let distance: Double
        let offset: Double
    }

    private struct Segment {
        let featureIndex: Int
        let start: Coordinate
        let end: Coordinate
        let offset: Double
        let length: Double

        func project(_ point: Coordinate) -> Projection {
            let a = vector(from: point, to: start)
            let edge = vector(from: point, to: end)
            let dx = edge.x - a.x, dy = edge.y - a.y
            let squaredLength = dx * dx + dy * dy
            let fraction = squaredLength > 0 ? min(1, max(0, -(a.x * dx + a.y * dy) / squaredLength)) : 0
            return Projection(coordinate: coordinate(from: start, to: end, fraction: fraction), distance: hypot(a.x + fraction * dx, a.y + fraction * dy), offset: offset + length * fraction)
        }
    }

    private struct Cell: Hashable {
        let x: Int
        let y: Int
        init(x: Int, y: Int) {
            let count = Int(360 / SegmentIndex.cellDegrees)
            self.x = ((x % count) + count) % count
            self.y = y
        }
    }

    private struct SegmentIndex {
        static let cellDegrees = 0.002
        private var segments: [Segment] = []
        private var cells: [Cell: [Int]] = [:]
        private var broadSegments: [Int] = []

        init(features: [SkiFeature]) {
            for (featureIndex, feature) in features.enumerated() where feature.identity.kind == .lift {
                var offset = 0.0
                for (a, b) in zip(feature.coordinates, feature.coordinates.dropFirst()) {
                    let length = Geo.distanceMeters(from: a, to: b)
                    guard length > 0 else { continue }
                    let segmentIndex = segments.count
                    segments.append(Segment(featureIndex: featureIndex, start: a, end: b, offset: offset, length: length))
                    offset += length
                    let longitude = a.longitude + wrappedLongitude(b.longitude - a.longitude)
                    let xs = cellRange(min(a.longitude, longitude), max(a.longitude, longitude))
                    let ys = cellRange(min(a.latitude, b.latitude), max(a.latitude, b.latitude))
                    // Malformed or unusually long edges must not allocate an enormous grid rectangle.
                    if xs.count * ys.count > 512 {
                        broadSegments.append(segmentIndex)
                    } else {
                        for x in xs { for y in ys { cells[Cell(x: x, y: y), default: []].append(segmentIndex) } }
                    }
                }
            }
        }

        func projections(near point: Coordinate, kind: ActivityTimelineKind, features: [SkiFeature]) -> [Int: Projection] {
            let latitudeRadius = maximumDistanceMeters / (6_371_000 * .pi / 180)
            let longitudeRadius = latitudeRadius / max(0.01, cos(point.latitude * .pi / 180))
            let xs = cellRange(point.longitude - longitudeRadius, point.longitude + longitudeRadius)
            let ys = cellRange(point.latitude - latitudeRadius, point.latitude + latitudeRadius)
            var nearby = Set(broadSegments)
            for x in xs { for y in ys { nearby.formUnion(cells[Cell(x: x, y: y)] ?? []) } }
            var projections: [Int: Projection] = [:]
            for segmentIndex in nearby {
                let segment = segments[segmentIndex]
                guard features[segment.featureIndex].identity.kind == kind else { continue }
                let projection = segment.project(point)
                guard projection.distance <= maximumDistanceMeters else { continue }
                if projection.distance < (projections[segment.featureIndex]?.distance ?? .infinity) {
                    projections[segment.featureIndex] = projection
                }
            }
            return projections
        }

        private func cellRange(_ minimum: Double, _ maximum: Double) -> ClosedRange<Int> {
            Int(floor(minimum / Self.cellDegrees))...Int(floor(maximum / Self.cellDegrees))
        }
    }
}
