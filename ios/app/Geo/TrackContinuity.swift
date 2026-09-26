/// Preserves explicit source segments for route drawing and measurements regardless of sample timing.
enum TrackContinuityPolicy {
    static func geometry(for track: RecordedTrack) -> TrackGeometry {
        var sections: [TrackSection] = []
        for segment in track.segments where !segment.points.isEmpty {
            sections.append(TrackSection(sourceSegmentID: segment.id, breakBefore: sections.isEmpty ? nil : .sourceBoundary, points: segment.points))
        }
        return TrackGeometry(activityID: track.activityID, sourceRevision: track.sourceRevision, sections: sections)
    }
}
