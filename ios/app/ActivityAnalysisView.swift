import SwiftUI

/// Source details are usable immediately, even when rebuilding analysis fails.
struct ActivityAnalysisView: View {
    let activityID: ActivityID
    let library: ActivityLibrary
    @State private var analysis: LoadState<ActivityAnalysis> = .loading

    var body: some View {
        Group {
            switch analysis {
            case .loading: ProgressView("Processing activity…")
            case .loaded(let result): ActivityStatisticsView(stats: result.statistics)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry processing") { analysis = .loading }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
        }
        .task(id: analysis.isLoading) {
            guard analysis.isLoading else { return }
            do {
                let result = try await library.analysis(id: activityID)
                guard !Task.isCancelled else { return }
                analysis = .loaded(result)
            } catch {
                guard !Task.isCancelled else { return }
                analysis = .failed(error.localizedDescription)
            }
        }
    }
}
