import SwiftUI

struct ProfileView: View {
    let library: ActivityLibrary
    @AppStorage(MapStyle.preferenceKey) private var mapStyle = MapStyle.defaultSelection

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
            }

            Section("Map") {
                Picker("Style", selection: $mapStyle) {
                    ForEach(MapStyle.options(including: mapStyle)) { style in
                        Text(style.name).tag(style)
                    }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("map-style-picker")
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
