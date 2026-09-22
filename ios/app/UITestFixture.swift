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
            for offset: Int64 in [0, 86_400_000, 3_024_000_000] {
                var points: [TrackPoint] = []
                for index in 0..<30 {
                    let point = try TrackPoint(timestampMilliseconds: start - offset + Int64(index) * 10_000,
                                               latitude: 47 + Double(index) / 10_000,
                                               longitude: 11 + Double(index % 5) / 10_000,
                                               elevationMeters: 2_000 - Double(index * 10))
                    points.append(point)
                }
                tracks.append(GPXTrack(segments: [GPXSegment(points: points)]))
            }
            _ = try await repository.importTracks(tracks)
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
                    Button {} label: { Label("Export All", systemImage: "square.and.arrow.up") }
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
