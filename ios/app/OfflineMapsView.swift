import SwiftUI

struct OfflineMapsView: View {
    let tracker: LocationTracker
    @Environment(OfflineMaps.self) private var offline
    @State private var details: OfflineRegion?
    @State private var download: OfflineRegion?
    @State private var showsMap = false
    @State private var filter = OfflineMapFilter.all
    @State private var sort = OfflineMapSort.nameAscending
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @Namespace private var mapTransition

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var regions: [OfflineRegion] {
        let regions = switch filter {
        case .downloaded: offline.selectedRegions.filter { offline.downloads[$0.id]?.phase == .downloaded }
        case .inProgress: offline.selectedRegions.filter { offline.downloads[$0.id]?.isPending == true }
        case .failed: offline.selectedRegions.filter { offline.downloads[$0.id]?.phase == .failed }
        case .all: allRegions
        }
        let matches = query.isEmpty ? regions
            : regions.filter { $0.name.localizedStandardContains(query) || $0.location.localizedStandardContains(query) }
        switch sort {
        case .nameAscending: return matches
        case .nameDescending: return matches.reversed()
        case .nearest: return origin.map { OfflineRegion.nearestFirst(matches, from: $0) } ?? matches
        }
    }

    private var origin: Coordinate? {
        tracker.currentLocation.flatMap { try? Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private var allRegions: [OfflineRegion] {
        let listed = Set(offline.catalog.map(\.id))
        let unlisted = offline.selectedRegions.filter { !listed.contains($0.id) }
        guard !unlisted.isEmpty else { return offline.catalog }
        return (offline.catalog + unlisted).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack {
            OfflineStorageBar()
                .padding()
            resortList
            bottomBar
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Offline maps")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Offline maps").font(.title2.bold())
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Coverage map", systemImage: "map") { showsMap = true }
                    .labelStyle(.iconOnly)
            }
            .matchedTransitionSource(id: "coverage-map", in: mapTransition)
        }
        .toolbar(.hidden, for: .tabBar)
        .sheet(item: $details) { region in OfflineMapSheet(region: region, isSelected: true) }
        .fullScreenCover(isPresented: $showsMap) {
            FullScreenCoverageMap()
                .navigationTransition(.zoom(sourceID: "coverage-map", in: mapTransition))
        }
    }

