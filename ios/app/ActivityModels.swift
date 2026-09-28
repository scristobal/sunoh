import Foundation

struct ActivityID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init() { rawValue = UUID().uuidString }
    init(stringLiteral value: String) { rawValue = value }
}

struct SegmentID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init() { rawValue = UUID().uuidString }
    init(stringLiteral value: String) { rawValue = value }
}

/// Exact source precision. Date conversion belongs at system/UI boundaries.
struct Timestamp: Codable, Hashable, Comparable, Sendable, ExpressibleByIntegerLiteral {
    let millisecondsSince1970: Int64
    init(millisecondsSince1970: Int64) { self.millisecondsSince1970 = millisecondsSince1970 }
    init(integerLiteral value: Int64) { millisecondsSince1970 = value }
    var date: Date { Date(timeIntervalSince1970: Double(millisecondsSince1970) / 1_000) }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.millisecondsSince1970 < rhs.millisecondsSince1970 }
}

struct Coordinate: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) throws {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw ActivityError.invalidPoint }
        self.latitude = latitude; self.longitude = longitude
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(latitude: values.decode(Double.self, forKey: .latitude),
                      longitude: values.decode(Double.self, forKey: .longitude))
    }
}

struct TrackPoint: Codable, Hashable, Sendable {
    let recordedAt: Timestamp
    let coordinate: Coordinate
    let elevationMeters: Double?

    init(recordedAt: Timestamp, coordinate: Coordinate, elevationMeters: Double?) throws {
        guard recordedAt.millisecondsSince1970 >= 0, elevationMeters?.isFinite ?? true else { throw ActivityError.invalidPoint }
        self.recordedAt = recordedAt; self.coordinate = coordinate; self.elevationMeters = elevationMeters
    }

    init(timestampMilliseconds: Int64, latitude: Double, longitude: Double, elevationMeters: Double?) throws {
        try self.init(recordedAt: Timestamp(millisecondsSince1970: timestampMilliseconds),
                      coordinate: Coordinate(latitude: latitude, longitude: longitude), elevationMeters: elevationMeters)
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(recordedAt: values.decode(Timestamp.self, forKey: .recordedAt),
                      coordinate: values.decode(Coordinate.self, forKey: .coordinate),
                      elevationMeters: values.decodeIfPresent(Double.self, forKey: .elevationMeters))
    }

    var timestampMilliseconds: Int64 { recordedAt.millisecondsSince1970 }
    var latitude: Double { coordinate.latitude }
    var longitude: Double { coordinate.longitude }
}

// Keep the stored value for unfinished recordings readable without changing their observations.
enum ActivityStatus: String, Codable, Sendable { case recording, stopped = "paused", completed }
enum ActivityOrigin: String, Codable, Sendable { case deviceRecording, gpxImport }
enum SegmentBoundary: String, Codable, Sendable { case recordingStarted, recordingResumed, importedSegment }
enum RecordingPhase: String, Codable, Sendable { case recording, stopped = "paused" }

struct ActivitySummary: Codable, Equatable, Identifiable, Sendable {
    let id: ActivityID
    let startedAt: Timestamp
    let lastPointAt: Timestamp?
    var completedAt: Timestamp? = nil
    var importedAt: Timestamp? = nil
    var origin: ActivityOrigin = .deviceRecording
    var status: ActivityStatus = .completed
    let pointCount: Int
    var sourceRevision: Int64 = 0
}

struct ActiveRecording: Equatable, Sendable {
    let summary: ActivitySummary
    let phase: RecordingPhase
    let segmentID: SegmentID
    let recordingStartedAt: Timestamp
    var recordingStoppedAt: Timestamp? = nil
    var id: ActivityID { summary.id }

    var needsSaveDecision: Bool {
        guard let recordingStoppedAt else { return false }
        let duration = recordingStoppedAt.millisecondsSince1970 - summary.startedAt.millisecondsSince1970
        return summary.pointCount < 10 || duration < 60_000
    }
}

struct TrackSegment: Equatable, Identifiable, Sendable {
    let id: SegmentID
    let ordinal: Int
    let boundary: SegmentBoundary
    let recordingStartedAt: Timestamp?
    let recordingStoppedAt: Timestamp?
    let points: [TrackPoint]
}

struct RecordedTrack: Equatable, Sendable {
    let activityID: ActivityID
    let sourceRevision: Int64
    let segments: [TrackSegment]

    /// GPX carries observations and original nonempty boundaries, never inferred gaps.
    var gpx: GPXTrack { GPXTrack(segments: segments.filter { !$0.points.isEmpty }.map { GPXSegment(points: $0.points) }) }
}

enum ContinuityBreak: Equatable, Sendable { case sourceBoundary }

struct TrackSection: Equatable, Sendable {
    let sourceSegmentID: SegmentID
    let breakBefore: ContinuityBreak?
    let points: [TrackPoint]
}

struct TrackGeometry: Equatable, Sendable {
    let activityID: ActivityID
    let sourceRevision: Int64
    let sections: [TrackSection]
}

struct ActivityDetails: Sendable {
    let activity: ActivitySummary
    let geometry: TrackGeometry
}

struct ActivityStatistics: Codable, Equatable, Sendable {
    var elapsedDurationMilliseconds: Int64 = 0
    var distanceMeters = 0.0
    var elevationGainMeters = 0.0
    var elevationLossMeters = 0.0
    var maximumElevationMeters: Double?
    var minimumElevationMeters: Double?
    var runCount = 0
    var averageDownhillSpeedMetersPerSecond: Double?
    var runDistanceMeters = 0.0
    var runDurationMilliseconds: Int64 = 0
    var maximumRunSpeedMetersPerSecond: Double?
    var tallestRunHeightMeters: Double?
    var longestRunDistanceMeters: Double?
    var averageRunSteepnessPercent: Double?
    var maximumRunSteepnessPercent: Double?

    init() {}
}

enum ActivityError: LocalizedError, Sendable {
    case missing, invalidTransition, invalidPoint, conflictingPoint(Int64), storage(String), multipleRecordings, invalidData(String), staleAnalysis

    var errorDescription: String? {
        switch self {
        case .missing: "This activity is no longer available."
        case .invalidTransition: "The recording changed. Refresh before continuing."
        case .invalidPoint: "A location sample is invalid or outside the recording interval."
        case .conflictingPoint(let timestamp): "A different location already exists at \(timestamp). The original point was preserved."
        case .storage(let message): "Storage is unavailable. Recording has stopped accepting points. \(message)"
        case .multipleRecordings: "Multiple open recordings were found. No new recording was started."
        case .invalidData(let message): "The activity data could not be read: \(message)"
        case .staleAnalysis: "The activity changed while it was being processed. Please retry."
        }
    }
}
