import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Sunoh

private let processingTrack = GPXTrack(segments: [
    GPXSegment(points: [try! TrackPoint(timestampMilliseconds: 1_001, latitude: 47, longitude: 11, elevationMeters: 2_000),
                   try! TrackPoint(timestampMilliseconds: 2_001, latitude: 47.001, longitude: 11.001, elevationMeters: 2_010)]),
    GPXSegment(points: [try! TrackPoint(timestampMilliseconds: 40_001, latitude: 47.002, longitude: 11.002, elevationMeters: nil)])
])

private func processingURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("processing.store")
}

private func persistedResults(_ url: URL) async throws -> [ActivityAnalysis] {
    try await Task.detached {
        let context = ModelContext(try ActivityDatabase.container(at: url))
        return try context.fetch(FetchDescriptor<StoredActivityAnalysis>()).map { try $0.result() }
    }.value
}

private func processingQuality(_ level: ActivityQualityLevel, _ maximum: Int64, intervalCount: Int = 1) -> ActivityTimelineQuality {
    var counts = [Int](repeating: 0, count: 30)
    counts[0] = intervalCount - 1
    counts[Int((maximum - 1) / 1_000)] += 1
    return ActivityTimelineQuality(level: level, maximumSampleIntervalMilliseconds: maximum,
        sampleGapHistogram: SampleGapHistogram(binWidthMilliseconds: 1_000, counts: counts))
}

private final class ProcessingCommit: Sendable {
    private let failure = Mutex(false)
    private let count = Mutex(0)
    var saves: Int { count.withLock { $0 } }
    func failNext() { failure.withLock { $0 = true } }
    func save(_ context: ModelContext) throws {
        let fail = failure.withLock { value in
            defer { value = false }
            return value
        }
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
        try context.save()
        count.withLock { $0 += 1 }
    }
}

