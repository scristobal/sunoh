import SwiftUI

struct ActivitySheetPresentation: Equatable, Sendable {
    var height: CGFloat = 0
    var isExpanded = false
}

/// Both sheet positions fit their content, leaving the rest of the map visible.
struct ActivitySectionSheet<Header: View, Details: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let details: () -> Details
    let onPresentationChange: (ActivitySheetPresentation) -> Void
    @State private var headerHeight: CGFloat = 1
    @State private var detailsHeight: CGFloat = 0
    @State private var selection: PresentationDetent = .height(1)

    private var expandedDetent: PresentationDetent { .height(headerHeight + detailsHeight) }
    private var isExpanded: Bool { detailsHeight > 0 && selection == expandedDetent }

    var body: some View {
        VStack(spacing: 0) {
            header()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    guard height > 0, height != headerHeight else { return }
                    let wasExpanded = isExpanded
                    headerHeight = height
                    selection = wasExpanded ? expandedDetent : .height(height)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("map-details-header")
            // Let the sheet's bounds reveal the details continuously during a drag.
            measuredDetails
                .accessibilityHidden(!isExpanded)
                .allowsHitTesting(isExpanded)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .onGeometryChange(for: ActivitySheetPresentation.self) { geometry in
            ActivitySheetPresentation(height: geometry.size.height + geometry.safeAreaInsets.bottom,
                                      isExpanded: isExpanded)
        } action: { presentation in
            if presentation.height > 0 { onPresentationChange(presentation) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("map-details-sheet")
        .presentationDetents([.height(headerHeight), expandedDetent], selection: $selection)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled)
        .presentationContentInteraction(.resizes)
        .interactiveDismissDisabled()
    }

    private var measuredDetails: some View {
        details()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                guard height > 0, height != detailsHeight else { return }
                let wasExpanded = isExpanded
                detailsHeight = height
                if wasExpanded { selection = expandedDetent }
            }
    }
}
