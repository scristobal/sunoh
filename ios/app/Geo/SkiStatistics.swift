import Foundation

extension Geo {
    static let minimumMovingSpeedMetersPerSecond = 1.2
    static let maximumSkiSpeedMetersPerSecond = 45.0

    struct SkiStatistics: Equatable, Sendable {
        var runDistanceMeters = 0.0
        var liftDistanceMeters = 0.0
        var runElevationLossMeters = 0.0
        var liftElevationGainMeters = 0.0
        var runDurationMilliseconds: Int64 = 0
        var liftDurationMilliseconds: Int64 = 0
        var averageDownhillSpeedMetersPerSecond: Double?
        var averageLiftSpeedMetersPerSecond: Double?
        var maximumRunSpeedMetersPerSecond: Double?
        var tallestRunHeightMeters: Double?
        var longestRunDistanceMeters: Double?
        var tallestLiftHeightMeters: Double?
        var longestLiftDistanceMeters: Double?
        // Grades weight eligible horizontal distance; maxima compare whole passage averages.
        var averageRunSteepnessPercent: Double?
        var averageLiftSteepnessPercent: Double?
        var maximumRunSteepnessPercent: Double?
        var maximumLiftSteepnessPercent: Double?
    }

    /// Measures original observations within detected passages. Time includes stops and long sample intervals, but never bridges source boundaries.
    static func skiStatistics(in geometry: TrackGeometry, passages: SkiActivityDetector.Result) -> SkiStatistics {
        var measured = (passages.runs.map { MeasuredPassage(range: $0, isRun: true) }
            + passages.lifts.map { MeasuredPassage(range: $0, isRun: false) })
            .sorted { $0.range.startedAt < $1.range.startedAt }
        var firstCandidate = 0
        for section in geometry.sections {
            let stops = stationarySpans(in: section.points)
            var stopIndex = 0
            for (pointIndex, start) in section.points.enumerated() {
                while stopIndex < stops.count && stops[stopIndex].pointIndices.upperBound < pointIndex { stopIndex += 1 }
                let stationaryPoint = stopIndex < stops.count && stops[stopIndex].pointIndices.contains(pointIndex)
                while firstCandidate < measured.count && measured[firstCandidate].range.endedAt < start.recordedAt { firstCandidate += 1 }
                guard firstCandidate < measured.count else { break }
                var index = firstCandidate
                while index < measured.count && measured[index].range.startedAt <= start.recordedAt {
                    if !stationaryPoint || pointIndex == stops[stopIndex].pointIndices.lowerBound {
                        measured[index].includeElevation(start.elevationMeters)
                    }
                    index += 1
                }
                guard pointIndex + 1 < section.points.count else { continue }
                let end = section.points[pointIndex + 1]
                let milliseconds = end.timestampMilliseconds - start.timestampMilliseconds
                guard milliseconds > 0 else { continue }
                let stationaryPair = stationaryPoint && pointIndex < stops[stopIndex].pointIndices.upperBound
                let speed = distanceMeters(from: start.coordinate, to: end.coordinate) / (Double(milliseconds) / 1_000)
                index = firstCandidate
                while index < measured.count && measured[index].range.startedAt < end.recordedAt {
                    let lower = max(start.recordedAt, measured[index].range.startedAt)
                    let upper = min(end.recordedAt, measured[index].range.endedAt)
                    let overlap = upper.millisecondsSince1970 - lower.millisecondsSince1970
                    if overlap > 0 {
                        measured[index].includeMovement(speed: stationaryPair ? 0 : speed, milliseconds: overlap)
                        if !stationaryPair, let a = start.elevationMeters, let b = end.elevationMeters, a.isFinite, b.isFinite {
                            let lowerFraction = Double(lower.millisecondsSince1970 - start.timestampMilliseconds) / Double(milliseconds)
                            let upperFraction = Double(upper.millisecondsSince1970 - start.timestampMilliseconds) / Double(milliseconds)
                            let lowerElevation = a + (b - a) * lowerFraction
                            let upperElevation = a + (b - a) * upperFraction
                            measured[index].includeElevationChange(from: lowerElevation, to: upperElevation)
                            if speed >= minimumMovingSpeedMetersPerSecond, speed < maximumSkiSpeedMetersPerSecond {
                                measured[index].includeSteepness(distanceMeters: speed * Double(overlap) / 1_000,
                                                                 elevationChange: upperElevation - lowerElevation)
                            }
                        }
                    }
                    index += 1
                }
            }
        }
        var result = SkiStatistics()
        var runMovingDistance = 0.0, runMovingSeconds = 0.0
        var liftMovingDistance = 0.0, liftMovingSeconds = 0.0
        var runSteepnessDistance = 0.0, runSteepnessDescent = 0.0
        var liftSteepnessDistance = 0.0, liftSteepnessAscent = 0.0
        for passage in measured {
            if passage.isRun {
                result.runDistanceMeters += passage.distanceMeters
                result.runElevationLossMeters += passage.elevationLossMeters
                result.runDurationMilliseconds += passage.durationMilliseconds
                runMovingDistance += passage.movingDistanceMeters
                runMovingSeconds += passage.movingSeconds
                runSteepnessDistance += passage.steepnessDistanceMeters
                runSteepnessDescent += passage.steepnessDescentMeters
                if let steepness = gradePercent(verticalMeters: passage.steepnessDescentMeters, horizontalMeters: passage.steepnessDistanceMeters) {
                    result.maximumRunSteepnessPercent = max(result.maximumRunSteepnessPercent ?? steepness, steepness)
                }
                if let speed = passage.maximumSpeed { result.maximumRunSpeedMetersPerSecond = max(result.maximumRunSpeedMetersPerSecond ?? speed, speed) }
                if let low = passage.minimumElevation, let high = passage.maximumElevation {
                    result.tallestRunHeightMeters = max(result.tallestRunHeightMeters ?? 0, high - low)
                }
                if passage.durationMilliseconds > 0 {
                    result.longestRunDistanceMeters = max(result.longestRunDistanceMeters ?? 0, passage.distanceMeters)
                }
            } else {
                result.liftDistanceMeters += passage.distanceMeters
                result.liftElevationGainMeters += passage.elevationGainMeters
                result.liftDurationMilliseconds += passage.durationMilliseconds
                liftMovingDistance += passage.movingDistanceMeters
                liftMovingSeconds += passage.movingSeconds
                liftSteepnessDistance += passage.steepnessDistanceMeters
                liftSteepnessAscent += passage.steepnessAscentMeters
                if let steepness = gradePercent(verticalMeters: passage.steepnessAscentMeters, horizontalMeters: passage.steepnessDistanceMeters) {
                    result.maximumLiftSteepnessPercent = max(result.maximumLiftSteepnessPercent ?? steepness, steepness)
                }
                if let low = passage.minimumElevation, let high = passage.maximumElevation {
                    result.tallestLiftHeightMeters = max(result.tallestLiftHeightMeters ?? 0, high - low)
                }
                if passage.durationMilliseconds > 0 {
                    result.longestLiftDistanceMeters = max(result.longestLiftDistanceMeters ?? 0, passage.distanceMeters)
                }
            }
        }
        result.averageDownhillSpeedMetersPerSecond = runMovingSeconds > 0 ? runMovingDistance / runMovingSeconds : nil
        result.averageLiftSpeedMetersPerSecond = liftMovingSeconds > 0 ? liftMovingDistance / liftMovingSeconds : nil
        result.averageRunSteepnessPercent = gradePercent(verticalMeters: runSteepnessDescent, horizontalMeters: runSteepnessDistance)
        result.averageLiftSteepnessPercent = gradePercent(verticalMeters: liftSteepnessAscent, horizontalMeters: liftSteepnessDistance)
        return result
    }

