import SwiftUI

struct RecordingActions: View {
    let recorder: RecordingController
    let status: RecordingStatus

    var body: some View {
        Group {
            if let action {
                Button {
                    Task {
                        switch action {
                        case .record: await recorder.startRecording()
                        case .pause: await recorder.pauseRecording()
                        case .resume: await recorder.resumeRecording()
                        }
                    }
                } label: {
                    // Measure every state with the current font and label style.
                    // The native button retains that footprint when its action changes.
                    ZStack {
                        ForEach(Action.allCases) { candidate in
                            Label(candidate.title, systemImage: candidate.symbol).hidden()
                        }
                        Label(action.title, systemImage: action.symbol)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(action == .record && status != .ready)
                .accessibilityLabel(action.title)
                .accessibilityIdentifier(action.identifier)
            }
        }
        .font(.subheadline.weight(.medium))
        .controlSize(.large)
        .tint(.black)
        .disabled(recorder.isChangingRecording || recorder.recordingStatus.isWorking)
    }

    private var action: Action? {
        switch recorder.recordingState {
        case .idle: .record
        case .recording: .pause
        case .paused: .resume
        case .unavailable: nil
        }
    }

    private enum Action: CaseIterable, Identifiable {
        case record, pause, resume
        var id: Self { self }
        var title: String {
            switch self {
            case .record: "Record"
            case .pause: "Pause"
            case .resume: "Resume"
            }
        }
        var symbol: String {
            switch self {
            case .record: "record.circle"
            case .pause: "pause.fill"
            case .resume: "play.circle"
            }
        }
        var identifier: String {
            switch self {
            case .record: "recording-start"
            case .pause: "recording-pause"
            case .resume: "recording-resume"
            }
        }
    }
}

/// Keep the primary action on the leading edge and completion actions trailing.
struct RecordingActionRow: View {
    let recorder: RecordingController
    let status: RecordingStatus

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                primaryAction
                Spacer()
                completionActions
            }
            VStack {
                primaryAction.frame(maxWidth: .infinity, alignment: .leading)
                completionActions.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var primaryAction: some View {
        RecordingActions(recorder: recorder, status: status)
            .fixedSize()
    }

    private var completionActions: some View {
        RecordingCompletionActions(recorder: recorder)
            .fixedSize()
    }
}

struct RecordingCompletionActions: View {
    let recorder: RecordingController
    @State private var showSaveConfirmation = false
    @State private var showDiscardConfirmation = false

    var body: some View {
        HStack { actions }
            .font(.subheadline.weight(.medium))
            .controlSize(.large)
            .disabled((recorder.recordingState != .paused && recorder.recordingState != .recording)
                      || recorder.isChangingRecording || recorder.recordingStatus.isWorking)
            .alert("Save session?", isPresented: $showSaveConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { await recorder.finishRecording() } }
            } message: {
                Text("This will finish the session and save your progress.")
            }
            .alert("Discard recording?", isPresented: $showDiscardConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Discard", role: .destructive) { Task { await recorder.discardRecording() } }
            } message: {
                Text("This permanently deletes this recording and all its points.")
            }
    }

    @ViewBuilder
    private var actions: some View {
        Button {
            showSaveConfirmation = true
        } label: {
            Label("Save", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.bordered)
        .labelStyle(.titleAndIcon)
        .accessibilityIdentifier("recording-save")
        Button(role: .destructive) {
            showDiscardConfirmation = true
        } label: {
            Label("Discard", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .tint(.red)
        .accessibilityIdentifier("recording-discard")
    }
}
