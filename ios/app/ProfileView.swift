import SwiftUI

struct ProfileView: View {
    let library: ActivityLibrary

    var body: some View {
        Form {
            Section {
                if case .loaded(let saved) = library.history {
                    LabeledContent("Saved activities", value: saved.count.formatted())
                } else if library.history.isLoading {
                    ProgressView("Loading activities…")
                }
                GPXImportButton(library: library)
                GPXExportAllButton(library: library)
            } header: {
                Text("Activities")
            } footer: {
                Text("Export All includes saved activities with recorded points in one GPX file. Your current recording is not included.")
            }

            if case .failed(let loadError) = library.history {
                Section {
                    Text(loadError).foregroundStyle(.red)
                    Button("Retry") { Task { await library.reloadHistory() } }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
    }
}
