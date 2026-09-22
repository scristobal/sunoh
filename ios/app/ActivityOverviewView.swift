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
                    VStack(alignment: .leading, spacing: 20) {
                        Button {
                            showFullScreenMap = true
                        } label: {
                            InspectMapView(geometry: details.geometry)
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

                        VStack(alignment: .leading, spacing: 4) {
                            Text(details.activity.dateIntervalLabel)
                                .font(.headline)
                            Text("\(details.activity.pointCount) saved points")
                                .foregroundStyle(.primary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        ActivityAnalysisView(activityID: activityID, library: library)
                        Divider()
                        Button(role: .destructive) { deletion = .confirming } label: {
                            Label("Delete Activity", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .tint(.red)
                        .accessibilityIdentifier("delete-activity")
                    }
                    .padding(20)
                }
                .accessibilityIdentifier("activity-overview-scroll")
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { dismiss() }
                    .accessibilityLabel("Close activity")
                    .accessibilityHint("Returns to activities")
                    .accessibilityIdentifier("close-activity-overview")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if case .loaded(let details) = content {
                    GPXExportButton(activityID: activityID, library: library)
                        .labelStyle(.iconOnly)
                        .disabled(details.activity.pointCount == 0)
                }
            }
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
