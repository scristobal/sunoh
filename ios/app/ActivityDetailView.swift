import SwiftUI

// MARK: - Activity detail

struct ActivityDetailView: View {
    let activityID: ActivityID
    let library: ActivityLibrary

    @Environment(\.dismiss) private var dismiss
    @State private var content: LoadState<ActivityDetails> = .loading
    @State private var showDetails = false

    var body: some View {
        Group {
            if case .loaded(let details) = content {
                InspectMapView(geometry: details.geometry)
            } else {
                Color(uiColor: .systemBackground)
            }
        }
        .ignoresSafeArea()
        .onAppear { showDetails = true }
        .sheet(isPresented: $showDetails) {
            details
                .tint(.black)
        }
        .task(id: content.isLoading) {
            if content.isLoading { await loadActivity() }
        }
    }

    private var details: some View {
        MapDetailsSheet {
            sheetHeader
        } details: {
            if case .loaded = content {
                ActivityAnalysisView(activityID: activityID, library: library)
            }
        }
    }

    @ViewBuilder
    private var sheetHeader: some View {
        switch content {
        case .loaded(let details):
            ActivitySheetHeader(
                activity: details.activity,
                library: library,
                onClose: { dismiss() }
            )
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

    private func loadActivity() async {
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

// The view formats measurements calculated by the activity processor.
extension ActivityStatistics {
    var formattedDuration: String {
        let totalMinutes = elapsedDurationMilliseconds / 60_000
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var formattedDistance: String {
        if distanceMeters >= 1_000 {
            return "\((distanceMeters / 1_000).formatted(.number.precision(.fractionLength(1)))) km"
        }
        return "\(distanceMeters.rounded(.towardZero).formatted(.number.precision(.fractionLength(0)))) m"
    }
}

// MARK: - Activity sheet header

private struct ActivitySheetHeader: View {
    let activity: ActivitySummary
    let library: ActivityLibrary
    let onClose: () -> Void
    @ScaledMetric(relativeTo: .body) private var iconSize = 44

    var body: some View {
        HStack(alignment: .center) {
            MapSheetCloseButton(label: "Close activity details", hint: "Returns to activity overview",
                                identifier: "close-activity-details", action: onClose)

            ViewThatFits(in: .horizontal) {
                HStack {
                    ActivityThumbnail(activityID: activity.id, library: library)
                        .frame(width: iconSize, height: iconSize)
                    title.fixedSize(horizontal: true, vertical: true)
                }
                title
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: some View {
        VStack(alignment: .leading) {
            Text(activity.dateIntervalLabel)
                .font(.headline)
            Text("\(activity.pointCount) saved points")
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ActivityStatisticsView: View {
    let stats: ActivityStatistics

    var body: some View {
        StatisticsGrid(metrics: metrics)
    }

    private var metrics: [StatisticsGrid.Metric] {
        var values: [StatisticsGrid.Metric] = [
            .init(label: "Duration", value: stats.formattedDuration),
            .init(label: "Distance", value: stats.formattedDistance),
            .init(label: "Descent", value: elevation(stats.elevationLossMeters)),
            .init(label: "Ascent", value: elevation(stats.elevationGainMeters))
        ]
        if let maximum = stats.maximumElevationMeters { values.append(.init(label: "Peak", value: elevation(maximum))) }
        if let minimum = stats.minimumElevationMeters { values.append(.init(label: "Lowest", value: elevation(minimum))) }
        return values
    }

    private func elevation(_ meters: Double) -> String {
        "\(meters.rounded(.towardZero).formatted(.number.precision(.fractionLength(0)))) m"
    }
}
