enum ActivityTimelineKind: String, Codable, CaseIterable, Equatable, Sendable {
    case run, lift
}

enum ActivityQualityLevel: String, Codable, CaseIterable, Equatable, Sendable {
    case low, fair, good, excellent
}

struct SampleGapHistogram: Codable, Equatable, Sendable {
    let binWidthMilliseconds: Int64
    /// Bin i counts intervals greater than i × width and no greater than (i + 1) × width.
    let counts: [Int]
}

struct ActivityTimelineQuality: Codable, Equatable, Sendable {
    static let excellentMaximumIntervalMilliseconds: Int64 = 2_000
    static let goodMaximumIntervalMilliseconds: Int64 = 5_000
    static let fairMaximumIntervalMilliseconds: Int64 = 15_000
    static let excellentMinimumCoverage = 0.90
    static let goodMinimumCoverage = 0.85
    static let fairMinimumCoverage = 0.80

    let level: ActivityQualityLevel
    let maximumSampleIntervalMilliseconds: Int64
    let sampleGapHistogram: SampleGapHistogram?

    init(level: ActivityQualityLevel, maximumSampleIntervalMilliseconds: Int64, sampleGapHistogram: SampleGapHistogram? = nil) {
        self.level = level
        self.maximumSampleIntervalMilliseconds = maximumSampleIntervalMilliseconds
        self.sampleGapHistogram = sampleGapHistogram
    }
}

enum ActivityTimelineBreakReason: String, Codable, Equatable, Sendable {
    case sourceBoundary
}

struct ActivityTimelineBreak: Codable, Equatable, Sendable {
    let startedAt: Timestamp
    let endedAt: Timestamp
    let reason: ActivityTimelineBreakReason

    var durationMilliseconds: Int64 { endedAt.millisecondsSince1970 - startedAt.millisecondsSince1970 }
}

struct ActivityTimeline: Codable, Equatable, Sendable {
    var entries: [ActivityTimelineEntry] = []
    var breaks: [ActivityTimelineBreak] = []
    var skiMatches: SkiTimelineMatches? = nil
}

struct ActivityTimelineEntry: Codable, Equatable, Sendable {
    let kind: ActivityTimelineKind
    let startedAt: Timestamp
    let endedAt: Timestamp
    let distanceMeters: Double?
    let elevationGainMeters: Double?
    let elevationLossMeters: Double?
    var quality: ActivityTimelineQuality? = nil
    var pointCount: Int? = nil

    var durationMilliseconds: Int64 { endedAt.millisecondsSince1970 - startedAt.millisecondsSince1970 }
}

extension Geo {
    /// Describes activity and sampling quality while preserving explicit source recording boundaries.
    static func timeline(in geometry: TrackGeometry, passages: SkiActivityDetector.Result) -> ActivityTimeline {
        let ranges = classifiedPassages(passages)
        var builder = TimelineBuilder()
        var coveredThrough: Timestamp?
        for section in geometry.sections {
            guard let first = section.points.first else { continue }
            if let previous = coveredThrough, first.recordedAt > previous {
                builder.appendSourceBreak(from: previous, to: first.recordedAt)
            }
            coveredThrough = max(coveredThrough ?? first.recordedAt, first.recordedAt)
            let stops = stationarySpans(in: section.points)
            var stopIndex = 0
            for (samplePairIndex, (start, end)) in zip(section.points, section.points.dropFirst()).enumerated() {
                let milliseconds = end.timestampMilliseconds - start.timestampMilliseconds
                let lower = max(start.recordedAt, coveredThrough ?? start.recordedAt)
                guard milliseconds > 0 else {
                    builder.finishSection()
                    continue
                }
                guard end.recordedAt > lower else { continue }
                while stopIndex < stops.count && stops[stopIndex].pointIndices.upperBound <= samplePairIndex { stopIndex += 1 }
                let isStopped = stopIndex < stops.count && stops[stopIndex].pointIndices.contains(samplePairIndex)
                let meters = distanceMeters(from: start.coordinate, to: end.coordinate)
                let speed = meters / (Double(milliseconds) / 1_000)
                forEachClassifiedInterval(from: lower, to: end.recordedAt, passages: ranges) { interval in
                    let kind: ActivityTimelineKind = interval.classification == .lift ? .lift : .run
                    var distance: Double? = 0
                    var gain: Double? = start.elevationMeters != nil && end.elevationMeters != nil ? 0 : nil
                    var loss = gain
                    if !isStopped {
                        let fraction = Double(interval.endedAt.millisecondsSince1970 - interval.startedAt.millisecondsSince1970) / Double(milliseconds)
                        distance = speed.isFinite && speed < maximumSkiSpeedMetersPerSecond ? meters * fraction : 0
                        if let a = start.elevationMeters, let b = end.elevationMeters {
                            let change = (b - a) * fraction
                            if change.isFinite {
                                gain = change > 0 ? change : 0
                                loss = change < 0 ? -change : 0
                            }
                        }
                    }
                    let entry = ActivityTimelineEntry(kind: kind, startedAt: interval.startedAt, endedAt: interval.endedAt,
                                                      distanceMeters: distance, elevationGainMeters: gain, elevationLossMeters: loss)
                    builder.append(entry, passageIndex: interval.passageIndex,
                                   samplePairIndex: samplePairIndex, sampleIntervalMilliseconds: milliseconds)
                }
                coveredThrough = end.recordedAt
            }
            builder.finishSection()
        }
        return ActivityTimeline(entries: builder.entries, breaks: builder.breaks)
    }

