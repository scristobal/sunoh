enum TrackClassification: String, CaseIterable, Equatable, Sendable {
    case run, lift
}

struct ClassifiedTrackSection: Equatable, Sendable {
    let classification: TrackClassification
    let points: [TrackPoint]
}

extension Geo {
    /// Splits observed route intervals at the detector's disjoint passage boundaries without changing the recording.
    static func classifiedSections(in geometry: TrackGeometry, passages: SkiActivityDetector.Result) -> [ClassifiedTrackSection] {
        let ranges = classifiedPassages(passages)
        var builder = ClassifiedTrackBuilder()
        for section in geometry.sections {
            for (start, end) in zip(section.points, section.points.dropFirst()) {
                let milliseconds = end.timestampMilliseconds - start.timestampMilliseconds
                guard milliseconds > 0 else {
                    builder.finishSection()
                    continue
                }
                forEachClassifiedInterval(from: start.recordedAt, to: end.recordedAt, passages: ranges) { interval in
                    builder.append(from: interpolatedPoint(at: interval.startedAt, from: start, to: end),
                                   to: interpolatedPoint(at: interval.endedAt, from: start, to: end), classification: interval.classification)
                }
            }
            builder.finishSection()
        }
        return builder.sections
    }

    struct ClassifiedPassage {
        let range: SkiActivityDetector.Passage
        let classification: TrackClassification
    }

    struct ClassifiedTrackInterval {
        let startedAt: Timestamp
        let endedAt: Timestamp
        let classification: TrackClassification
        let passageIndex: Int?
    }

    static func classifiedPassages(_ passages: SkiActivityDetector.Result) -> [ClassifiedPassage] {
        (passages.runs.map { ClassifiedPassage(range: $0, classification: .run) }
            + passages.lifts.map { ClassifiedPassage(range: $0, classification: .lift) })
            .filter { $0.range.startedAt < $0.range.endedAt }
            .sorted { $0.range.startedAt < $1.range.startedAt }
    }

    static func forEachClassifiedInterval(from start: Timestamp, to end: Timestamp, passages: [ClassifiedPassage], _ body: (ClassifiedTrackInterval) -> Void) {
        var lower = start
        var index = firstPassage(endingAfter: lower, in: passages)
        while lower < end {
            let upper: Timestamp
            let classification: TrackClassification
            let passageIndex: Int?
            if index < passages.count {
                let passage = passages[index]
                if lower < passage.range.startedAt {
                    upper = min(end, passage.range.startedAt)
                    classification = .run
                    passageIndex = nil
                } else {
                    upper = min(end, passage.range.endedAt)
                    classification = passage.classification
                    passageIndex = index
                    if upper == passage.range.endedAt { index += 1 }
                }
            } else {
                upper = end
                classification = .run
                passageIndex = nil
            }
            body(ClassifiedTrackInterval(startedAt: lower, endedAt: upper, classification: classification, passageIndex: passageIndex))
            lower = upper
        }
    }

    private static func firstPassage(endingAfter time: Timestamp, in passages: [ClassifiedPassage]) -> Int {
        var lower = 0, upper = passages.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if passages[middle].range.endedAt <= time { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }

    private static func interpolatedPoint(at time: Timestamp, from start: TrackPoint, to end: TrackPoint) -> TrackPoint {
        if time == start.recordedAt { return start }
        if time == end.recordedAt { return end }
        let fraction = Double(time.millisecondsSince1970 - start.timestampMilliseconds) / Double(end.timestampMilliseconds - start.timestampMilliseconds)
        var longitudeDelta = end.longitude - start.longitude
        if longitudeDelta > 180 { longitudeDelta -= 360 }
        if longitudeDelta < -180 { longitudeDelta += 360 }
        var longitude = start.longitude + longitudeDelta * fraction
        if longitude > 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }
        let latitude = min(90, max(-90, start.latitude + (end.latitude - start.latitude) * fraction))
        var elevation: Double?
        if let a = start.elevationMeters, let b = end.elevationMeters {
            let interpolated = a * (1 - fraction) + b * fraction
            if interpolated.isFinite { elevation = interpolated }
        }
        // The timestamp is inside a valid interval, and the interpolated coordinates and elevation remain valid.
        return try! TrackPoint(timestampMilliseconds: time.millisecondsSince1970, latitude: latitude, longitude: longitude, elevationMeters: elevation)
    }

    private struct ClassifiedTrackBuilder {
        var sections: [ClassifiedTrackSection] = []
        private var points: [TrackPoint] = []
        private var classification = TrackClassification.run

        mutating func append(from start: TrackPoint, to end: TrackPoint, classification next: TrackClassification) {
            if classification != next || points.last != start {
                finishSection()
                classification = next
                points.append(start)
            }
            points.append(end)
        }

        mutating func finishSection() {
            if points.count >= 2 { sections.append(ClassifiedTrackSection(classification: classification, points: points)) }
            points.removeAll(keepingCapacity: true)
        }
    }
}
