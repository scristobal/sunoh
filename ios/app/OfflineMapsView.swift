import SwiftUI

struct OfflineMapsView: View {
    @Environment(OfflineMaps.self) private var offline
    @State private var details: OfflineRegion?
    @State private var viewMode = ViewMode.list
    @State private var showSearch = false
    @State private var storageBarHeight: CGFloat = 0

    private enum ViewMode { case list, map }

    var body: some View {
        VStack {
            Picker("View", selection: $viewMode) {
                Label("List", systemImage: "list.bullet").labelStyle(.iconOnly).tag(ViewMode.list)
                Label("Map", systemImage: "map").labelStyle(.iconOnly).tag(ViewMode.map)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Group {
                switch viewMode {
                case .list: mapsList
                case .map: OfflineStatusMapView(obscuredBottom: storageBarHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .bottom) {
            OfflineStorageBar()
                .padding()
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                .padding(.horizontal)
                .padding(.bottom)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { storageBarHeight = $0 }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Offline maps")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add map", systemImage: "plus") { showSearch = true }
                    .labelStyle(.iconOnly)
            }
        }
        .navigationDestination(isPresented: $showSearch) { OfflineMapSearch() }
        .sheet(item: $details) { region in OfflineMapSheet(region: region, isSelected: true) }
    }

    private var mapsList: some View {
        List {
            if let issue = offline.issue {
                Section { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }

            if !offline.isReady && offline.selectedRegions.isEmpty {
                Section { ProgressView("Loading maps…") }
            } else if offline.selectedRegions.isEmpty {
                Section {
                    ContentUnavailableView("No offline maps", systemImage: "map",
                        description: Text("Tap + to find a resort to download."))
                }
            } else {
                Section {
                    ForEach(offline.selectedRegions) { region in
                        Button { details = region } label: {
                            OfflineResortRow(region: region)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .contentMargins(.bottom, storageBarHeight)
    }
}

private struct OfflineMapSearch: View {
    @Environment(OfflineMaps.self) private var offline
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var download: OfflineRegion?
    @State private var requestedRegion: OfflineRegion?
    @FocusState private var searchFocused: Bool

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var results: [OfflineRegion] {
        guard !query.isEmpty else { return [] }
        return offline.catalog.filter {
            !offline.isSelected($0) &&
            ($0.name.localizedStandardContains(query) || $0.location.localizedStandardContains(query))
        }
    }

    var body: some View {
        List {
            if let error = offline.catalogError, offline.catalog.isEmpty {
                ContentUnavailableView("Maps unavailable", systemImage: "map", description: Text(error))
            } else if !offline.isReady && offline.catalog.isEmpty {
                ProgressView("Loading maps…")
            } else if query.isEmpty {
                ContentUnavailableView("Search for a resort", systemImage: "magnifyingglass",
                    description: Text("Find a map to download in the Alps."))
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ForEach(results) { region in
                    Button {
                        searchFocused = false
                        requestedRegion = region
                        download = region
                    } label: { OfflineResortRow(region: region) }
                        .buttonStyle(.plain)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search resorts", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit { searchFocused = false }
                if !search.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { search = "" }
                        .labelStyle(.iconOnly).foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                }
            }
            .padding()
            .glassEffect(.regular, in: .capsule)
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Add map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .sheet(item: $download, onDismiss: {
            if let region = requestedRegion, offline.isSelected(region) { dismiss() }
        }) { region in OfflineMapSheet(region: region, isSelected: false) }
        .onAppear { searchFocused = true }
        .onDisappear { searchFocused = false }
    }
}

private struct OfflineResortRow: View {
    let region: OfflineRegion

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(region.name).font(.headline).foregroundStyle(.primary)
                Text(region.location).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

private struct OfflineMapSheet: View {
    let region: OfflineRegion
    let isSelected: Bool
    @Environment(OfflineMaps.self) private var offline
    @Environment(\.dismiss) private var dismiss
    @State private var previewIssue: String?
    @State private var confirmDelete = false
    @State private var contentHeight: CGFloat = 1

    var body: some View {
        ScrollView {
            VStack {
                HStack {
                    Button(isSelected ? "Done" : "Cancel") { dismiss() }
                        .buttonStyle(.glass)
                    Text(region.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                ZStack {
                    if let issue = MapService.configurationIssue ?? previewIssue {
                        ContentUnavailableView("Map unavailable", systemImage: "map", description: Text(issue))
                    } else {
                        OfflineStatusMap(regions: [region], downloads: [:],
                            focusedRegion: region, onIssue: { previewIssue = $0 }, isPreview: true)
                            .allowsHitTesting(false)
                    }
                }
                .aspectRatio(1.8, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 24))

                if let error = offline.error(for: region) {
                    Text(error).foregroundStyle(.red)
                }

                VStack {
                    if !isSelected {
                        Toggle("Download over mobile data", isOn: Binding(
                            get: { offline.allowsMobileData }, set: { offline.setMobileDataAllowed($0) }))
                            .disabled(!offline.isReady)
                    }
                    Button(role: isSelected ? .destructive : nil) {
                        if isSelected { confirmDelete = true }
                        else if offline.request(region) { dismiss() }
                    } label: {
                        Text(isSelected ? "Delete" : "Download").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(isSelected ? .red : .accentColor)
                    .controlSize(.large)
                    .disabled(isSelected ? (!offline.isReady || !offline.removing.isEmpty) : !offline.canRequest)
                }
                .padding(.top)
            }
            .padding()
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { height in
                if height > 0 { contentHeight = height }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .alert("Delete \(region.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    await offline.delete(region)
                    if !offline.isSelected(region) { dismiss() }
                }
            }
            Button("Keep map", role: .cancel) {}
        } message: {
            Text("Removes this map. Data needed by other downloaded maps will be kept.")
        }
    }
}
