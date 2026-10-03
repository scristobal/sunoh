import SwiftUI

struct ProfileView: View {
    let library: ActivityLibrary
    let tracker: LocationTracker
    @Environment(OfflineMaps.self) private var offline

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
                NavigationLink {
                    OfflineMapsView(tracker: tracker)
                } label: {
                    LabeledContent {
                        Text(offline.storageText).foregroundStyle(.secondary)
                    } label: {
                        Label("Offline maps", systemImage: "arrow.down.circle")
                    }
                }
                ClearMapCacheButton()
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
        .onAppear { offline.refreshStorage() }
    }
}

private struct ClearMapCacheButton: View {
    @Environment(OfflineMaps.self) private var offline
    @State private var confirming = false
    @State private var failed = false

    var body: some View {
        Button { confirming = true } label: {
            LabeledContent {
                if offline.isClearingCache {
                    ProgressView()
                } else {
                    Text(offline.cacheText).foregroundStyle(.secondary)
                }
            } label: {
                Label("Clear map cache", systemImage: "trash")
            }
        }
        .disabled(!offline.canClearCache)
        .accessibilityIdentifier("clear-map-cache")
        .alert("Clear map cache?", isPresented: $confirming) {
            Button("Clear cache", role: .destructive) {
                Task {
                    do { try await offline.clearCache() } catch { failed = true }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes map data saved while browsing. Downloaded offline maps are kept.")
        }
        .alert("Map cache not cleared", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The map cache could not be cleared. Try again after reopening Sunō.")
        }
    }
}
