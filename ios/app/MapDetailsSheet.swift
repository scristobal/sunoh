import SwiftUI

/// Native sheet sizing follows the header's laid-out height, including text
/// wrapping and Dynamic Type. SwiftUI owns the safe areas and drag interaction.
struct MapDetailsSheet<Header: View, Details: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let details: () -> Details
    @State private var selection: PresentationDetent = .large
    @State private var headerHeight: CGFloat?
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isCompact: Bool {
        headerHeight.map { selection == .height($0) } ?? true
    }

    private var detents: Set<PresentationDetent> {
        guard let headerHeight else { return [.large] }
        // A half-height stop can be shorter than the header at accessibility
        // sizes. Keep the fitted header and full-height reading states instead.
        if dynamicTypeSize.isAccessibilitySize { return [.height(headerHeight), .large] }
        return [.height(headerHeight), .medium, .large]
    }

    var body: some View {
        // The compact detent fits the padded header without extra stack spacing.
        VStack(spacing: 0) {
            ScrollView {
                VStack {
                    measuredHeader

                    details()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .accessibilityHidden(isCompact)
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
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled)
        .presentationContentInteraction(.resizes)
        .interactiveDismissDisabled()
        .onChange(of: isCompact) {
            if isCompact { scrollPosition.scrollTo(edge: .top) }
        }
        .onChange(of: dynamicTypeSize) {
            if dynamicTypeSize.isAccessibilitySize, selection == .medium { selection = .large }
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
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel(label)
            .accessibilityHint(hint)
            .accessibilityIdentifier(identifier)
    }
}
