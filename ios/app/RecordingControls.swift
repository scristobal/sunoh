import SwiftUI

struct RecordControls: View {
    let tracker: LocationTracker
    let recorder: RecordingController

    var body: some View {
        VStack(alignment: .leading) {
            RecordingSummary(tracker: tracker, recorder: recorder)
            RecordingMessages(tracker: tracker, recorder: recorder)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RecordingSummary: View {
    let tracker: LocationTracker
    let recorder: RecordingController

    private var status: RecordingStatus {
        recorder.recordingStatus.withLocationReadiness(tracker.isLocationReady)
    }

    var body: some View {
        RecordingActionRow(recorder: recorder, status: status)
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RecordingMessages: View {
    let tracker: LocationTracker
    let recorder: RecordingController

    var body: some View {
        VStack(alignment: .leading) {
            if let message = tracker.locationMessage {
                Text(message).font(.callout).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = recorder.storageError {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if recorder.requiresRestart {
                    Text("Restart Sunō to reopen storage. Pending points have not been saved.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button("Retry") { Task { await recorder.refresh() } }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
        }
    }
}
