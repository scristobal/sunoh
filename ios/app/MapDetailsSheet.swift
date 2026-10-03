import SwiftUI

/// Both native sheet positions fit their content. SwiftUI owns safe areas and dragging.
struct MapDetailsSheet<Header: View, Details: View>: View {
    let hasDetails: Bool
    @ViewBuilder let header: () -> Header
    @ViewBuilder let details: () -> Details
    @State private var selection: PresentationDetent = .large
    @State private var headerHeight: CGFloat?
    @State private var contentHeight: CGFloat?
    @State private var scrollPosition = ScrollPosition(edge: .top)

    private var isCompact: Bool {
        headerHeight.map { selection == .height($0) } ?? true
    }

    private var detents: Set<PresentationDetent> {
        guard let headerHeight else { return [.large] }
        guard hasDetails, let contentHeight else { return [.height(headerHeight)] }
        return [.height(headerHeight), .height(max(headerHeight, contentHeight))]
    }

    var body: some View {
        // The compact detent fits the padded header without extra stack spacing.
        VStack(spacing: 0) {
            ScrollView {
                VStack {
                    measuredHeader

                    if hasDetails {
                        details()
                            .frame(maxWidth: .infinity)
                            .padding([.horizontal, .bottom])
                            .accessibilityHidden(isCompact)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    guard height > 0, height != contentHeight else { return }
                    let keepExpanded = !isCompact
                    contentHeight = height
                    if keepExpanded, hasDetails { selection = .height(height) }
                }
            }
            .scrollPosition($scrollPosition)
            .scrollDisabled(isCompact)
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("map-details-scroll")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("map-details-sheet")
        .presentationDetents(detents, selection: $selection)
        .presentationDragIndicator(hasDetails ? .visible : .hidden)
        .presentationBackgroundInteraction(.enabled)
        .presentationContentInteraction(.resizes)
        .interactiveDismissDisabled()
        .onChange(of: isCompact) {
            if isCompact { scrollPosition.scrollTo(edge: .top) }
        }
        .onChange(of: hasDetails) {
            if !hasDetails, let headerHeight { selection = .height(headerHeight) }
        }
    }

    private var measuredHeader: some View {
        header()
            .fixedSize(horizontal: false, vertical: true)
            .padding()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                guard height > 0 else { return }
                let keepCompact = isCompact
                headerHeight = height
                if keepCompact { selection = .height(height) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("map-details-header")
    }
}

struct MapSheetCloseButton: View {
    let label: String
    let hint: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(role: .close, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel(label)
            .accessibilityHint(hint)
            .accessibilityIdentifier(identifier)
    }
}
