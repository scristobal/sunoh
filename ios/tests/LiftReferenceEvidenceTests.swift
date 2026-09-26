import Foundation
import Testing
@testable import Sunoh

struct LiftReferenceEvidenceTests {
    @Test(arguments: [false, true]) func sustainedFullReferenceTraversalIdentifiesFlatRidesWithoutAnAscent(missingElevation: Bool) throws {
        let points = try straight(seconds: 120, elevation: { _ in missingElevation ? nil : 1_000 })
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let baseline = SkiActivityDetector.analyze(geometry)
        let result = SkiActivityDetector.analyze(geometry, liftFeatures: [try feature()])
        #expect(baseline.lifts.isEmpty)
        #expect(result.lifts == [passage(0, 120)])
        #expect(result.runs.isEmpty)
        #expect(geometry.sections[0].points == points)
    }

    @Test func continuousTwentySecondSamplingStillSupportsAReferenceRide() throws {
        let points = try straight(seconds: 120, cadence: 20)
        #expect(SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: points)]), liftFeatures: [try feature()]).lifts == [passage(0, 120)])
    }

    @Test func referenceEvidenceConnectsAscentAcrossLongFlatAndBriefDescendingTravel() throws {
        let points = try straight(seconds: 360, elevation: { time in
            if time <= 120 { return 1_000 + Double(time) }
            if time <= 240 { return 1_120 }
            if time <= 270 { return 1_120 - Double(time - 240) * 0.5 }
            return 1_105 + Double(time - 270)
        })
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        #expect(SkiActivityDetector.analyze(geometry).liftCount == 2)
        let result = SkiActivityDetector.analyze(geometry, liftFeatures: [try feature(length: 1_080)])
        #expect(result.lifts == [passage(0, 360)])
        #expect(result.runs.isEmpty)
    }

