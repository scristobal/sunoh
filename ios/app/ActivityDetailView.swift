import SwiftUI

// MARK: - Activity detail

struct ActivityDetailView: View {
    let activityID: ActivityID
    let library: ActivityLibrary

    @Environment(\.dismiss) private var dismiss
    @State private var content: LoadState<ActivityDetails> = .loading
    @State private var analysis: ActivityAnalysis?
    @State private var analysisError: String?
    @State private var isProcessing = false
    @State private var analysisRequest = 0
    @State private var forceAnalysis = false
    @State private var selection = 0
    @State private var sheetPresentation = ActivitySheetPresentation()
    @State private var showDetails = false

    var body: some View {
        GeometryReader { geometry in
            Group {
                if case .loaded(let details) = content {
                    InspectMapView(geometry: displayedGeometry(from: details),
                                   passages: currentAnalysis(for: details)?.passages,
                                   maximumZoomLevel: 16, obscuredBottom: sheetPresentation.height,
                                   safeTop: geometry.safeAreaInsets.top, contextPadding: 40,
                                   fliesToChanges: true)
                        .accessibilityIdentifier("activity-section-map")
                } else {
                    Color(uiColor: .systemBackground)
                }
            }
            .ignoresSafeArea()
        }
        .onAppear { showDetails = true }
        .sheet(isPresented: $showDetails) {
            details
                .tint(.black)
        }
        .task(id: content.isLoading) {
            if content.isLoading { await loadActivity() }
        }
        .task(id: analysisRequest) {
            if case .loaded = content { await loadAnalysis() }
        }
    }

    private var details: some View {
        ActivitySectionSheet {
            sheetHeader
        } details: {
            if let analysisError {
                VStack(alignment: .leading) {
                    Text(analysisError)
                    Button("Retry processing") { retryAnalysis() }
                }
            } else if isProcessing {
                ProgressView("Processing activity…")
            } else if let timeline = analysis?.timeline, case .loaded(let details) = content {
                VStack(alignment: .leading) {
                    if timeline.skiMatches?.failure != nil {
                        Button("Retry identification") { retryAnalysis() }
                    }
                    ActivitySectionView(timeline: timeline, geometry: details.geometry, selection: $selection)
                }
            }
        } onPresentationChange: { presentation in
            sheetPresentation = presentation
        }
    }

    @ViewBuilder
    private var sheetHeader: some View {
        switch content {
        case .loaded(let details):
            HStack {
                closeButton
                ActivityHeading(activity: details.activity, analysis: currentAnalysis(for: details),
                                processingFailed: analysisError != nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failed(let error):
            ContentUnavailableView {
                Label("Unable to Load Activity", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { content = .loading }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        case .loading:
            VStack(spacing: 16) {
                ProgressView("Loading activity…")
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
    }

    private var closeButton: some View {
        MapSheetCloseButton(label: "Close activity details", hint: "Returns to activity overview",
                            identifier: "close-activity-details", action: { dismiss() })
    }

    private func currentAnalysis(for details: ActivityDetails) -> ActivityAnalysis? {
        analysis?.isCurrent(for: details.activity) == true ? analysis : nil
    }

    private func displayedGeometry(from details: ActivityDetails) -> TrackGeometry {
        guard sheetPresentation.isExpanded,
              let timeline = currentAnalysis(for: details)?.timeline, !timeline.entries.isEmpty else {
            return details.geometry
        }
        let index = min(max(0, selection), timeline.entries.count - 1)
        return Geo.selectedGeometry(in: details.geometry, entry: timeline.entries[index])
    }

    private func retryAnalysis() {
        forceAnalysis = true
        analysisRequest += 1
    }

    private func loadActivity() async {
        do {
            let details = try await library.details(id: activityID)
            guard !Task.isCancelled else { return }
            content = .loaded(details)
            analysisRequest += 1
        } catch {
            guard !Task.isCancelled else { return }
            content = .failed(error.localizedDescription)
        }
    }

    private func loadAnalysis() async {
        let force = forceAnalysis
        forceAnalysis = false
        analysisError = nil
        isProcessing = true
        do {
            let result = try await library.analysis(id: activityID, force: force)
            guard !Task.isCancelled else { return }
            analysis = result
            let count = result.timeline?.entries.count ?? 0
            selection = min(max(0, selection), max(0, count - 1))
            isProcessing = false
        } catch {
            guard !Task.isCancelled else { return }
            analysisError = error.localizedDescription
            isProcessing = false
        }
    }
}
