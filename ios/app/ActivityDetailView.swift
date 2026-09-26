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

// The view formats measurements calculated by the activity processor.
extension ActivityStatistics {
    var formattedDuration: String {
        Self.duration(elapsedDurationMilliseconds)
    }

    var formattedRunDuration: String { Self.duration(runDurationMilliseconds) }
    var formattedRunDistance: String { Self.distance(runDistanceMeters) }
    var formattedLongestRunDistance: String { longestRunDistanceMeters.map(Self.distance) ?? "—" }
    var formattedMaximumRunSpeed: String { Self.speed(maximumRunSpeedMetersPerSecond) }
    var formattedAverageRunSteepness: String { Self.steepness(averageRunSteepnessPercent) }
    var formattedMaximumRunSteepness: String { Self.steepness(maximumRunSteepnessPercent) }

    private static func duration(_ milliseconds: Int64) -> String {
        let totalMinutes = milliseconds / 60_000
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var formattedDistance: String {
        Self.distance(distanceMeters)
    }

    var formattedAverageRunSpeed: String {
        Self.speed(averageDownhillSpeedMetersPerSecond)
    }

    static func distance(_ meters: Double) -> String {
        if meters >= 1_000 {
            return "\((meters / 1_000).formatted(.number.precision(.fractionLength(1)))) km"
        }
        return "\(meters.formatted(.number.precision(.fractionLength(0)))) m"
    }

    private static func speed(_ metersPerSecond: Double?) -> String {
        guard let speed = metersPerSecond else { return "—" }
        return "\((speed * 3.6).formatted(.number.precision(.fractionLength(1)))) km/h"
    }

    private static func steepness(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        return (percent / 100).formatted(.percent.precision(.fractionLength(1)))
    }
}

struct ActivityStatisticsView: View {
    let stats: ActivityStatistics

    var body: some View {
        VStack(alignment: .leading) {
            statisticsGroup("session", metrics: sessionMetrics)
            Divider()
            statisticsGroup("runs", metrics: runMetrics)
        }
    }

    private func statisticsGroup(_ identifier: String, metrics: [StatisticsGrid.Metric]) -> some View {
        Grid(alignment: .top) {
            ForEach(Array(stride(from: 0, to: metrics.count, by: 3)), id: \.self) { start in
                GridRow(alignment: .top) {
                    ForEach(metrics[start..<min(start + 3, metrics.count)]) { metric in
                        VStack {
                            Text(metric.value).font(.title3.weight(.semibold))
                            Text(metric.label).font(.caption)
                        }
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(metric.label)
                        .accessibilityValue(metric.value)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity-statistics-\(identifier)")
    }

    private var sessionMetrics: [StatisticsGrid.Metric] {
        [
            .init(label: "Duration", value: stats.formattedDuration),
            .init(label: "Distance", value: stats.formattedDistance),
            .init(label: "Descent", value: elevation(stats.elevationLossMeters))
        ]
    }

    private var runMetrics: [StatisticsGrid.Metric] {
        [
            .init(label: "Trips", value: stats.runCount.formatted()),
            .init(label: "Time", value: stats.formattedRunDuration),
            .init(label: "Distance", value: stats.formattedRunDistance),
            .init(label: "Descent", value: elevation(stats.runElevationLossMeters)),
            .init(label: "Speed", value: stats.formattedAverageRunSpeed),
            .init(label: "Top speed", value: stats.formattedMaximumRunSpeed),
            .init(label: "Tallest", value: stats.tallestRunHeightMeters.map(elevation) ?? "—"),
            .init(label: "Longest", value: stats.formattedLongestRunDistance),
            .init(label: "Steep", value: stats.formattedAverageRunSteepness),
            .init(label: "Steepest", value: stats.formattedMaximumRunSteepness)
        ]
    }

    private func elevation(_ meters: Double) -> String {
        "\(meters.formatted(.number.precision(.fractionLength(0)))) m"
    }
}
