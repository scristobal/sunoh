import Foundation
@testable import Sunoh

func fixtureTrack(_ segments: [GPXSegment], activityID: ActivityID = "fixture", sourceRevision: Int64 = 1) -> RecordedTrack {
    RecordedTrack(activityID: activityID, sourceRevision: sourceRevision, segments: segments.enumerated().map { index, segment in
        TrackSegment(id: SegmentID(rawValue: "fixture-\(index)"), ordinal: index, boundary: .importedSegment,
                     recordingStartedAt: nil, recordingStoppedAt: nil, points: segment.points)
    })
}

func fixtureGeometry(_ segments: [GPXSegment]) -> TrackGeometry {
    TrackContinuityPolicy.geometry(for: fixtureTrack(segments))
}
