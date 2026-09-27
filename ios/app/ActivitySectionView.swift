import SwiftUI

struct ActivitySectionView: View {
    let timeline: ActivityTimeline
    let geometry: TrackGeometry
    @Binding var selection: Int

    private var index: Int { min(max(0, selection), max(0, timeline.entries.count - 1)) }

    var body: some View {
        VStack(alignment: .leading) {
            if !timeline.entries.isEmpty {
                let entry = timeline.entries[index]
                let number = timeline.entries.prefix(index + 1).filter { $0.kind == entry.kind }.count
                let total = timeline.entries.filter { $0.kind == entry.kind }.count
                ActivityElevationProfile(geometry: Geo.selectedGeometry(in: geometry, entry: entry))
                    .aspectRatio(4, contentMode: .fit)
                ActivitySectionMeasurements(entry: entry)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("timeline-entry-\(index)")
                HStack {
                    Button { move(by: -1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Previous run or lift")
                    .accessibilityIdentifier("previous-activity-section")
                    .disabled(index == 0)
                    Spacer()
                    Text("\(entry.kind.title.lowercased()) \(number) of \(total)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("activity-section-position")
                    Spacer()
                    Button { move(by: 1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .accessibilityLabel("Next run or lift")
                    .accessibilityIdentifier("next-activity-section")
                    .disabled(index == timeline.entries.count - 1)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.large)
            } else {
                Text("Not enough recorded data to build a timeline.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(.rect)
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            move(by: value.translation.width < 0 ? 1 : -1)
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity-section-card")
    }

    private func move(by step: Int) {
        guard !timeline.entries.isEmpty else { return }
        withAnimation { selection = min(max(0, index + step), timeline.entries.count - 1) }
    }
}

private struct ActivitySectionMeasurements: View {
    let entry: ActivityTimelineEntry

    var body: some View {
        VStack {
            Text(measurements.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("timeline-measurements")
        }
        .frame(maxWidth: .infinity)
    }

    private var measurements: [String] {
        var values: [String] = []
        if let distance = entry.distanceMeters {
            values.append("↔ \(ActivityStatistics.distance(distance))")
        }
        if let descent = entry.elevationLossMeters, entry.kind == .run {
            values.append("↕︎ \(elevation(descent))")
        }
        if let ascent = entry.elevationGainMeters, entry.kind == .lift {
            values.append("↕︎ \(elevation(ascent))")
        }
        return values
    }

    private func elevation(_ meters: Double) -> String {
        "\(meters.magnitude.formatted(.number.precision(.fractionLength(0)))) m"
    }
}

private extension ActivityTimelineKind {
    var title: String {
        switch self {
        case .run: "Run"
        case .lift: "Lift"
        }
    }
}

enum TimelineFormatting {
    static func time(_ timestamp: Timestamp) -> String {
        timestamp.date.formatted(Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: .current, calendar: .current
        ))
    }

    static func duration(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds) / 1_000
        if milliseconds > 0 && seconds == 0 { return "<1s" }
        let hours = seconds / 3_600
        let minutes = seconds % 3_600 / 60
        let remainder = seconds % 60
        var components: [String] = []
        if hours > 0 { components.append("\(hours)h") }
        if minutes > 0 { components.append("\(minutes)m") }
        if remainder > 0 || components.isEmpty { components.append("\(remainder)s") }
        return components.joined(separator: " ")
    }
}
