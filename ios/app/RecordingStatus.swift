/// Work that changes or restores the active recording, separate from routine point writes.
enum RecordingOperation: Equatable {
    case restoring, starting, stopping, saving, discarding

    var label: String {
        switch self {
        case .restoring: "Loading recording"
        case .starting: "Starting"
        case .stopping: "Stopping"
        case .saving: "Saving"
        case .discarding: "Discarding"
        }
    }
}

/// The status presented consistently wherever the recording is visible.
/// Location readiness is combined with the store status at the presentation boundary.
enum RecordingStatus: Equatable {
    case ready
    case locationNotReady
    case working(RecordingOperation)
    case recording
    case stopped
    case unavailable

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    func withLocationReadiness(_ isReady: Bool) -> RecordingStatus {
        switch self {
        case .ready, .locationNotReady: isReady ? .ready : .locationNotReady
        default: self
        }
    }

    var label: String {
        switch self {
        case .ready: "Ready"
        case .locationNotReady: "Location not ready"
        case .working(let operation): operation.label
        case .recording: "Recording"
        case .stopped: "Recording stopped"
        case .unavailable: "Recording unavailable"
        }
    }
}
