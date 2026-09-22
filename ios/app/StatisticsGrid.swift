import SwiftUI

/// Try complete columns at their intrinsic text sizes before reducing the column
/// count. The last layout wraps vertically, including at accessibility text sizes.
struct StatisticsGrid: View {
    struct Metric: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    let metrics: [Metric]
    var maximumColumns = 3

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach((1...maximumColumns).reversed(), id: \.self) { columns in
                grid(columns: columns)
                    .fixedSize(horizontal: columns > 1, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func grid(columns: Int) -> some View {
        Grid {
            ForEach(Array(stride(from: 0, to: metrics.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(metrics[start..<min(start + columns, metrics.count)]) { metric in
                        VStack {
                            Text(metric.value)
                                .font(.title3.weight(.semibold))
                            Text(metric.label)
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(metric.label)
                        .accessibilityValue(metric.value)
                    }
                }
            }
        }
    }
}
