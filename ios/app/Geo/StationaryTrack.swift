extension Geo {
    struct StationarySpan {
        let pointIndices: ClosedRange<Int>
        let startedAt: Timestamp
        let endedAt: Timestamp
    }

    /// Finds sustained stops without treating slow travel or timestamp reversals as stationary.
    static func stationarySpans(in points: [TrackPoint]) -> [StationarySpan] {
        // Coordinate conversion can put an exact threshold a few floating-point units above its limit.
        let distanceToleranceMeters = 0.000001
        var spans: [StationarySpan] = []
        var origin: Int?
        var endIndex: Int?
        var remainsNearby = true
        func finishCandidate() {
            if let origin, let endIndex, remainsNearby,
               points[endIndex].timestampMilliseconds - points[origin].timestampMilliseconds >= 10_000 {
                spans.append(StationarySpan(pointIndices: origin...endIndex,
                                            startedAt: points[origin].recordedAt, endedAt: points[endIndex].recordedAt))
            }
            origin = nil
            endIndex = nil
            remainsNearby = true
        }
        for index in points.indices.dropLast() {
            let start = points[index], end = points[index + 1]
            let milliseconds = end.timestampMilliseconds - start.timestampMilliseconds
            guard milliseconds > 0 else {
                finishCandidate()
                continue
            }
            let meters = distanceMeters(from: start.coordinate, to: end.coordinate)
            let maximumDistance = Double(milliseconds) / 1_000 * 0.5
            guard meters.isFinite, meters <= maximumDistance + distanceToleranceMeters else {
                finishCandidate()
                continue
            }
            if origin == nil { origin = index }
            endIndex = index + 1
            if let origin, distanceMeters(from: points[origin].coordinate, to: end.coordinate) > 5 + distanceToleranceMeters {
                remainsNearby = false
            }
        }
        finishCandidate()
        return spans
    }

    /// Keeps stops between observed lift movement while leaving terminal waits outside the ride.
    static func liftsWithInternalStops(_ lifts: [SkiActivityDetector.Passage], stops: [StationarySpan]) -> [SkiActivityDetector.Passage] {
        var ranges = lifts
        for stop in stops {
            let before = ranges.lastIndex { $0.startedAt < stop.startedAt && $0.endedAt >= stop.startedAt }
            let after = ranges.firstIndex { $0.startedAt <= stop.endedAt && $0.endedAt > stop.endedAt }
            if let before, let after {
                let joined = SkiActivityDetector.Passage(startedAt: ranges[before].startedAt, endedAt: ranges[after].endedAt)
                ranges.replaceSubrange(before...after, with: [joined])
                continue
            }
            ranges = ranges.compactMap { passage in
                let start = passage.startedAt >= stop.startedAt && passage.startedAt < stop.endedAt ? stop.endedAt : passage.startedAt
                let end = passage.endedAt > stop.startedAt && passage.endedAt <= stop.endedAt ? stop.startedAt : passage.endedAt
                guard start < end else { return nil }
                return SkiActivityDetector.Passage(startedAt: start, endedAt: end)
            }
        }
        return ranges
    }
}