    @Test func missingWrongAndAmbiguousReferencesNeverVetoTrackOnlyLifts() throws {
        let points = try straight(seconds: 120, elevation: { 1_000 + Double($0) })
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        let baseline = SkiActivityDetector.analyze(geometry)
        #expect(baseline.lifts == [passage(0, 120)])
        let cases = [[], [try feature(y: 200)], [try feature(id: "left", y: -3), try feature(id: "right", y: 3)], [try feature(kind: .run)]]
        for references in cases { #expect(SkiActivityDetector.analyze(geometry, liftFeatures: references) == baseline) }
    }

    @Test func shortCrossingsAndPartialParallelTraversalsDoNotCreateLifts() throws {
        let short = try straight(seconds: 30)
        #expect(SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: short)]), liftFeatures: [try feature(length: 90)]).lifts.isEmpty)
        let points = try straight(seconds: 120)
        let geometry = fixtureGeometry([GPXSegment(points: points)])
        #expect(SkiActivityDetector.analyze(geometry, liftFeatures: [try feature(length: 1_000)]).lifts.isEmpty)
        let crossing = SkiFeature(identity: identity("crossing"), coordinates: [try point(0, x: 180, y: -500).coordinate, try point(0, x: 180, y: 500).coordinate])
        #expect(SkiActivityDetector.analyze(geometry, liftFeatures: [crossing]).lifts.isEmpty)
        #expect(SkiActivityDetector.analyze(geometry, liftFeatures: [try feature(id: "left", y: -3), try feature(id: "right", y: 3)]).lifts.isEmpty)
    }

    @Test(arguments: [0.0, 1.5, 18.0]) func stationaryWalkingAndFastTravelCannotUseGeometryAlone(speed: Double) throws {
        let points = try straight(seconds: 120, speed: speed)
        let result = SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: points)]), liftFeatures: [try feature(length: max(360, speed * 120))])
        #expect(result.lifts.isEmpty)
    }

    @Test func erraticSpeedAndSustainedDescentRemainRunsUnderLiftGeometry() throws {
        var x = 0.0
        var points = [try point(0, x: x)]
        for index in 1...24 {
            x += index.isMultiple(of: 2) ? 10 : 50
            points.append(try point(index * 5, x: x))
        }
        #expect(SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: points)]), liftFeatures: [try feature(length: x)]).lifts.isEmpty)
        let descending = try straight(seconds: 120, elevation: { 1_000 - Double($0) * 0.5 })
        #expect(SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: descending)]), liftFeatures: [try feature()]).lifts.isEmpty)
    }

    @Test func mildBriefLocationOutlierCanBridgeButImpossibleOrSparseJumpsCannot() throws {
        let mild = try (0...24).map { try point($0 * 5, x: Double($0) * 15, y: $0 == 12 ? 30 : 0) }
        #expect(SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: mild)]), liftFeatures: [try feature()]).lifts == [passage(0, 120)])
        let impossible = try (0...24).map { try point($0 * 5, x: Double($0) * 15, y: $0 == 12 ? 300 : 0) }
        #expect(SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: impossible)]), liftFeatures: [try feature()]).lifts.isEmpty)
        let sparse = try straight(seconds: 120).filter { $0.timestampMilliseconds <= 40_000 || $0.timestampMilliseconds >= 80_000 }
        #expect(SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: sparse)]), liftFeatures: [try feature()]).lifts.isEmpty)
    }

    @Test func repeatedUnsupportedSnippetsCannotTransitivelyAbsorbTheWholeRide() throws {
        let points = try (0...44).map { index in
            try point(index * 5, x: Double(index) * 15, y: [10, 22, 34].contains(index) ? 30 : 0)
        }
        let result = SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: points)]), liftFeatures: [try feature(length: 660)])
        #expect(!result.lifts.contains { $0.startedAt <= 170_000 && $0.endedAt >= 175_000 })
        #expect(result.runs.contains { $0.startedAt <= 170_000 && $0.endedAt >= 175_000 })
    }

    @Test func reversalStaysADistinctPassageAfterCombiningWithTheBaseline() throws {
        let outward = try straight(seconds: 120)
        let returning = try (1...24).map { try point(120 + $0 * 5, x: 360 - Double($0) * 15) }
        let result = SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: outward + returning)]), liftFeatures: [try feature()])
        #expect(result.lifts == [passage(0, 120), passage(120, 240)])
    }

    @Test func sourceAndInvalidTimeBoundariesKeepReferenceRidesSeparate() throws {
        let first = try straight(seconds: 120)
        let second = try straight(seconds: 120, start: 130)
        let sources = fixtureGeometry([GPXSegment(points: first), GPXSegment(points: second)])
        #expect(SkiActivityDetector.analyze(sources, liftFeatures: [try feature()]).lifts == [passage(0, 120), passage(130, 250)])
        let reversed = try straight(seconds: 120, start: 100)
        let invalid = fixtureGeometry([GPXSegment(points: first + reversed)])
        #expect(SkiActivityDetector.analyze(invalid, liftFeatures: [try feature()]).lifts == [passage(0, 120), passage(100, 220)])
    }

    @Test func terminalWaitsStayRunWhileSupportedMidrideStopsStayInsideLift() throws {
        var points = try (0...4).map { try point($0 * 5, x: 0) }
        points += try (1...24).map { try point(20 + $0 * 5, x: Double($0) * 15) }
        points += try (1...24).map { try point(140 + $0 * 5, x: 360) }
        points += try (1...24).map { try point(260 + $0 * 5, x: 360 + Double($0) * 15) }
        points += try (1...4).map { try point(380 + $0 * 5, x: 720) }
        let result = SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: points)]), liftFeatures: [try feature(length: 720)])
        #expect(result.lifts == [passage(20, 380)])
        #expect(result.runs == [passage(0, 20), passage(380, 400)])
    }

    @Test func changingLiftFeaturesCannotBridgeAWalkingTransfer() throws {
        var points = try straight(seconds: 120)
        points += try (1...2).map { try point(120 + $0 * 5, x: 360 + Double($0) * 5) }
        points += try (1...24).map { try point(130 + $0 * 5, x: 370 + Double($0) * 15) }
        let second = SkiFeature(identity: identity("second"), coordinates: [try point(0, x: 370).coordinate, try point(0, x: 730).coordinate])
        let result = SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: points)]), liftFeatures: [try feature(), second])
        #expect(result.lifts == [passage(0, 120), passage(130, 250)])
        #expect(result.runs == [passage(120, 130)])
    }

    @Test func abruptFeatureDirectionChangeAtAStationKeepsRidesSeparate() throws {
        var points = try straight(seconds: 120)
        points += try (1...24).map { try point(120 + $0 * 5, x: 360, y: Double($0) * 15) }
        let second = SkiFeature(identity: identity("second"), coordinates: [try point(0, x: 360).coordinate, try point(0, x: 360, y: 360).coordinate])
        let result = SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: points)]), liftFeatures: [try feature(), second])
        #expect(result.lifts == [passage(0, 120), passage(120, 240)])
    }

    @Test func flatAltitudeNoiseAndAnIsolatedSpikeDoNotEraseReferenceEvidence() throws {
        let noisy = try straight(seconds: 120, elevation: { $0.isMultiple(of: 10) ? 1_003 : 997 })
        #expect(SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: noisy)]), liftFeatures: [try feature()]).lifts == [passage(0, 120)])
        let spike = try straight(seconds: 240, elevation: { time in
            if time < 120 { return 1_000 + Double(time) }
            return time == 130 ? 1_125 : 1_120
        })
        #expect(SkiActivityDetector.analyze(fixtureGeometry([GPXSegment(points: spike)]), liftFeatures: [try feature(length: 720)]).lifts == [passage(0, 240)])
    }

    @Test func isolatedDenseOrSparseEndpointAltitudeSpikesCannotAnchorPartialTraversal() throws {
        let cases: [[TrackPoint]] = [
            try straight(seconds: 120, elevation: { $0 == 120 ? 1_040 : 1_000 }),
            try straight(seconds: 120, elevation: { $0 == 0 ? 960 : 1_000 }),
            try straight(seconds: 120, elevation: { $0 == 120 ? 1_040 : ($0 == 0 || $0 == 60 ? 1_000 : nil) })
        ]
        for points in cases {
            let geometry = fixtureGeometry([GPXSegment(points: points)])
            #expect(SkiActivityDetector.analyze(geometry).lifts.isEmpty)
            #expect(SkiActivityDetector.analyze(geometry, liftFeatures: [try feature(length: 1_000)]).lifts.isEmpty)
        }
    }

    private func straight(seconds: Int, speed: Double = 3, cadence: Int = 5, start: Int = 0, elevation: (Int) -> Double? = { _ in 1_000 }) throws -> [TrackPoint] {
        try stride(from: 0, through: seconds, by: cadence).map { try point(start + $0, x: Double($0) * speed, elevation: elevation($0)) }
    }

    private func feature(id: String = "lift", kind: ActivityTimelineKind = .lift, length: Double = 360, y: Double = 0) throws -> SkiFeature {
        SkiFeature(identity: identity(id, kind: kind), coordinates: [try point(0, x: 0, y: y).coordinate, try point(0, x: length, y: y).coordinate])
    }

    private func identity(_ id: String, kind: ActivityTimelineKind = .lift) -> SkiFeatureIdentity {
        SkiFeatureIdentity(id: id, kind: kind, sources: [], resorts: [])
    }

    private func point(_ seconds: Int, x: Double, y: Double = 0, elevation: Double? = 1_000) throws -> TrackPoint {
        try TrackPoint(timestampMilliseconds: Int64(seconds) * 1_000, latitude: y * 180 / (.pi * 6_371_000), longitude: x * 180 / (.pi * 6_371_000), elevationMeters: elevation)
    }

    private func passage(_ start: Int, _ end: Int) -> SkiActivityDetector.Passage {
        .init(startedAt: Timestamp(millisecondsSince1970: Int64(start) * 1_000), endedAt: Timestamp(millisecondsSince1970: Int64(end) * 1_000))
    }
}