struct ActivityProcessingTests {
    @Test func twoStateClassificationRebuildsAndPersistsAllRecordedIntervals() async throws {
        let url = try processingURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var points: [TrackPoint] = []
        var seconds = 0, meters = 0.0, elevation = 2_000.0
        func appendPoint() throws {
            points.append(try TrackPoint(timestampMilliseconds: Int64(seconds) * 1_000, latitude: 0,
                longitude: meters * 180 / (.pi * 6_371_000), elevationMeters: elevation))
        }
        try appendPoint()
        for (duration, speed, climbRate) in [(30, 0.0, 0.0), (120, 8.0, -1.5), (40, 2.0, 0.0),
                                              (20, 0.0, 0.0), (180, 3.0, 1.0), (20, 0.0, 0.0)] {
            for _ in stride(from: 0, to: duration, by: 5) {
                seconds += 5; meters += speed * 5; elevation += climbRate * 5
                try appendPoint()
            }
        }
        let source = GPXTrack(segments: [GPXSegment(points: points)])
        let repository = try await ActivityRepository.open(url: url)
        let summary = try #require(try await repository.importTracks([source]).imported.first)
        try await repository.saveAnalysis(ActivityAnalysis(activityID: summary.id, sourceRevision: summary.sourceRevision,
            processingVersion: ActivityAnalysis.currentProcessingVersion - 1, processedAt: 1, statistics: ActivityStatistics(), thumbnailPNG: Data([1]), passages: .init(), timeline: .init()))

        let result = try await ActivityProcessor(repository: repository).process(id: summary.id)
        let entries = try #require(result.timeline).entries
        #expect(result.isCurrent(for: summary))
        #expect(entries.map(\.kind) == [.run, .lift, .run])
        #expect(entries.map(\.durationMilliseconds) == [210_000, 180_000, 20_000])
        #expect(entries.first?.startedAt == 0)
        #expect(entries.last?.endedAt == 410_000)
        #expect(entries.reduce(0) { $0 + $1.durationMilliseconds } == 410_000)
        for (before, after) in zip(entries, entries.dropFirst()) { #expect(before.endedAt == after.startedAt) }
        #expect(result.statistics.runCount == 2)
        #expect(result.statistics.runDurationMilliseconds == entries.filter { $0.kind == .run }.reduce(0) { $0 + $1.durationMilliseconds })
        #expect(try await persistedResults(url) == [result])
        #expect(try await repository.recordedTrack(id: summary.id).gpx == source)

        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: summary.id) == result)
        #expect(try await reopened.recordedTrack(id: summary.id).gpx == source)
    }

    @Test func stationaryTimeRebuildsInsideTheRunAndIsReusedAfterReopen() async throws {
        let url = try processingURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let points = try stride(from: 0, through: 240, by: 10).map { seconds in
            let movingSeconds = min(seconds, 60) + max(0, seconds - 180)
            return try TrackPoint(timestampMilliseconds: Int64(seconds) * 1_000, latitude: 0,
                longitude: Double(movingSeconds) * 5 * 180 / (.pi * 6_371_000),
                elevationMeters: 2_000 - Double(movingSeconds) * 2)
        }
        let source = GPXTrack(segments: [GPXSegment(points: points)])
        let repository = try await ActivityRepository.open(url: url)
        let summary = try #require(try await repository.importTracks([source]).imported.first)
        try await repository.saveAnalysis(ActivityAnalysis(activityID: summary.id, sourceRevision: summary.sourceRevision,
            processingVersion: ActivityAnalysis.currentProcessingVersion - 1, processedAt: 1, statistics: ActivityStatistics(), thumbnailPNG: Data([1]), passages: .init(), timeline: .init()))

        let result = try await ActivityProcessor(repository: repository).process(id: summary.id)
        let timeline = try #require(result.timeline)
        let run = try #require(timeline.entries.first)
        #expect(result.isCurrent(for: summary))
        #expect(timeline.entries.count == 1)
        #expect(run.kind == .run)
        #expect(run.durationMilliseconds == 240_000)
        #expect(run.pointCount == 25)
        #expect(run.quality?.level == .fair)
        #expect(abs(try #require(run.distanceMeters) - 600) < 0.000001)
        #expect(run.elevationLossMeters == 240)
        #expect(result.statistics.runCount == 1)
        #expect(result.statistics.runDurationMilliseconds == 240_000)
        #expect(abs(result.statistics.runDistanceMeters - 600) < 0.000001)
        #expect(try await persistedResults(url) == [result])
        #expect(try await repository.recordedTrack(id: summary.id).gpx == source)

        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: summary.id) == result)
        #expect(try await reopened.recordedTrack(id: summary.id).gpx == source)
    }

    @Test func removingTheGlobalGapCutoffRebuildsAndCachesLongIntervals() async throws {
        let url = try processingURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func point(_ seconds: Int) throws -> TrackPoint {
            try TrackPoint(timestampMilliseconds: Int64(seconds) * 1_000, latitude: 0,
                           longitude: Double(seconds) * 10 * 180 / (.pi * 6_371_000), elevationMeters: nil)
        }
        let source = try GPXTrack(segments: [GPXSegment(points: [point(0), point(10), point(70)]),
                                              GPXSegment(points: [point(200), point(260)])])
        let repository = try await ActivityRepository.open(url: url)
        let summary = try #require(try await repository.importTracks([source]).imported.first)
        try await repository.saveAnalysis(ActivityAnalysis(activityID: summary.id, sourceRevision: summary.sourceRevision,
            processingVersion: ActivityAnalysis.currentProcessingVersion - 1, processedAt: 1, statistics: ActivityStatistics(), thumbnailPNG: Data([1]), passages: .init(), timeline: .init()))

        let result = try await ActivityProcessor(repository: repository).process(id: summary.id)
        let timeline = try #require(result.timeline)
        #expect(result.isCurrent(for: summary))
        #expect(abs(result.statistics.distanceMeters - 1_300) < 0.000001)
        #expect(timeline.entries.map(\.kind) == [.run, .run])
        #expect(timeline.entries.map(\.durationMilliseconds) == [70_000, 60_000])
        #expect(timeline.entries.map(\.pointCount) == [3, 2])
        #expect(timeline.entries.allSatisfy { $0.quality?.level == .low })
        #expect(timeline.entries.map { $0.quality?.sampleGapHistogram?.binWidthMilliseconds } == [2_000, 2_000])
        #expect(timeline.entries.map { $0.quality?.sampleGapHistogram?.counts.reduce(0, +) } == [2, 1])
        #expect(timeline.entries.allSatisfy { $0.quality?.sampleGapHistogram?.counts.last == 1 })
        #expect(timeline.breaks == [ActivityTimelineBreak(startedAt: 70_000, endedAt: 200_000, reason: .sourceBoundary)])
        #expect(result.statistics.runCount == 2)
        #expect(result.statistics.runDurationMilliseconds == 130_000)
        #expect(abs(result.statistics.runDistanceMeters - 1_300) < 0.000001)
        #expect(result.thumbnailPNG != nil)
        #expect(try await repository.recordedTrack(id: summary.id).gpx == source)

        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: summary.id) == result)
        #expect(try await reopened.recordedTrack(id: summary.id).gpx == source)
    }

    @Test func timelineEntriesAreUpdatedPersistedAndReusedAfterReopen() async throws {
        let url = try processingURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = try await ActivityRepository.open(url: url)
        let summary = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let timeline = ActivityTimeline(entries: [
            ActivityTimelineEntry(kind: .run, startedAt: 1_001, endedAt: 1_501, distanceMeters: 50.25, elevationGainMeters: 1.5, elevationLossMeters: 10.75,
                                  quality: processingQuality(.excellent, 2_000, intervalCount: 3), pointCount: 4),
            ActivityTimelineEntry(kind: .lift, startedAt: 1_501, endedAt: 2_001, distanceMeters: 25.5, elevationGainMeters: 15.25, elevationLossMeters: 0,
                                  quality: processingQuality(.good, 4_000, intervalCount: 4), pointCount: 5),
            ActivityTimelineEntry(kind: .run, startedAt: 2_001, endedAt: 3_001, distanceMeters: 8.25, elevationGainMeters: nil, elevationLossMeters: nil,
                                  quality: processingQuality(.fair, 12_000, intervalCount: 5), pointCount: 6),
            ActivityTimelineEntry(kind: .lift, startedAt: 3_001, endedAt: 4_001, distanceMeters: 0, elevationGainMeters: nil, elevationLossMeters: nil,
                                  quality: processingQuality(.low, 20_000, intervalCount: 6), pointCount: 7)
        ], breaks: [ActivityTimelineBreak(startedAt: 4_001, endedAt: 40_001, reason: .sourceBoundary)])
        let processor = ActivityProcessor(repository: repository, calculate: { _ in
            (ActivityStatistics(), Data([1]), .init(), timeline)
        })
        let first = try await processor.process(id: summary.id)
        #expect(first.timeline == timeline)
        #expect(first.timeline?.entries.compactMap { $0.quality?.level } == [.excellent, .good, .fair, .low])
        #expect(first.timeline?.entries.map(\.durationMilliseconds) == [500, 500, 1_000, 1_000])
        #expect(first.timeline?.entries.map(\.pointCount) == [4, 5, 6, 7])
        #expect(first.timeline?.entries.first?.quality?.sampleGapHistogram == SampleGapHistogram(
            binWidthMilliseconds: 1_000, counts: [2, 1] + [Int](repeating: 0, count: 28)))
        #expect(first.isCurrent(for: summary))
        #expect(try await persistedResults(url) == [first])
        let updatedTimeline = ActivityTimeline(entries: [ActivityTimelineEntry(kind: .run, startedAt: 1_001, endedAt: 40_001,
            distanceMeters: 500.75, elevationGainMeters: 20.5, elevationLossMeters: 200.25,
            quality: processingQuality(.good, 5_000, intervalCount: 7), pointCount: 8)])
        let updated = ActivityAnalysis(activityID: summary.id, sourceRevision: summary.sourceRevision,
            processingVersion: ActivityAnalysis.currentProcessingVersion, processedAt: 99_000, statistics: first.statistics,
            thumbnailPNG: first.thumbnailPNG, passages: first.passages, timeline: updatedTimeline)
        try await repository.saveAnalysis(updated)
        #expect(try await persistedResults(url) == [updated])
        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: summary.id) == updated)
    }

    @Test func currentVersionWithoutTimelineIsRebuilt() async throws {
        let url = try processingURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = try await ActivityRepository.open(url: url)
        let summary = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let missingTimeline = ActivityAnalysis(activityID: summary.id, sourceRevision: summary.sourceRevision,
            processingVersion: ActivityAnalysis.currentProcessingVersion, processedAt: 1, statistics: ActivityStatistics(),
            thumbnailPNG: Data([1]), passages: .init())
        try await repository.saveAnalysis(missingTimeline)
        #expect(try await persistedResults(url) == [missingTimeline])
        #expect(!missingTimeline.isCurrent(for: summary))
        let processor = ActivityProcessor(repository: repository, clock: { 99_000 }, calculate: { _ in
            (ActivityStatistics(), Data([1]), .init(), .init())
        })
        let rebuilt = try await processor.process(id: summary.id)
        #expect(rebuilt.processedAt == 99_000)
        #expect(rebuilt.timeline == ActivityTimeline())
        #expect(rebuilt.isCurrent(for: summary))
        #expect(try await persistedResults(url) == [rebuilt])
        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: summary.id) == rebuilt)
    }

    @Test(arguments: ["quality", "pointCount", "histogram"])
    func currentTimelineMissingCachedDetailsIsRebuiltOnce(missing: String) async throws {
        let url = try processingURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = try await ActivityRepository.open(url: url)
        let summary = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let completeEntry = ActivityTimelineEntry(kind: .run, startedAt: 1_001, endedAt: 2_001,
            distanceMeters: 50, elevationGainMeters: 10, elevationLossMeters: 0,
            quality: processingQuality(.excellent, 1_000), pointCount: 2)
        var incompleteEntry = completeEntry
        switch missing {
        case "quality": incompleteEntry.quality = nil
        case "pointCount": incompleteEntry.pointCount = nil
        default: incompleteEntry.quality = ActivityTimelineQuality(level: .excellent, maximumSampleIntervalMilliseconds: 1_000)
        }
        let incomplete = ActivityTimeline(entries: [incompleteEntry])
        let stale = ActivityAnalysis(activityID: summary.id, sourceRevision: summary.sourceRevision,
            processingVersion: ActivityAnalysis.currentProcessingVersion, processedAt: 1, statistics: ActivityStatistics(),
            thumbnailPNG: Data([1]), passages: .init(), timeline: incomplete)
        try await repository.saveAnalysis(stale)
        let reopened = try await ActivityRepository.open(url: url)
        let decoded = try #require(try await reopened.storedAnalysis(id: summary.id))
        #expect(decoded == stale)
        #expect(!decoded.isCurrent(for: summary))
        let complete = ActivityTimeline(entries: [completeEntry])
        let processor = ActivityProcessor(repository: reopened, clock: { 99_000 }, calculate: { _ in
            (stale.statistics, stale.thumbnailPNG, .init(), complete)
        })
        let rebuilt = try await processor.process(id: summary.id)
        #expect(rebuilt.timeline == complete)
        #expect(rebuilt.processedAt == 99_000)
        #expect(rebuilt.isCurrent(for: summary))
        let cachedRepository = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: cachedRepository, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: summary.id) == rebuilt)
    }

    @Test func passageRangesAreUpdatedPersistedAndReusedAfterReopen() async throws {
        let url = try processingURL()
        let repository = try await ActivityRepository.open(url: url)
        let summary = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let passages = SkiActivityDetector.Result(runs: [.init(startedAt: 1_001, endedAt: 2_001)],
            lifts: [.init(startedAt: 2_001, endedAt: 40_001)])
        let processor = ActivityProcessor(repository: repository, calculate: { _ in
            var statistics = ActivityStatistics()
            statistics.runCount = passages.runCount
            return (statistics, Data([1]), passages, .init())
        })
        let first = try await processor.process(id: summary.id)
        #expect(first.passages == passages)
        #expect(try await persistedResults(url) == [first])
        let updatedPassages = SkiActivityDetector.Result(runs: [.init(startedAt: 1_001, endedAt: 1_501), .init(startedAt: 2_001, endedAt: 40_001)],
            lifts: [.init(startedAt: 1_501, endedAt: 2_001)])
        var statistics = first.statistics
        statistics.runCount = updatedPassages.runCount
        let updated = ActivityAnalysis(activityID: summary.id, sourceRevision: summary.sourceRevision,
            processingVersion: ActivityAnalysis.currentProcessingVersion, processedAt: 99_000, statistics: statistics,
            thumbnailPNG: first.thumbnailPNG, passages: updatedPassages, timeline: first.timeline)
        try await repository.saveAnalysis(updated)
        #expect(try await persistedResults(url) == [updated])
        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: summary.id) == updated)
    }

    @Test func currentVersionWithoutPassageRangesIsRebuilt() async throws {
        let url = try processingURL()
        let repository = try await ActivityRepository.open(url: url)
        let summary = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let missingRanges = ActivityAnalysis(activityID: summary.id, sourceRevision: summary.sourceRevision,
            processingVersion: ActivityAnalysis.currentProcessingVersion, processedAt: 1, statistics: ActivityStatistics(), thumbnailPNG: Data([1]), timeline: .init())
        try await repository.saveAnalysis(missingRanges)
        #expect(!missingRanges.isCurrent(for: summary))
        let processor = ActivityProcessor(repository: repository, clock: { 99_000 }, calculate: { _ in
            (ActivityStatistics(), Data([1]), .init(), .init())
        })
        let rebuilt = try await processor.process(id: summary.id)
        #expect(rebuilt.processedAt == 99_000)
        #expect(rebuilt.passages == SkiActivityDetector.Result())
        #expect(rebuilt.isCurrent(for: summary))
        #expect(try await persistedResults(url) == [rebuilt])
    }

    @Test(arguments: [nil, 8.5] as [Double?])
    func passageStatisticsArePersistedUpdatedAndReusedAfterReopen(averageDownhillSpeed: Double?) async throws {
        let url = try processingURL()
        let repository = try await ActivityRepository.open(url: url)
        let summary = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let processor = ActivityProcessor(repository: repository, calculate: { _ in
            var statistics = ActivityStatistics()
            statistics.runCount = 7
            statistics.averageDownhillSpeedMetersPerSecond = averageDownhillSpeed
            if averageDownhillSpeed != nil {
                statistics.runDistanceMeters = 1_100.25
                statistics.runDurationMilliseconds = 120_500
                statistics.maximumRunSpeedMetersPerSecond = 12.75
                statistics.tallestRunHeightMeters = 251.25
                statistics.longestRunDistanceMeters = 711.75
                statistics.averageRunSteepnessPercent = 12.25
                statistics.maximumRunSteepnessPercent = 35.75
            }
            return (statistics, Data([1]), .init(), .init())
        })
        let result = try await processor.process(id: summary.id)
        #expect(result.statistics.runCount == 7)
        #expect(result.statistics.averageDownhillSpeedMetersPerSecond == averageDownhillSpeed)
        #expect(result.statistics.runDistanceMeters == (averageDownhillSpeed == nil ? 0 : 1_100.25))
        #expect(result.statistics.runDurationMilliseconds == (averageDownhillSpeed == nil ? 0 : 120_500))
        #expect(result.statistics.maximumRunSpeedMetersPerSecond == (averageDownhillSpeed == nil ? nil : 12.75))
        #expect(result.statistics.tallestRunHeightMeters == (averageDownhillSpeed == nil ? nil : 251.25))
        #expect(result.statistics.longestRunDistanceMeters == (averageDownhillSpeed == nil ? nil : 711.75))
        #expect(result.statistics.averageRunSteepnessPercent == (averageDownhillSpeed == nil ? nil : 12.25))
        #expect(result.statistics.maximumRunSteepnessPercent == (averageDownhillSpeed == nil ? nil : 35.75))
        #expect(try await persistedResults(url) == [result])
        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: summary.id) == result)

        var updatedStatistics = result.statistics
        updatedStatistics.averageDownhillSpeedMetersPerSecond = averageDownhillSpeed == nil ? 9.75 : nil
        updatedStatistics.runDistanceMeters = averageDownhillSpeed == nil ? 2_000.5 : 0
        updatedStatistics.runDurationMilliseconds = averageDownhillSpeed == nil ? 200_500 : 0
        updatedStatistics.maximumRunSpeedMetersPerSecond = averageDownhillSpeed == nil ? 22.25 : nil
        updatedStatistics.tallestRunHeightMeters = averageDownhillSpeed == nil ? 502.5 : nil
        updatedStatistics.longestRunDistanceMeters = averageDownhillSpeed == nil ? 1_203.5 : nil
        updatedStatistics.averageRunSteepnessPercent = averageDownhillSpeed == nil ? 15.75 : nil
        updatedStatistics.maximumRunSteepnessPercent = averageDownhillSpeed == nil ? 42.25 : nil
        let updated = ActivityAnalysis(activityID: result.activityID, sourceRevision: result.sourceRevision,
            processingVersion: result.processingVersion, processedAt: 99_000, statistics: updatedStatistics, thumbnailPNG: result.thumbnailPNG, passages: result.passages, timeline: result.timeline)
        try await repository.saveAnalysis(updated)
        #expect(try await persistedResults(url) == [updated])
        let reopenedAfterUpdate = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let updatedCache = ActivityProcessor(repository: reopenedAfterUpdate, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await updatedCache.process(id: summary.id) == updated)
    }

    @Test func productionProcessingPersistsSteepnessForItsDetectedRunsAndLifts() async throws {
        let url = try processingURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let metersPerDegree = Double.pi * 6_371_000 / 180
        let downhill = try (0...12).map { index in
            try TrackPoint(timestampMilliseconds: 1_000 + Int64(index) * 10_000, latitude: 0,
                longitude: Double(index) * 80 / metersPerDegree, elevationMeters: 2_000 - Double(index) * 10)
        }
        let uphill = try (0...12).map { index in
            try TrackPoint(timestampMilliseconds: 131_000 + Int64(index) * 10_000, latitude: 0,
                longitude: (960 + Double(index) * 30) / metersPerDegree, elevationMeters: 1_880 + Double(index) * 10)
        }
        let repository = try await ActivityRepository.open(url: url)
        let track = GPXTrack(segments: [GPXSegment(points: downhill), GPXSegment(points: uphill)])
        let summary = try #require(try await repository.importTracks([track]).imported.first)
        let result = try await ActivityProcessor(repository: repository).process(id: summary.id)
        #expect(result.statistics.runCount == 1)
        #expect(result.passages?.runCount == 1)
        #expect(result.passages?.liftCount == 1)
        #expect(abs(try #require(result.statistics.averageRunSteepnessPercent) - 12.5) < 0.000001)
        #expect(abs(try #require(result.statistics.maximumRunSteepnessPercent) - 12.5) < 0.000001)
        let timeline = try #require(result.timeline)
        #expect(timeline.entries.map(\.kind) == [.run, .lift])
        #expect(timeline.entries.first?.startedAt == downhill.first?.recordedAt)
        #expect(timeline.entries.last?.endedAt == uphill.last?.recordedAt)
        #expect(timeline.entries.map(\.durationMilliseconds) == [120_000, 120_000])
        #expect(timeline.entries.map(\.pointCount) == [13, 13])
        var counts = [Int](repeating: 0, count: 30)
        counts[9] = 12
        let histogram = SampleGapHistogram(binWidthMilliseconds: 1_000, counts: counts)
        #expect(timeline.entries.allSatisfy { $0.quality == ActivityTimelineQuality(level: .fair, maximumSampleIntervalMilliseconds: 10_000, sampleGapHistogram: histogram) })
        let continuityBreak = try #require(timeline.breaks.first)
        #expect(continuityBreak.startedAt == downhill.last?.recordedAt)
        #expect(continuityBreak.endedAt == uphill.first?.recordedAt)
        #expect(continuityBreak.reason == .sourceBoundary)
        #expect(try await persistedResults(url) == [result])
        let reopened = try await ActivityRepository.open(url: url, commit: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let cached = ActivityProcessor(repository: reopened, calculate: { _ in throw ActivityProcessingError.thumbnail })
        #expect(try await cached.process(id: summary.id) == result)
    }

    @Test func statisticsAndPNGSurviveReopenWithoutAnotherWrite() async throws {
        let url = try processingURL()
        let commit = ProcessingCommit()
        let repository = try await ActivityRepository.open(url: url, clock: { 50_000 }, commit: commit.save)
        let imported = try await repository.importTracks([processingTrack])
        let summary = try #require(imported.imported.first)
        let processor = ActivityProcessor(repository: repository, clock: { 50_000 })
        let saves = commit.saves
        async let first = processor.process(id: summary.id)
        async let second = processor.process(id: summary.id)
        let (result, concurrent) = try await (first, second)
        #expect(result == concurrent)
        #expect(commit.saves == saves + 1)
        #expect(result.processedAt == 50_000)
        #expect(result.processingVersion == ActivityAnalysis.currentProcessingVersion)
        #expect(result.thumbnailPNG?.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) == true)
        #expect(result.statistics.distanceMeters > 0)
        #expect(result.statistics.elevationGainMeters == 10)
        #expect(result.statistics.averageRunSteepnessPercent == nil)
        #expect(result.statistics.maximumRunSteepnessPercent == nil)
        #expect(try await persistedResults(url) == [result])

        let reopened = try await ActivityRepository.open(url: url, clock: { 99_000 }, commit: { _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        let reopenedProcessor = ActivityProcessor(repository: reopened)
        #expect(try await reopenedProcessor.process(id: summary.id) == result)
        #expect(try await reopened.details(id: summary.id).activity == summary)
        #expect(try await reopened.recordedTrack(id: summary.id).gpx == processingTrack)
        #expect(try await reopened.summaries() == [summary])
    }

    @Test func failedProcessingCommitRemainsRetryableAndDoesNotBlockRecording() async throws {
        let url = try processingURL()
        let commit = ProcessingCommit()
        let repository = try await ActivityRepository.open(url: url, clock: { 1_000 }, commit: commit.save)
        let summary = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let processor = ActivityProcessor(repository: repository)
        commit.failNext()
        await #expect(throws: CocoaError.self) { try await processor.process(id: summary.id) }
        #expect(try await persistedResults(url).isEmpty)
        #expect(try await repository.summaries() == [summary])
        #expect(try await repository.recordedTrack(id: summary.id).gpx == processingTrack)
        let active = try await repository.start()
        _ = try await repository.append([processingTrack.segments[0].points[0]], activityID: active.id)
        let retry = try await processor.process(id: summary.id)
        #expect(retry.thumbnailPNG != nil)
        #expect(try await persistedResults(url) == [retry])
        #expect(try await repository.active()?.summary.pointCount == 1)
    }

    @Test func olderProcessingVersionIsReplacedAtomicallyAndDeletedWithItsActivity() async throws {
        let url = try processingURL()
        let repository = try await ActivityRepository.open(url: url, clock: { 50_000 })
        let summary = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let stale = ActivityAnalysis(activityID: summary.id, sourceRevision: summary.sourceRevision, processingVersion: ActivityAnalysis.currentProcessingVersion - 1, processedAt: 10,
                                     statistics: ActivityStatistics(),
                                     thumbnailPNG: Data([0]))
        try await Task.detached {
            let context = ModelContext(try ActivityDatabase.container(at: url))
            let activity = try #require(context.fetch(FetchDescriptor<StoredActivity>()).first)
            context.insert(try StoredActivityAnalysis(stale, activity: activity))
            try context.save()
        }.value
        let commit = ProcessingCommit()
        let reopened = try await ActivityRepository.open(url: url, clock: { 60_000 }, commit: commit.save)
        let reopenedProcessor = ActivityProcessor(repository: reopened, clock: { 60_000 })
        commit.failNext()
        await #expect(throws: CocoaError.self) { try await reopenedProcessor.process(id: summary.id) }
        #expect(try await persistedResults(url) == [stale])
        let updated = try await reopenedProcessor.process(id: summary.id)
        #expect(updated.processingVersion == ActivityAnalysis.currentProcessingVersion)
        #expect(updated.processedAt == 60_000)
        #expect(updated.statistics.distanceMeters > 0)
        #expect(try await persistedResults(url) == [updated])
        #expect(try await reopened.recordedTrack(id: summary.id).gpx == processingTrack)
        try await reopened.delete(id: summary.id)
        #expect(try await persistedResults(url).isEmpty)
        await #expect(throws: ActivityError.self) { try await reopenedProcessor.process(id: summary.id) }
        #expect(try await reopened.summaries().isEmpty)
    }

    @Test @MainActor func savingAndImportingProcessWithoutOpeningActivityViews() async throws {
        let url = try processingURL()
        let repository = try await ActivityRepository.open(url: url, clock: { 1_000 })
        let store = RecordingController(repository: repository)
        let library = ActivityLibrary(repository: repository)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        await library.reloadHistory()
        await store.startRecording()
        store.record([try! TrackPoint(timestampMilliseconds: 1_000, latitude: 47, longitude: 11, elevationMeters: 2_000)])
        await store.stopRecording()
        await store.finishRecording()
        await library.processingTask?.value
        let saved = try #require(try await repository.summaries().first)
        #expect(try await persistedResults(url).map(\.activityID) == [saved.id])
        #expect(library.processingFailures.isEmpty)
        let imported = try #require(try await library.importTracks([processingTrack]).imported.first)
        await library.processingTask?.value
        let results = try await persistedResults(url)
        #expect(Set(results.map(\.activityID)) == Set([saved.id, imported.id]))
        #expect(results.allSatisfy { $0.thumbnailPNG != nil })
        #expect(store.storageError == nil)
    }

    @Test @MainActor func historyRefreshRetriesProcessingFailureWithoutAffectingRecording() async throws {
        let url = try processingURL()
        let commit = ProcessingCommit()
        let repository = try await ActivityRepository.open(url: url, clock: { 1_000 }, commit: commit.save)
        let saved = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let active = try await repository.start()
        let store = RecordingController(repository: repository)
        let library = ActivityLibrary(repository: repository)
        store.onCompleted = { activity in await library.didComplete(activity) }
        library.onStorageFailure = { error in store.reportStorageFailure(error) }
        try await store.restore()
        commit.failNext()
        await library.reloadHistory()
        await library.processingTask?.value
        #expect(library.processingFailures[saved.id] != nil)
        #expect(store.storageError == nil)
        #expect(store.recordingState == .recording)
        #expect(try await persistedResults(url).isEmpty)
        await library.reloadHistory()
        await library.processingTask?.value
        #expect(library.processingFailures.isEmpty)
        #expect(try await persistedResults(url).map(\.activityID) == [saved.id])
        #expect(try await repository.active() == active)
    }

    @Test func processingFailureLeavesOriginalDetailsAvailable() async throws {
        let repository = try await ActivityRepository.open(url: processingURL())
        let saved = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let processor = ActivityProcessor(repository: repository, calculate: { _ in throw ActivityProcessingError.thumbnail })
        await #expect(throws: ActivityProcessingError.self) { try await processor.process(id: saved.id) }
        let details = try await repository.details(id: saved.id)
        #expect(details.activity == saved)
        #expect(details.geometry.sections.flatMap(\.points) == processingTrack.segments.flatMap(\.points))
        #expect(try await repository.storedAnalysis(id: saved.id) == nil)
    }

    @Test func deletionDuringProcessingCannotRecreateAnActivity() async throws {
        let url = try processingURL()
        let repository = try await ActivityRepository.open(url: url)
        let saved = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let gate = CalculationGate()
        let processor = ActivityProcessor(repository: repository, calculate: { _ in
            await gate.suspend()
            return (ActivityStatistics(), Data([1]), .init(), .init())
        })
        let processing = Task { try await processor.process(id: saved.id) }
        await gate.waitUntilStarted()
        try await repository.delete(id: saved.id)
        await gate.release()
        do { _ = try await processing.value; Issue.record("Deleted activity accepted late analysis") }
        catch { #expect(error is ActivityError) }
        #expect(try await repository.summaries().isEmpty)
        #expect(try await persistedResults(url).isEmpty)
    }

    @Test func wrongSourceRevisionCannotReplaceCommittedAnalysis() async throws {
        let repository = try await ActivityRepository.open(url: processingURL())
        let saved = try #require(try await repository.importTracks([processingTrack]).imported.first)
        let original = try await ActivityProcessor(repository: repository).process(id: saved.id)
        let stale = ActivityAnalysis(activityID: saved.id, sourceRevision: saved.sourceRevision - 1,
            processingVersion: ActivityAnalysis.currentProcessingVersion, processedAt: 1, statistics: ActivityStatistics(), thumbnailPNG: nil)
        await #expect(throws: ActivityError.self) { try await repository.saveAnalysis(stale) }
        #expect(try await repository.storedAnalysis(id: saved.id) == original)
    }

    @Test func emptyCompletedActivityHasPersistedStatisticsWithoutPNG() async throws {
        let url = try processingURL()
        let repository = try await ActivityRepository.open(url: url, clock: { 1_000 })
        let active = try await repository.start()
        _ = try await repository.stop(id: active.id)
        _ = try await repository.finish(id: active.id)
        let processor = ActivityProcessor(repository: repository)
        let result = try await processor.process(id: active.id)
        #expect(result.thumbnailPNG == nil)
        #expect(result.statistics.elapsedDurationMilliseconds == 0)
        #expect(result.timeline == ActivityTimeline())
        #expect(result.isCurrent(for: try await repository.summary(id: active.id)))
        #expect(try await persistedResults(url) == [result])
    }
}

private actor CalculationGate {
    private var started = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var calculation: CheckedContinuation<Void, Never>?
    func suspend() async {
        started = true; waiting?.resume(); waiting = nil
        await withCheckedContinuation { calculation = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { calculation?.resume(); calculation = nil }
}
