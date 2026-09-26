#if DEBUG
import Foundation
import SwiftUI

/// UI tests exercise the real repository in a new temporary directory on every
/// launch. They never open, seed, migrate or remove the user's activity store.
enum UITestFixture {
    static var isReference: Bool {
        ["native-controls", "native-sheet", "live-summary"].contains(scenario ?? "")
    }
    static var scenario: String? {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return nil }
        return ProcessInfo.processInfo.environment["SUNOH_UI_SCENARIO"] ?? "populated"
    }

    static func repository() async throws -> ActivityRepository {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try await ActivityRepository.open(url: directory.appendingPathComponent("Activities.store"))
        if scenario != "empty" {
            let start: Int64 = 1_784_937_600_000
            var tracks: [GPXTrack] = []
            let offsets: [Int64] = ["timeline", "ski-matching", "lift-detection"].contains(scenario ?? "") ? [0] : [0, 86_400_000, 3_024_000_000]
            for offset in offsets {
                if scenario == "lift-detection" {
                    tracks.append(try liftDetectionTrack(start: start - offset))
                    continue
                }
                if scenario == "timeline" || scenario == "ski-matching" {
                    tracks.append(try timelineTrack(start: start - offset))
                    continue
                }
                if scenario == "classified-map" {
                    tracks.append(try classifiedMapTrack(start: start - offset))
                    continue
                }
                var points: [TrackPoint] = []
                if scenario == "ski-session" {
                    var seconds = 0.0, north = 0.0, elevation = 2_000.0
                    for phase in 0..<5 {
                        let uphill = phase % 2 == 1
                        let duration = uphill ? 180 : 120
                        for _ in 0..<duration / 5 {
                            points.append(try TrackPoint(timestampMilliseconds: start - offset + Int64(seconds * 1_000),
                                latitude: 47 + north / 111_195, longitude: 11, elevationMeters: elevation))
                            seconds += 5
                            north += uphill ? 15 : 40
                            elevation += (uphill ? 250.0 / 180 : -250.0 / 120) * 5
                        }
                    }
                    points.append(try TrackPoint(timestampMilliseconds: start - offset + Int64(seconds * 1_000),
                        latitude: 47 + north / 111_195, longitude: 11, elevationMeters: elevation))
                    tracks.append(GPXTrack(segments: [GPXSegment(points: points)]))
                    continue
                }
                for index in 0..<30 {
                    let point = try TrackPoint(timestampMilliseconds: start - offset + Int64(index) * 10_000,
                                               latitude: 47 + Double(index) / 10_000,
                                               longitude: 11 + Double(index % 5) / 10_000,
                                               elevationMeters: scenario == "no-elevation" ? nil : 2_000 - Double(index * 10))
                    points.append(point)
                }
                tracks.append(GPXTrack(segments: [GPXSegment(points: points)]))
            }
            _ = try await repository.importTracks(tracks)
            if scenario == "ski-matching" { try await addSkiMatchingFixture(to: repository) }
            if scenario == "lift-detection" { try await addLiftDetectionFixture(to: repository) }
        }
        if scenario == "paused" || scenario == "recording" {
            let recording = try await repository.start()
            let point = try TrackPoint(timestampMilliseconds: recording.summary.startedAt.millisecondsSince1970,
                                       latitude: 47, longitude: 11, elevationMeters: 2_000)
            _ = try await repository.append([point], activityID: recording.id)
            if scenario == "paused" { _ = try await repository.pause(id: recording.id) }
        }
        return repository
    }

    private static func addSkiMatchingFixture(to repository: ActivityRepository) async throws {
        guard let activity = try await repository.summaries().first else { return }
        let input = try await repository.processingInput(id: activity.id)
        let geometry = TrackContinuityPolicy.geometry(for: input.track)
        let result = try await ActivityProcessor(repository: repository).process(id: activity.id)
        guard var timeline = result.timeline, let points = geometry.sections.first?.points else { return }
        let origin = activity.startedAt.millisecondsSince1970
        let north = SkiResort(id: "fixture-north", name: "North Peak", sources: [.init(type: "fixture", id: "north")])
        let south = SkiResort(id: "fixture-south", name: "South Bowl", sources: [.init(type: "fixture", id: "south")])
        let group = SkiResort(id: "fixture-group", name: "Valley Pass", sources: [.init(type: "fixture", id: "group")])
        func feature(_ id: String, kind: ActivityTimelineKind, from: Int64, to: Int64, resorts: [SkiResort]) -> SkiFeature {
            let coordinates = points.filter { (origin + from * 1_000...origin + to * 1_000).contains($0.timestampMilliseconds) }.map(\.coordinate)
            return SkiFeature(identity: SkiFeatureIdentity(id: id, kind: kind,
                sources: [.init(type: "fixture", id: id)], resorts: resorts), coordinates: coordinates)
        }
        let features = [
            feature("fixture-run-1a", kind: .run, from: 20, to: 70, resorts: [north, group]),
            feature("fixture-run-1b", kind: .run, from: 70, to: 100, resorts: [north, group]),
            feature("fixture-run-2", kind: .run, from: 100, to: 220, resorts: [south, group]),
            feature("fixture-lift-1", kind: .lift, from: 220, to: 400, resorts: [south, group])
        ]
        timeline.skiMatches = SkiFeatureMatcher.match(geometry: geometry, timeline: timeline, features: features, datasetVersion: "ui-fixture")
        // Legacy piste results must remain hidden even if a view receives an older snapshot.
        if let matching = timeline.skiMatches, let firstRun = timeline.entries.first, !matching.entries.isEmpty {
            var entries = matching.entries
            entries[0] = features.filter { $0.identity.kind == .run }.map {
                SkiFeatureMatch(feature: $0.identity, startedAt: firstRun.startedAt,
                    endedAt: firstRun.endedAt, confidence: 1)
            }
            timeline.skiMatches = SkiTimelineMatches(datasetVersion: matching.datasetVersion,
                entries: entries, resorts: matching.resorts)
        }
        try await repository.saveAnalysis(ActivityAnalysis(activityID: activity.id, sourceRevision: activity.sourceRevision,
            processingVersion: ActivityAnalysis.currentProcessingVersion, processedAt: result.processedAt,
            statistics: result.statistics, thumbnailPNG: result.thumbnailPNG, passages: result.passages, timeline: timeline))
    }

    private static func liftDetectionTrack(start: Int64) throws -> GPXTrack {
        let points = try stride(from: 0, through: 600, by: 5).map { seconds in
            let east: Double
            let north: Double
            let elevation: Double
            if seconds <= 120 {
                east = -960 + Double(seconds) * 8
                north = 0
                elevation = 2_000 - Double(seconds) * 250 / 120
            } else if seconds <= 480 {
                let elapsed = Double(seconds - 120)
                east = 0
                north = elapsed * 3
                if elapsed <= 120 {
                    elevation = 1_750 + elapsed * 200 / 120
                } else if elapsed <= 240 {
                    elevation = 1_950
                } else if elapsed <= 270 {
                    elevation = 1_950 - (elapsed - 240) * 15 / 30
                } else {
                    elevation = 1_935 + (elapsed - 270) * 115 / 90
                }
            } else {
                east = Double(seconds - 480) * 8
                north = 1_080
                elevation = 2_050 - Double(seconds - 480) * 250 / 120
            }
            return try TrackPoint(timestampMilliseconds: start + Int64(seconds) * 1_000,
                                  latitude: 47 + north / 111_195,
                                  longitude: 11 + east / (111_195 * cos(47 * .pi / 180)),
                                  elevationMeters: elevation)
        }
        return GPXTrack(segments: [GPXSegment(points: points)])
    }

    private static func addLiftDetectionFixture(to repository: ActivityRepository) async throws {
        guard let activity = try await repository.summaries().first else { return }
        let input = try await repository.processingInput(id: activity.id)
        let geometry = TrackContinuityPolicy.geometry(for: input.track)
        let start = activity.startedAt.millisecondsSince1970
        let ride = (start + 120_000)...(start + 480_000)
        let coordinates = geometry.sections.flatMap(\.points).filter { ride.contains($0.timestampMilliseconds) }.map(\.coordinate)
        let resort = SkiResort(id: "fixture-plateau", name: "Plateau Mountain", sources: [.init(type: "fixture", id: "plateau")])
        let lift = SkiFeature(identity: SkiFeatureIdentity(id: "fixture-plateau-express", kind: .lift,
            sources: [.init(type: "fixture", id: "plateau-express")], resorts: [resort]), coordinates: coordinates)
        let processor = ActivityProcessor(repository: repository, referenceData: { _ in
            SkiDataCatalog.ReferenceData(datasetVersion: "ui-lift-detection", features: [lift])
        })
        _ = try await processor.process(id: activity.id, force: true)
    }

    private static func timelineTrack(start: Int64) throws -> GPXTrack {
        func point(seconds: Int, east: Double, north: Double, elevation: Double) throws -> TrackPoint {
            try TrackPoint(timestampMilliseconds: start + Int64(seconds) * 1_000,
                           latitude: 47 + north / 111_195,
                           longitude: 11 + east / (111_195 * cos(47 * .pi / 180)),
                           elevationMeters: elevation)
        }

        var first: [TrackPoint] = []
        for index in 0...4 {
            first.append(try point(seconds: index * 5, east: 0, north: 0, elevation: 2_000))
        }
        for index in 1...4 {
            first.append(try point(seconds: 20 + index * 5, east: 0, north: Double(index) * 10, elevation: 2_000))
        }
        for index in 1...60 {
            first.append(try point(seconds: 40 + index, east: 0, north: 40 + Double(index) * 8,
                                   elevation: 2_000 - Double(index) * 125 / 60))
        }
        for index in 1...4 {
            first.append(try point(seconds: 100 + index * 5, east: 0, north: 520, elevation: 1_875))
        }
        for index in 1...4 {
            first.append(try point(seconds: 120 + index * 15, east: 0, north: 520 + Double(index) * 120,
                                   elevation: 1_875 - Double(index) * 125 / 4))
        }
        for index in 1...4 {
            first.append(try point(seconds: 180 + index * 5, east: 0, north: 1_000, elevation: 1_750))
        }
        for index in 1...4 {
            first.append(try point(seconds: 200 + index * 5, east: 0, north: 1_000 + Double(index) * 10, elevation: 1_750))
        }
        for index in 1...9 {
            first.append(try point(seconds: 220 + index * 20, east: 0, north: 1_040 + Double(index) * 60,
                                   elevation: 1_750 + Double(index) * 250 / 9))
        }
        for index in 1...12 {
            first.append(try point(seconds: 400 + index * 5, east: Double(index) * 10, north: 1_580, elevation: 2_000))
        }
        var second = try (0...12).map { index in
            try point(seconds: 520 + index * 5, east: 240 + Double(index) * 10, north: 1_580, elevation: 2_000)
        }
        second.append(try point(seconds: 640, east: 480, north: 1_580, elevation: 2_000))
        return GPXTrack(segments: [GPXSegment(points: first), GPXSegment(points: second)])
    }

    private static func classifiedMapTrack(start: Int64) throws -> GPXTrack {
        func point(seconds: Int, east: Double, north: Double, elevation: Double) throws -> TrackPoint {
            try TrackPoint(timestampMilliseconds: start + Int64(seconds) * 1_000,
                           latitude: 47 + north / 111_195,
                           longitude: 11 + east / (111_195 * cos(47 * .pi / 180)),
                           elevationMeters: elevation)
        }

        var skiing: [TrackPoint] = []
        for index in 0...36 {
            skiing.append(try point(seconds: index * 5, east: 0, north: Double(index) * 15,
                                   elevation: 1_600 + Double(index) * 250 / 36))
        }
        for index in 1...24 {
            skiing.append(try point(seconds: 180 + index * 5, east: Double(index) * 30,
                                   north: 540 - Double(index) * 22.5, elevation: 1_850 - Double(index) * 250 / 24))
        }

        var traverses: [TrackPoint] = []
        for index in 0...24 {
            traverses.append(try point(seconds: 360 + index * 5, east: 300 + Double(index) * 10,
                                      north: -180, elevation: 1_600))
        }
        for index in 0...24 {
            traverses.append(try point(seconds: 600 + index * 5, east: 780,
                                      north: -180 + Double(index) * 10, elevation: 1_600))
        }
        let isolated = try point(seconds: 780, east: 300, north: 420, elevation: 1_800)
        return GPXTrack(segments: [GPXSegment(points: skiing), GPXSegment(points: traverses), GPXSegment(points: [isolated])])
    }
}

/// An unmodified native control reference used to distinguish SDK audit failures
/// from constraints introduced by the app.
struct NativeControlsAuditView: View {
    @State private var showSheet = false
    var body: some View {
        NavigationStack {
            Form {
                if UITestFixture.scenario == "live-summary" {
                    ForEach([RecordingActivityAttributes.Phase.recording, .paused, .blocked], id: \.self) { phase in
                        RecordingActivitySummary(state: .init(pointCount: 123_456, phase: phase,
                                                              startedAt: .now.addingTimeInterval(-360_000), lastPointAt: .now))
                    }
                    RecordingActivitySummary(state: .init(pointCount: 0, phase: .recording))
                } else {
                    Button {} label: { Label("Import GPX", systemImage: "square.and.arrow.down") }
                    Button {} label: { Label("Export all", systemImage: "square.and.arrow.up") }
                }
            }
            .navigationTitle("Native controls")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { showSheet = UITestFixture.scenario == "native-sheet" }
            .sheet(isPresented: $showSheet) {
                VStack(alignment: .leading) {
                    Text("Native sheet title").font(.headline)
                    Text("Native sheet subtitle").font(.subheadline)
                }
                .padding()
                .presentationDetents([.fraction(0.15), .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}
#endif
