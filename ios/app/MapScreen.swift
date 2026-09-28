import SwiftUI

struct MapScreen: View {
    let tracker: LocationTracker
    let recorder: RecordingController

    @Namespace private var mapTransition
    @State private var map = MapViewStore()
    @State private var showFullScreenMap = false

    private var status: RecordingStatus {
        recorder.recordingStatus.withLocationReadiness(tracker.isLocationReady)
    }

    var body: some View {
        ScrollView {
            VStack {
                HStack {
                    RecordingStatusIcon(status: status)
                    Text(status.label)
                        .accessibilityIdentifier("map-recording-status")
                }
                .frame(maxWidth: .infinity)

                Button {
                    showFullScreenMap = true
                } label: {
                    RecordMapView(tracker: tracker, recorder: recorder, map: map)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 20))
                        .contentShape(.rect(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: "live-map", in: mapTransition) { source in
                    source.clipShape(.rect(cornerRadius: 20))
                }
                .accessibilityLabel("Open full screen map")
                .accessibilityIdentifier("open-live-map")
                .padding(.horizontal)

                RecordControls(tracker: tracker, recorder: recorder)
            }
            .padding(.vertical)
        }
        .fullScreenCover(isPresented: $showFullScreenMap) {
            FullScreenLiveMap(tracker: tracker, recorder: recorder)
                .navigationTransition(.zoom(sourceID: "live-map", in: mapTransition))
        }
    }
}

private struct FullScreenLiveMap: View {
    let tracker: LocationTracker
    let recorder: RecordingController

    @Environment(\.dismiss) private var dismiss
    @State private var map = MapViewStore()
    @State private var showDetails = false

    var body: some View {
        ZStack {
            RecordMapView(tracker: tracker, recorder: recorder, map: map)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            MapSheetCloseButton(label: "Close full screen map", hint: "Returns to Live",
                                identifier: "close-live-map", action: { dismiss() })
                .padding()
        }
        .onAppear { showDetails = true }
        .sheet(isPresented: $showDetails) {
            MapDetailsSheet {
                LiveMapSheetHeader(
                    status: recorder.recordingStatus.withLocationReadiness(tracker.isLocationReady),
                    recorder: recorder
                )
            } details: {
                LiveMapRecordingDetails(recorder: recorder)
            }
            .tint(.black)
        }
    }
}

private struct LiveMapSheetHeader: View {
    let status: RecordingStatus
    let recorder: RecordingController

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                statusIcon
                summary.fixedSize()
            }
            .fixedSize()

            VStack {
                HStack {
                    statusIcon
                    Spacer()
                }
                summary
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusIcon: some View {
        RecordingStatusIcon(status: status)
            .accessibilityIdentifier("live-recording-status")
    }

    private var summary: some View {
        StatisticsGrid(metrics: [
            .init(label: "Elapsed time", value: elapsed),
            .init(label: "Saved points", value: recorder.pointCount.formatted())
        ], maximumColumns: 2)
    }

    private var elapsed: String {
        guard let activity = recorder.currentActivity else { return "—" }
        let milliseconds = max(0, (activity.lastPointAt ?? activity.startedAt).millisecondsSince1970
                               - activity.startedAt.millisecondsSince1970)
        return Duration.milliseconds(milliseconds).formatted(.time(pattern: .hourMinuteSecond))
    }
}

private struct LiveMapRecordingDetails: View {
    let recorder: RecordingController

    var body: some View {
        StatisticsGrid(metrics: metrics, maximumColumns: 2)
    }

    private var metrics: [StatisticsGrid.Metric] {
        let activity = recorder.currentActivity
        let geometry = recorder.geometryValue.flatMap { $0.activityID == activity?.id ? $0 : nil }
        let statistics = activity.flatMap { activity in
            geometry.map { ActivityStatistics(activity: activity, geometry: $0) }
        }
        let currentElevation = geometry?.sections.last?.points.last?.elevationMeters
        let hasElevation = statistics?.maximumElevationMeters != nil
        return [
            .init(label: "Distance", value: statistics?.formattedDistance ?? "—"),
            .init(label: "Current elevation", value: elevation(currentElevation)),
            .init(label: "Ascent", value: elevation(hasElevation ? statistics?.elevationGainMeters : nil)),
            .init(label: "Descent", value: elevation(hasElevation ? statistics?.elevationLossMeters : nil))
        ]
    }

    private func elevation(_ meters: Double?) -> String {
        guard let meters else { return "—" }
        return "\(meters.rounded(.towardZero).formatted(.number.precision(.fractionLength(0)))) m"
    }
}