    private struct TimelineBuilder {
        private static let histogramBinCount = 30
        var entries: [ActivityTimelineEntry] = []
        var breaks: [ActivityTimelineBreak] = []
        private var current: ActivityTimelineEntry?
        private var passageIndex: Int?
        private var maximumSampleIntervalMilliseconds: Int64 = 0
        private var sampleIntervalCounts: [Int64: Int] = [:]
        private var lastSamplePairIndex: Int?
        private var samplePointIndices: Set<Int> = []
        private var excellentCoveredMilliseconds = 0.0
        private var goodCoveredMilliseconds = 0.0
        private var fairCoveredMilliseconds = 0.0

        mutating func append(_ entry: ActivityTimelineEntry, passageIndex nextPassageIndex: Int?, samplePairIndex: Int, sampleIntervalMilliseconds: Int64) {
            if let current, current.kind == entry.kind, current.endedAt == entry.startedAt, (entry.kind == .run || passageIndex == nextPassageIndex) {
                self.current = ActivityTimelineEntry(kind: entry.kind, startedAt: current.startedAt, endedAt: entry.endedAt,
                                                     distanceMeters: adding(current.distanceMeters, entry.distanceMeters),
                                                     elevationGainMeters: adding(current.elevationGainMeters, entry.elevationGainMeters),
                                                     elevationLossMeters: adding(current.elevationLossMeters, entry.elevationLossMeters))
            } else {
                finishSection()
                current = entry
                passageIndex = nextPassageIndex
            }
            // Keep the original cadence when an observed pair straddles an activity boundary.
            maximumSampleIntervalMilliseconds = max(maximumSampleIntervalMilliseconds, sampleIntervalMilliseconds)
            let fraction = Double(entry.durationMilliseconds) / Double(sampleIntervalMilliseconds)
            excellentCoveredMilliseconds += fraction * Double(min(sampleIntervalMilliseconds, ActivityTimelineQuality.excellentMaximumIntervalMilliseconds))
            goodCoveredMilliseconds += fraction * Double(min(sampleIntervalMilliseconds, ActivityTimelineQuality.goodMaximumIntervalMilliseconds))
            fairCoveredMilliseconds += fraction * Double(min(sampleIntervalMilliseconds, ActivityTimelineQuality.fairMaximumIntervalMilliseconds))
            if lastSamplePairIndex != samplePairIndex {
                sampleIntervalCounts[sampleIntervalMilliseconds, default: 0] += 1
                samplePointIndices.insert(samplePairIndex)
                samplePointIndices.insert(samplePairIndex + 1)
                lastSamplePairIndex = samplePairIndex
            }
        }

        mutating func appendSourceBreak(from start: Timestamp, to end: Timestamp) {
            finishSection()
            guard end > start else { return }
            if let previous = breaks.last, previous.endedAt == start {
                breaks[breaks.count - 1] = ActivityTimelineBreak(startedAt: previous.startedAt, endedAt: end,
                                                               reason: .sourceBoundary)
            } else {
                breaks.append(ActivityTimelineBreak(startedAt: start, endedAt: end, reason: .sourceBoundary))
            }
        }

        mutating func finishSection() {
            if var current {
                let duration = Double(current.durationMilliseconds)
                let level: ActivityQualityLevel
                if excellentCoveredMilliseconds >= duration * ActivityTimelineQuality.excellentMinimumCoverage { level = .excellent }
                else if goodCoveredMilliseconds >= duration * ActivityTimelineQuality.goodMinimumCoverage { level = .good }
                else if fairCoveredMilliseconds >= duration * ActivityTimelineQuality.fairMinimumCoverage { level = .fair }
                else { level = .low }
                current.quality = ActivityTimelineQuality(level: level, maximumSampleIntervalMilliseconds: maximumSampleIntervalMilliseconds,
                                                          sampleGapHistogram: sampleGapHistogram())
                current.pointCount = samplePointIndices.count
                entries.append(current)
            }
            current = nil
            passageIndex = nil
            maximumSampleIntervalMilliseconds = 0
            sampleIntervalCounts.removeAll(keepingCapacity: true)
            lastSamplePairIndex = nil
            samplePointIndices.removeAll(keepingCapacity: true)
            excellentCoveredMilliseconds = 0
            goodCoveredMilliseconds = 0
            fairCoveredMilliseconds = 0
        }

        private func sampleGapHistogram() -> SampleGapHistogram {
            let width = histogramBinWidthMilliseconds()
            var counts = Array(repeating: 0, count: Self.histogramBinCount)
            for (interval, count) in sampleIntervalCounts {
                counts[Int((interval - 1) / width)] += count
            }
            return SampleGapHistogram(binWidthMilliseconds: width, counts: counts)
        }

        private func histogramBinWidthMilliseconds() -> Int64 {
            var magnitude: Int64 = 1_000
            while true {
                for multiplier in [Int64(1), 2, 5] {
                    let width = magnitude * multiplier
                    if (maximumSampleIntervalMilliseconds - 1) / width < Int64(Self.histogramBinCount) { return width }
                }
                magnitude *= 10
            }
        }

        private func adding(_ first: Double?, _ second: Double?) -> Double? {
            first.map { $0 + (second ?? 0) } ?? second
        }
    }
}
