import SwiftUI

struct ActivityOverviewView: View {
    let activityID: ActivityID
    let library: ActivityLibrary

    @Environment(\.dismiss) private var dismiss
    private enum Deletion: Equatable {
        case idle, confirming, deleting, failed(String)
    }

    @Namespace private var mapTransition
    @State private var content: LoadState<ActivityDetails> = .loading
    @State private var analysis: ActivityAnalysis?
    @State private var analysisFailed = false
    @State private var showFullScreenMap = false
    @State private var deletion: Deletion = .idle

    var body: some View {
        Group {
            switch content {
            case .loading:
                ScrollableStatus { ProgressView("Loading activity…") }
            case .failed(let error):
                ScrollableStatus {
                    ContentUnavailableView {
                        Label("Unable to Load Activity", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { content = .loading }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                }
            case .loaded(let details):
                ScrollView {
                    VStack(alignment: .leading) {
                        Button {
                            showFullScreenMap = true
                        } label: {
                            InspectMapView(geometry: details.geometry,
                                           passages: analysis?.isCurrent(for: details.activity) == true ? analysis?.passages : nil)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(.rect(cornerRadius: 20))
                                .contentShape(.rect(cornerRadius: 20))
                        }
                        .buttonStyle(.plain)
                        .matchedTransitionSource(id: "activity-map", in: mapTransition) { source in
                            source.clipShape(.rect(cornerRadius: 20))
                        }
                        .accessibilityLabel("Open full screen activity map")
                        .accessibilityIdentifier("open-activity-map")

                        ActivityElevationProfile(geometry: details.geometry)
                            .aspectRatio(4, contentMode: .fit)
                        ActivityAnalysisView(activityID: activityID, library: library, onAnalysis: {
                            analysis = $0
                            analysisFailed = false
                        }, onFailure: { _ in analysisFailed = true })
                    }
                    .padding()
                }
                .accessibilityIdentifier("activity-overview-scroll")
                .safeAreaInset(edge: .bottom) {
                    VStack {
                        Divider()
                        HStack {
                            GPXExportButton(activityID: activityID, library: library)
                                .disabled(details.activity.pointCount == 0)
                            Button(role: .destructive) { deletion = .confirming } label: {
                                Label("Delete Activity", systemImage: "trash")
                            }
                            .tint(.red)
                            .accessibilityIdentifier("delete-activity")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding([.horizontal, .bottom])
                    }
                    .background(.background)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            VStack {
                HStack {
                    MapSheetCloseButton(label: "Close activity", hint: "Returns to activities",
                                        identifier: "close-activity-overview") { dismiss() }
                    if case .loaded(let details) = content {
                        ActivityHeading(activity: details.activity, analysis: analysis, processingFailed: analysisFailed)
                    } else {
                        Text("Activity").font(.headline)
                        Spacer()
                    }
                }
                .padding()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("activity-overview-header")
                Divider()
            }
            .background(.background)
        }
        .disabled(deletion == .deleting)
        .interactiveDismissDisabled(deletion == .deleting)
        .alert("Delete Activity?", isPresented: Binding(
            get: { deletion == .confirming },
            set: { if !$0 && deletion == .confirming { deletion = .idle } }
        )) {
            Button("Delete", role: .destructive) { Task { await deleteActivity() } }
            Button("Cancel", role: .cancel) { deletion = .idle }
        } message: {
            Text("This activity and all its recorded points will be permanently deleted.")
        }
        .alert("Unable to Delete Activity", isPresented: Binding(
            get: { if case .failed = deletion { return true }; return false },
            set: { if !$0, case .failed = deletion { deletion = .idle } }
        )) {
            Button("OK", role: .cancel) { deletion = .idle }
        } message: {
            if case .failed(let error) = deletion { Text(error) }
        }
        .fullScreenCover(isPresented: $showFullScreenMap) {
            ActivityDetailView(activityID: activityID, library: library)
                .navigationTransition(.zoom(sourceID: "activity-map", in: mapTransition))
        }
        .task(id: content.isLoading) {
            guard content.isLoading else { return }
            do {
                let details = try await library.details(id: activityID)
                guard !Task.isCancelled else { return }
                content = .loaded(details)
            } catch {
                guard !Task.isCancelled else { return }
                content = .failed(error.localizedDescription)
            }
        }
    }

    private func deleteActivity() async {
        guard deletion != .deleting else { return }
        deletion = .deleting
        do {
            try await library.delete(id: activityID)
            dismiss()
        } catch {
            deletion = .failed(error.localizedDescription)
        }
    }
}
