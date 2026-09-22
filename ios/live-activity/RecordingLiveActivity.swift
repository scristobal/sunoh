import ActivityKit
import SwiftUI
import WidgetKit

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingActivitySummary(state: context.state)
                .widgetURL(URL(string: "sunoh://explore"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.statusSymbol)
                        .foregroundStyle(context.state.isRecording ? .red : .orange)
                        .accessibilityLabel(context.state.statusLabel)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.statusLabel)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.pointCount, format: .number.notation(.compactName))
                        .font(.caption)
                        .monospacedDigit()
                        .accessibilityLabel("\(context.state.pointCount) saved points")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RecordingTime(state: context.state)
                        .font(.headline)
                }
            } compactLeading: {
                Image(systemName: context.state.statusSymbol)
                    .foregroundStyle(context.state.isRecording ? .red : .orange)
                    .accessibilityLabel(context.state.statusLabel)
            } compactTrailing: {
                Text(context.state.pointCount, format: .number.notation(.compactName))
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .accessibilityLabel("\(context.state.pointCount) saved points")
            } minimal: {
                Image(systemName: context.state.statusSymbol)
                    .foregroundStyle(context.state.isRecording ? .red : .orange)
                    .accessibilityLabel(context.state.statusLabel)
            }
            .widgetURL(URL(string: "sunoh://explore"))
        }
    }
}
