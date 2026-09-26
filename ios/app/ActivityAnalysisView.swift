import SwiftUI

/// Source details are usable immediately, even when rebuilding analysis fails.
struct ActivityAnalysisView: View {
    let activityID: ActivityID
    let library: ActivityLibrary
    var onAnalysis: ((ActivityAnalysis) -> Void)? = nil
    var onFailure: ((String) -> Void)? = nil
    @State private var analysis: LoadState<ActivityAnalysis> = .loading
    @State private var forceProcessing = false

    var body: some View {
        Group {
            switch analysis {
            case .loading: ProgressView("Processing activity…")
            case .loaded(let result):
                VStack(alignment: .leading) {
                    ActivityStatisticsView(stats: result.statistics)
                    if result.timeline?.skiMatches?.failure != nil {
                        Button("Retry identification") {
                            forceProcessing = true
                            analysis = .loading
                        }
                    }
                }
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
                let result = try await library.analysis(id: activityID, force: forceProcessing)
                guard !Task.isCancelled else { return }
                forceProcessing = false
                analysis = .loaded(result)
                onAnalysis?(result)
            } catch {
                guard !Task.isCancelled else { return }
                analysis = .failed(error.localizedDescription)
                onFailure?(error.localizedDescription)
            }
        }
    }
}
