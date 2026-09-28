import SwiftUI

struct MapScreen: View {
    let tracker: LocationTracker
    let recorder: RecordingController

    @Namespace private var mapTransition
    @State private var map = MapViewStore()
    @State private var showFullScreenMap = false

    var body: some View {
        ScrollView {
            VStack {
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
        .onChange(of: recorder.currentActivity != nil, initial: true) { _, hasActivity in
            showDetails = hasActivity
        }
        .sheet(isPresented: $showDetails) {
            MapDetailsSheet(hasDetails: recorder.currentActivity != nil) {
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
                summary
            }
            .fixedSize()

            VStack {
                summary
            }
        }
        .font(.title3.weight(.medium))
        .monospacedDigit()
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var summary: some View {
        if recorder.currentActivity != nil {
            RecordingStatusIcon(status: status)
                .accessibilityIdentifier("live-recording-status")
            Text(elapsed)
                .accessibilityLabel("Duration")
                .accessibilityValue(elapsed)
                .accessibilityIdentifier("live-duration")
        }
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
        ViewThatFits(in: .horizontal) {
            HStack {
                metrics
            }
            .fixedSize()

            VStack {
                metrics
            }
        }
        .font(.subheadline.weight(.medium))
        .monospacedDigit()
        .frame(maxWidth: .infinity)
    }

    private var statistics: ActivityStatistics? {
        let activity = recorder.currentActivity
        let geometry = recorder.geometryValue.flatMap { $0.activityID == activity?.id ? $0 : nil }
        return activity.flatMap { activity in
            geometry.map { ActivityStatistics(activity: activity, geometry: $0) }
        }
    }

    @ViewBuilder
    private var metrics: some View {
        let statistics = statistics
        let hasElevation = statistics?.maximumElevationMeters != nil
        metric("Distance", symbol: "arrow.left.and.right", value: statistics?.formattedDistance ?? "—")
        metric("Ascent", symbol: "arrow.up", value: elevation(hasElevation ? statistics?.elevationGainMeters : nil))
        metric("Descent", symbol: "arrow.down", value: elevation(hasElevation ? statistics?.elevationLossMeters : nil))
    }

    private func metric(_ label: String, symbol: String, value: String) -> some View {
        Label(value, systemImage: symbol)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityIdentifier("live-\(label.lowercased())")
    }

    private func elevation(_ meters: Double?) -> String {
        guard let meters else { return "—" }
        return "\(meters.rounded(.towardZero).formatted(.number.precision(.fractionLength(0)))) m"
    }
}