    private static func gradePercent(verticalMeters: Double, horizontalMeters: Double) -> Double? {
        guard verticalMeters.isFinite, horizontalMeters.isFinite, horizontalMeters > 0 else { return nil }
        let percent = verticalMeters / horizontalMeters * 100
        return percent.isFinite ? percent : nil
    }

    private struct MeasuredPassage {
        let range: SkiActivityDetector.Passage
        let isRun: Bool
        var distanceMeters = 0.0
        var elevationGainMeters = 0.0
        var elevationLossMeters = 0.0
        var durationMilliseconds: Int64 = 0
        var movingDistanceMeters = 0.0
        var movingSeconds = 0.0
        var maximumSpeed: Double?
        var minimumElevation: Double?
        var maximumElevation: Double?
        var steepnessDistanceMeters = 0.0
        var steepnessAscentMeters = 0.0
        var steepnessDescentMeters = 0.0

        mutating func includeMovement(speed: Double, milliseconds: Int64) {
            durationMilliseconds += milliseconds
            guard speed.isFinite, speed < Geo.maximumSkiSpeedMetersPerSecond else { return }
            let seconds = Double(milliseconds) / 1_000
            distanceMeters += speed * seconds
            guard speed >= Geo.minimumMovingSpeedMetersPerSecond else { return }
            movingDistanceMeters += speed * seconds
            movingSeconds += seconds
            maximumSpeed = max(maximumSpeed ?? speed, speed)
        }

        mutating func includeElevation(_ elevation: Double?) {
            guard let elevation, elevation.isFinite else { return }
            minimumElevation = min(minimumElevation ?? elevation, elevation)
            maximumElevation = max(maximumElevation ?? elevation, elevation)
        }

        mutating func includeElevationChange(from start: Double, to end: Double) {
            includeElevation(start)
            includeElevation(end)
            let change = end - start
            guard change.isFinite else { return }
            elevationGainMeters += max(0, change)
            elevationLossMeters += max(0, -change)
        }

        mutating func includeSteepness(distanceMeters: Double, elevationChange: Double) {
            guard distanceMeters.isFinite, distanceMeters > 0, elevationChange.isFinite else { return }
            steepnessDistanceMeters += distanceMeters
            steepnessAscentMeters += max(0, elevationChange)
            steepnessDescentMeters += max(0, -elevationChange)
        }
    }
}
