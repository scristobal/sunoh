import SwiftUI

extension RecordingActivityAttributes.ContentState {
    var statusLabel: String {
        isBlocked ? "Storage unavailable" : (isRecording ? "Recording" : "Recording stopped")
    }

    var statusSymbol: String {
        isBlocked ? "exclamationmark.triangle" : (isRecording ? "record.circle" : "stop.circle")
    }
}

struct RecordingActivitySummary: View {
    let state: RecordingActivityAttributes.ContentState

    // ActivityKit can truncate Lock Screen presentations above 160 points.
    // This is the platform's content limit, independent of device pixel density:
    // https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
    private static let maximumHeight: CGFloat = 160

    var body: some View {
        ViewThatFits {
            HStack(spacing: 16) {
                status
                RecordingTime(state: state)
                points
            }
            .padding()
            .fixedSize(horizontal: true, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                status
                RecordingTime(state: state)
                points
            }
            .padding()
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: state.statusSymbol)
                        .accessibilityLabel(state.statusLabel)
                    Text(state.pointCount, format: .number.notation(.compactName))
                        .monospacedDigit()
                        .accessibilityLabel("\(state.pointCount.formatted()) saved points")
                }
                if state.startedAt != nil, state.lastPointAt != nil {
                    RecordingTime(state: state)
                }
            }
            .font(.caption.weight(.semibold))
            .padding()
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: Self.maximumHeight, alignment: .topLeading)
    }

    private var status: some View {
        Label(state.statusLabel, systemImage: state.statusSymbol)
            .font(.headline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var points: some View {
        Text("\(state.pointCount.formatted()) saved points")
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct RecordingTime: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Group {
            if let start = state.startedAt, let end = state.lastPointAt {
                // Show only the time covered by saved points.
                Text(timerInterval: start...max(start, end), pauseTime: end, countsDown: false)
                    .monospacedDigit()
            } else {
                Text(state.isRecording ? "Waiting for points" : "No saved points")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
