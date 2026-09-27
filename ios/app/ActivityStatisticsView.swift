import SwiftUI

struct ActivityStatisticsView: View {
    let stats: ActivityStatistics

    var body: some View {
        Grid(alignment: .top) {
            ForEach(Array(stride(from: 0, to: metrics.count, by: 3)), id: \.self) { start in
                GridRow(alignment: .top) {
                    ForEach(metrics[start..<min(start + 3, metrics.count)]) { metric in
                        VStack {
                            Text(metric.value).font(.title3.weight(.semibold))
                            Text(metric.label).font(.caption)
                        }
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(metric.label)
                        .accessibilityValue(metric.value)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity-statistics")
    }

    private var metrics: [StatisticsGrid.Metric] {
        [
            .init(label: "Total duration", value: stats.formattedDuration),
            .init(label: "Total distance", value: stats.formattedDistance),
            .init(label: "Vertical", value: elevation(stats.elevationLossMeters)),
            .init(label: "Runs", value: stats.runCount.formatted()),
            .init(label: "Time on runs", value: stats.formattedRunDuration),
            .init(label: "Distance on runs", value: stats.formattedRunDistance),
            .init(label: "Average speed", value: stats.formattedAverageRunSpeed),
            .init(label: "Top speed", value: stats.formattedMaximumRunSpeed),
            .init(label: "Average steep", value: stats.formattedAverageRunSteepness),
            .init(label: "Tallest run", value: stats.tallestRunHeightMeters.map(elevation) ?? "—"),
            .init(label: "Longest run", value: stats.formattedLongestRunDistance),
            .init(label: "Steepest run", value: stats.formattedMaximumRunSteepness)
        ]
    }

    private func elevation(_ meters: Double) -> String {
        "\(meters.formatted(.number.precision(.fractionLength(0)))) m"
    }
}
