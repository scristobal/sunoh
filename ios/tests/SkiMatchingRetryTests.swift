import Foundation
import Synchronization
import Testing
@testable import Sunoh

struct SkiMatchingRetryTests {
    @Test func identificationRetryRecalculatesAfterAnInflightCachedFailure() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let calculations = Mutex(0)
        let refreshedTimeline = fixture.refreshedTimeline
        let processor = ActivityProcessor(repository: fixture.controlled, calculate: { _ in
            calculations.withLock { $0 += 1 }
            return (ActivityStatistics(), Data([1]), .init(), refreshedTimeline)
        })
        await fixture.controlled.blockNextStoredAnalysis()
        let normal = Task { try await processor.process(id: fixture.activity.id) }
        await fixture.controlled.waitForStoredAnalysis()
        let retried = try await retryBeforeReleasingCache(id: fixture.activity.id, processor: processor, repository: fixture.controlled)
        #expect(try await normal.value == fixture.cached)
        #expect(retried.timeline?.skiMatches?.failure == nil)
        #expect(retried.timeline?.skiMatches?.datasetVersion == "recovered")
        #expect(calculations.withLock { $0 } == 1)
        #expect(try await fixture.repository.storedAnalysis(id: fixture.activity.id) == retried)
        #expect(try await fixture.repository.recordedTrack(id: fixture.activity.id).gpx == fixture.track)
    }

    @Test func concurrentIdentificationRetriesShareOneForcedCalculation() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let gate = RetryCalculationGate()
        let refreshedTimeline = fixture.refreshedTimeline
        let processor = ActivityProcessor(repository: fixture.controlled, calculate: { _ in
            await gate.suspend()
            return (ActivityStatistics(), Data([1]), .init(), refreshedTimeline)
        })
        let first = Task { try await processor.process(id: fixture.activity.id, force: true) }
        await gate.waitUntilStarted()
        let second = try await retryBeforeReleasingCalculation(id: fixture.activity.id, processor: processor, gate: gate)
        #expect(try await first.value == second)
        #expect(await gate.calls == 1)
        #expect(second.timeline?.skiMatches?.datasetVersion == "recovered")
        #expect(try await fixture.repository.recordedTrack(id: fixture.activity.id).gpx == fixture.track)
    }

    private struct Fixture {
        let directory: URL
        let repository: ActivityRepository
        let controlled: ControlledActivities
        let activity: ActivitySummary
        let track: GPXTrack
        let cached: ActivityAnalysis

        var refreshedTimeline: ActivityTimeline {
            var timeline = cached.timeline!
            timeline.skiMatches = SkiTimelineMatches(datasetVersion: "recovered", entries: [[]], resorts: [])
            return timeline
        }

        static func create() async throws -> Fixture {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let repository = try await ActivityRepository.open(url: directory.appendingPathComponent("retry.store"))
            let controlled = ControlledActivities(repository: repository, clock: ControlledClock())
            let points = try (0...3).map { index in
                try TrackPoint(timestampMilliseconds: Int64(index) * 1_000, latitude: 47 + Double(index) * 0.0001,
                               longitude: 11, elevationMeters: 2_000 - Double(index) * 5)
            }
            let track = GPXTrack(segments: [GPXSegment(points: points)])
            let activity = try #require(try await repository.importTracks([track]).imported.first)
            let geometry = try await repository.geometry(id: activity.id)
            var timeline = Geo.timeline(in: geometry, passages: .init())
            timeline.skiMatches = SkiTimelineMatches(datasetVersion: nil, entries: [[]], resorts: [], failure: "Reference data unavailable")
            let cached = ActivityAnalysis(activityID: activity.id, sourceRevision: activity.sourceRevision,
                processingVersion: ActivityAnalysis.currentProcessingVersion, processedAt: 1, statistics: ActivityStatistics(),
                thumbnailPNG: Data([1]), passages: .init(), timeline: timeline)
            #expect(cached.isCurrent(for: activity))
            try await repository.saveAnalysis(cached)
            return Fixture(directory: directory, repository: repository, controlled: controlled, activity: activity, track: track, cached: cached)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}

// Each release must enter the processor's actor, after the retry has suspended.
private func retryBeforeReleasingCache(id: ActivityID, processor: isolated ActivityProcessor, repository: ControlledActivities) async throws -> ActivityAnalysis {
    Task { await processor.releaseCacheForRetryTest(repository) }
    return try await processor.process(id: id, force: true)
}

private func retryBeforeReleasingCalculation(id: ActivityID, processor: isolated ActivityProcessor, gate: RetryCalculationGate) async throws -> ActivityAnalysis {
    Task { await processor.releaseCalculationForRetryTest(gate) }
    return try await processor.process(id: id, force: true)
}

private extension ActivityProcessor {
    func releaseCacheForRetryTest(_ repository: ControlledActivities) async { await repository.releaseStoredAnalysis() }
    func releaseCalculationForRetryTest(_ gate: RetryCalculationGate) async { await gate.release() }
}

private actor RetryCalculationGate {
    private(set) var calls = 0
    private var started: CheckedContinuation<Void, Never>?
    private var suspended: CheckedContinuation<Void, Never>?
    private var released = false

    func suspend() async {
        calls += 1
        started?.resume(); started = nil
        if released { return }
        await withCheckedContinuation { suspended = $0 }
    }

    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        released = true
        suspended?.resume(); suspended = nil
    }
}