    private var resortList: some View {
        let regions = regions
        return List {
            if let issue = offline.issue {
                Section { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }

            Section {
                if let error = offline.catalogError, filter == .all, offline.catalog.isEmpty {
                    ContentUnavailableView("Maps unavailable", systemImage: "map", description: Text(error))
                } else if !offline.isReady && regions.isEmpty {
                    ProgressView("Loading maps…")
                } else if regions.isEmpty {
                    if query.isEmpty { emptyState } else { ContentUnavailableView.search(text: query) }
                } else {
                    ForEach(regions) { region in
                        Button {
                            searchFocused = false
                            if offline.isSelected(region) { details = region } else { download = region }
                        } label: {
                            OfflineResortRow(region: region, record: offline.downloads[region.id],
                                             isRemoving: offline.removing.contains(region.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $download) { region in OfflineMapSheet(region: region, isSelected: false) }
    }

    @ViewBuilder private var emptyState: some View {
        switch filter {
        case .downloaded:
            ContentUnavailableView("No downloaded maps", systemImage: "map",
                description: Text("Choose All in the filter menu to find a resort to download."))
        case .inProgress:
            ContentUnavailableView("No downloads in progress", systemImage: "arrow.down.circle")
        case .failed:
            ContentUnavailableView("No failed downloads", systemImage: "exclamationmark.circle")
        case .all:
            ContentUnavailableView("No resorts", systemImage: "map")
        }
    }

    private var bottomBar: some View {
        HStack {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(filter.searchPrompt, text: $search)
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

            Group {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(OfflineMapSort.allCases) { sort in
                            Label(sort.title, systemImage: sort.systemImage).tag(sort)
                                .selectionDisabled(sort == .nearest && origin == nil)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label { Text("Sort") } icon: { BottomBarIcon("arrow.up.arrow.down") }
                        .labelStyle(.iconOnly)
                }

                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(OfflineMapFilter.allCases) { filter in
                            Label(filter.title, systemImage: filter.systemImage).tag(filter)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label { Text("Filter") } icon: { BottomBarIcon("line.3.horizontal.decrease") }
                        .labelStyle(.iconOnly)
                }
            }
            .menuOrder(.fixed)
            .menuStyle(.button)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        }
        .padding([.horizontal, .bottom])
    }
}

private struct BottomBarIcon: View {
    let systemImage: String

    init(_ systemImage: String) { self.systemImage = systemImage }

    // Both icons take the space of the larger symbol so the sort and filter buttons are the same size.
    var body: some View {
        ZStack {
            Image(systemName: "arrow.up.arrow.down").hidden()
            Image(systemName: "line.3.horizontal.decrease").hidden()
            Image(systemName: systemImage)
        }
    }
}

private enum OfflineMapSort: CaseIterable, Identifiable {
    case nameAscending, nameDescending, nearest

    var id: Self { self }

    var title: String {
        switch self {
        case .nameAscending: "A to Z"
        case .nameDescending: "Z to A"
        case .nearest: "Nearest first"
        }
    }

    var systemImage: String {
        switch self {
        case .nameAscending: "arrow.down"
        case .nameDescending: "arrow.up"
        case .nearest: "location"
        }
    }
}

private enum OfflineMapFilter: CaseIterable, Identifiable {
    case all, failed, inProgress, downloaded

    var id: Self { self }

    var title: String {
        switch self {
        case .downloaded: "Downloaded"
        case .inProgress: "In progress"
        case .failed: "Failed"
        case .all: "All"
        }
    }

    var systemImage: String {
        switch self {
        case .downloaded: "arrow.down.circle.fill"
        case .inProgress: "arrow.down.circle.dotted"
        case .failed: "exclamationmark.circle"
        case .all: "list.bullet"
        }
    }

    var searchPrompt: String {
        switch self {
        case .downloaded: "Search downloaded maps"
        case .inProgress: "Search maps in progress"
        case .failed: "Search failed downloads"
        case .all: "Search resorts"
        }
    }
}

private struct FullScreenCoverageMap: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OfflineStatusMapView()
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                MapSheetCloseButton(label: "Close coverage map", hint: "Returns to offline maps",
                                    identifier: "close-coverage-map", action: { dismiss() })
                    .padding()
            }
    }
}

private struct OfflineResortRow: View {
    let region: OfflineRegion
    let record: OfflineMapRecord?
    let isRemoving: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(region.name).font(.headline).foregroundStyle(.primary)
                Text(region.location).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            OfflineMapStateIcon(record: record, isRemoving: isRemoving)
        }
        .contentShape(Rectangle())
    }
}

private struct OfflineMapStateIcon: View {
    let record: OfflineMapRecord?
    let isRemoving: Bool

    var body: some View {
        Group {
            if isRemoving {
                ProgressView()
            } else if let record {
                switch record.phase {
                case .downloaded:
                    Image(systemName: "arrow.down.circle.fill")
                case .failed:
                    Image(systemName: "exclamationmark.circle")
                case .queued, .downloading:
                    if let progress {
                        Image(systemName: "circle", variableValue: progress)
                            .symbolVariableValueMode(.draw)
                    } else {
                        ProgressView()
                    }
                }
            } else {
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
            }
        }
        .font(.title2)
        .accessibilityLabel(stateDescription)
    }

    private var progress: Double? {
        guard let record, record.requiredResources > 0 else { return nil }
        return Double(record.completedResources) / Double(record.requiredResources)
    }

    private var stateDescription: String {
        if isRemoving { return "Deleting" }
        guard let record else { return "Not downloaded" }
        switch record.phase {
        case .downloaded: return "Downloaded"
        case .failed: return "Download failed"
        case .queued, .downloading:
            guard let progress else { return "Waiting to download" }
            return "Downloading, \(progress.formatted(.percent.precision(.fractionLength(0))))"
        }
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
                    closeButton
                    Text(region.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    closeButton
                        .hidden()
                        .accessibilityHidden(true)
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

    private var closeButton: some View {
        Button(isSelected ? "Done" : "Cancel") { dismiss() }
            .buttonStyle(.glass)
    }
}
