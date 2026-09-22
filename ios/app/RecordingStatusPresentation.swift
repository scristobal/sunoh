import SwiftUI

extension RecordingStatus {
    var symbol: String {
        switch self {
        case .ready: "location"
        case .locationNotReady: "location.slash"
        case .working: "hourglass"
        case .recording: "record.circle"
        case .paused: "pause.circle"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .locationNotReady, .paused: .orange
        case .working: .secondary
        case .recording, .unavailable: .red
        }
    }
}

struct RecordingStatusIcon: View {
    let status: RecordingStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if status.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
            } else {
                Image(systemName: status.symbol)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(status.color)
                    .symbolEffect(.pulse.wholeSymbol, options: .repeating,
                                  isActive: status == .recording && !reduceMotion)
            }
        }
        .accessibilityLabel(status.label)
    }
}
