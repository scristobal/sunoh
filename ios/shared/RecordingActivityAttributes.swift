import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes, Sendable {
    enum Phase: String, Codable, Hashable, Sendable { case recording, stopped, blocked }

    struct ContentState: Codable, Hashable, Sendable {
        var pointCount: Int
        var phase: Phase
        var isRecording: Bool { phase == .recording }
        var isBlocked: Bool { phase == .blocked }
        var startedAt: Date?
        var lastPointAt: Date?
    }
}
