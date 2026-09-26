extension Geo {
    /// Produces map geometry for one timeline entry without changing observations or joining source sections.
    static func selectedGeometry(in geometry: TrackGeometry, entry: ActivityTimelineEntry) -> TrackGeometry {
        var sections: [TrackSection] = []
        if entry.startedAt < entry.endedAt {
            for section in geometry.sections {
                var points: [TrackPoint] = []
                func finish() {
                    if points.count >= 2 {
                        sections.append(TrackSection(sourceSegmentID: section.sourceSegmentID,
                            breakBefore: sections.isEmpty ? nil : .sourceBoundary, points: points))
                    }
                    points.removeAll(keepingCapacity: true)
                }
                for (start, end) in zip(section.points, section.points.dropFirst()) {
                    guard start.recordedAt < end.recordedAt else { finish(); continue }
                    let lower = max(entry.startedAt, start.recordedAt)
                    let upper = min(entry.endedAt, end.recordedAt)
                    guard lower < upper else { continue }
                    let a = selectedPoint(at: lower, from: start, to: end)
                    let b = selectedPoint(at: upper, from: start, to: end)
                    if points.last != a {
                        finish()
                        points.append(a)
                    }
                    points.append(b)
                }
                finish()
            }
        }
        return TrackGeometry(activityID: geometry.activityID, sourceRevision: geometry.sourceRevision, sections: sections)
    }

    private static func selectedPoint(at time: Timestamp, from start: TrackPoint, to end: TrackPoint) -> TrackPoint {
        if time == start.recordedAt { return start }
        if time == end.recordedAt { return end }
        let fraction = Double(time.millisecondsSince1970 - start.timestampMilliseconds) / Double(end.timestampMilliseconds - start.timestampMilliseconds)
        var longitudeDelta = end.longitude - start.longitude
        if longitudeDelta > 180 { longitudeDelta -= 360 }
        if longitudeDelta < -180 { longitudeDelta += 360 }
        var longitude = start.longitude + longitudeDelta * fraction
        if longitude > 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }
        let latitude = min(90, max(-90, start.latitude + (end.latitude - start.latitude) * fraction))
        var elevation: Double?
        if let a = start.elevationMeters, let b = end.elevationMeters {
            let interpolated = a * (1 - fraction) + b * fraction
            if interpolated.isFinite { elevation = interpolated }
        }
        // The requested timestamp lies inside two validated observations.
        return try! TrackPoint(timestampMilliseconds: time.millisecondsSince1970, latitude: latitude, longitude: longitude, elevationMeters: elevation)
    }
}
