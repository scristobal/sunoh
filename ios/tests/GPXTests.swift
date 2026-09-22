import Foundation
import Testing
@testable import Sunoh

struct GPXTests {
    @Test func fullHistoryFileKeepsTracksSeparateAndPreservesSamples() async throws {
        let first = try GPX.decode(document(validPoint))[0]
        let second = GPXTrack(segments: [GPXSegment(points: [
            try! TrackPoint(timestampMilliseconds: 1_800_000_000_125, latitude: 48, longitude: 12, elevationMeters: nil)
        ]), GPXSegment(points: [
            try! TrackPoint(timestampMilliseconds: 1_800_000_100_999, latitude: 48.01, longitude: 12.01, elevationMeters: 1500)
        ])])
        let file = try await GPXFiles.writeAll(activityIDs: ["first", "second"]) { id in
            id == "first" ? first : second
        }
        defer { file.removeTemporaryFile() }
        #expect(file.url.lastPathComponent == "Sunoh-activities.gpx")
        #expect(try await GPXFiles.read(file.url) == [first, second])
        let xml = try String(contentsOf: file.url, encoding: .utf8)
        let tags = xml.matches(of: /<\/?([a-zA-Z][a-zA-Z0-9]*)/).map { String($0.1) }
        #expect(Set(tags) == Set(["gpx", "trk", "trkseg", "trkpt", "ele", "time"]))
    }

    @Test func failedOrCancelledFullHistoryExportRemovesPartialFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = try GPX.decode(document(validPoint))[0]
        await #expect(throws: ActivityError.self) {
            try await GPXFiles.writeAll(activityIDs: ["first", "deleted"], temporaryDirectory: root) { id in
                if id == "deleted" { throw ActivityError.missing }
                return track
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await #expect(throws: CancellationError.self) {
            try await GPXFiles.writeAll(activityIDs: ["first", "cancelled"], temporaryDirectory: root) { id in
                if id == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
                return track
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func fullHistoryExportReportsAnUnwritableDestination() async throws {
        let blockedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Data("Not a directory".utf8)
        try original.write(to: blockedRoot)
        defer { try? FileManager.default.removeItem(at: blockedRoot) }
        let track = try GPX.decode(document(validPoint))[0]
        await #expect(throws: (any Error).self) {
            try await GPXFiles.writeAll(activityIDs: ["first"], temporaryDirectory: blockedRoot) { _ in track }
        }
        #expect(try Data(contentsOf: blockedRoot) == original)
    }

    @Test func exportsOnlyObservationsAndRoundTripsMillisecondsAndSegments() throws {
        let track = GPXTrack(segments: [
            GPXSegment(points: [
                try! TrackPoint(timestampMilliseconds: 1_770_000_000_001, latitude: 47.12345678901234, longitude: 11.98765432109876, elevationMeters: 2_100.125),
                try! TrackPoint(timestampMilliseconds: 1_770_000_000_999, latitude: 47.125, longitude: 11.99, elevationMeters: nil)
            ]),
            GPXSegment(points: [try! TrackPoint(timestampMilliseconds: 1_770_000_120_123, latitude: -45, longitude: -12, elevationMeters: -1.25)])
        ])
        let data = try GPX.encode(track)
        #expect(try GPX.decode(data) == [track])
        let xml = String(decoding: data, as: UTF8.self)
        #expect(xml.contains("creator=\"Sunō\""))
        #expect(xml.contains(".001Z"))
        #expect(xml.contains(".999Z"))
        // Only these element names may be emitted, including no extensions/statistics.
        let tags = xml.matches(of: /<\/?([a-zA-Z][a-zA-Z0-9]*)/).map { String($0.1) }
        #expect(Set(tags) == Set(["gpx", "trk", "trkseg", "trkpt", "ele", "time"]))
    }

    @Test func readsSeparateTracksAndIgnoresDerivedExtensionValues() throws {
        let data = Data("""
        <g:gpx xmlns:g="http://www.topografix.com/GPX/1/1" xmlns:s="urn:example:statistics" version="1.1" creator="Fixture">
          <g:metadata><g:time>1999-01-01T00:00:00Z</g:time></g:metadata>
          <g:trk><g:name>First day</g:name><g:trkseg>
            <g:trkpt lat="47" lon="11"><g:ele>2000</g:ele><g:time>2026-02-01T10:00:00.125+01:00</g:time>
              <g:extensions><s:speed>99</s:speed><s:ele>9999</s:ele><s:time>bad</s:time></g:extensions>
            </g:trkpt>
          </g:trkseg></g:trk>
          <g:trk><g:trkseg><g:trkpt lat="48" lon="12"><g:time>2026-02-02T09:00:00Z</g:time></g:trkpt></g:trkseg></g:trk>
        </g:gpx>
        """.utf8)
        let tracks = try GPX.decode(data)
        #expect(tracks.count == 2)
        #expect(tracks[0].segments[0].points[0].elevationMeters == 2_000)
        #expect(tracks[0].segments[0].points[0].timestampMilliseconds == 1_769_936_400_125)
        #expect(tracks[1].segments[0].points[0].elevationMeters == nil)
    }

    @Test func acceptsGPX10AndUnnamespacedRecordings() throws {
        for namespace in [" xmlns=\"http://www.topografix.com/GPX/1/0\"", ""] {
            let xml = "<gpx version=\"1.0\"\(namespace)><trk><trkseg>\(validPoint)</trkseg></trk></gpx>"
            #expect(try GPX.decode(Data(xml.utf8)).count == 1)
        }
    }

    @Test(arguments: [
        "<trkpt lat=\"91\" lon=\"11\"><time>2026-02-01T09:00:00Z</time></trkpt>",
        "<trkpt lat=\"nan\" lon=\"11\"><time>2026-02-01T09:00:00Z</time></trkpt>",
        "<trkpt lat=\"47\" lon=\"11\"><ele>2000</ele></trkpt>",
        "<trkpt lat=\"47\" lon=\"11\"><time>yesterday</time></trkpt>",
        "<trkpt lat=\"47\" lon=\"11\"><time>1960-01-01T00:00:00Z</time></trkpt>",
        "<trkpt lat=\"47\" lon=\"11\"><ele>NaN</ele><time>2026-02-01T09:00:00Z</time></trkpt>",
        "<trkpt lat=\"47\" lon=\"11\"><time><value>2026-02-01T09:00:00Z</value></time></trkpt>",
        "<trkpt lat=\"47\" lon=\"11\"><time>2026-02-01T09:00:00Z</time><time>2026-02-01T09:01:00Z</time></trkpt>"
    ])
    func rejectsInvalidSamples(_ point: String) {
        #expect(throws: GPXError.self) { try GPX.decode(document(point)) }
    }

    @Test func rejectsEmptyMalformedAndNonTrackFiles() {
        for xml in ["", "<gpx", "<gpx version=\"1.1\"><trk/></gpx>",
                    "<gpx version=\"1.1\"><trk><trkseg/></trk></gpx>",
                    "<gpx version=\"1.1\"><rte><rtept lat=\"47\" lon=\"11\"/></rte></gpx>",
                    "<notgpx/>"] {
            #expect(throws: GPXError.self) { try GPX.decode(Data(xml.utf8)) }
        }
    }

    @Test func rejectsDuplicateOrDecreasingTimestampsAndInvalidLaterTracks() {
        #expect(throws: GPXError.self) { try GPX.decode(document(validPoint + validPoint)) }
        let earlier = validPoint.replacingOccurrences(of: "09:00:00", with: "08:59:59")
        #expect(throws: GPXError.self) { try GPX.decode(document(validPoint + earlier)) }
        let twoTracks = "<gpx version=\"1.1\"><trk><trkseg>\(validPoint)</trkseg></trk><trk/></gpx>"
        #expect(throws: GPXError.self) { try GPX.decode(Data(twoTracks.utf8)) }
    }

    @Test func rejectsCustomEntitiesAndOversizedInput() {
        let xml = """
        <!DOCTYPE gpx [<!ENTITY value "2000">]>
        <gpx version="1.1"><trk><trkseg><trkpt lat="47" lon="11"><ele>&value;</ele><time>2026-02-01T09:00:00Z</time></trkpt></trkseg></trk></gpx>
        """
        #expect(throws: GPXError.self) { try GPX.decode(Data(xml.utf8)) }
        #expect(throws: GPXError.tooLarge) { try GPX.decode(Data(repeating: 32, count: GPX.maximumBytes + 1)) }
    }

    @Test func cancellationStopsDecoding() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try GPX.decode(document(validPoint)) }
        }
        await task.value
    }

    @Test func fileExchangeWorksWithoutSecurityScopeForLocalFiles() async throws {
        let track = try GPX.decode(document(validPoint))[0]
        let file = try await GPXFiles.write(track)
        defer { file.removeTemporaryFile() }
        #expect(try await GPXFiles.read(file.url) == [track])
    }

    private var validPoint: String {
        "<trkpt lat=\"47\" lon=\"11\"><ele>2000</ele><time>2026-02-01T09:00:00Z</time></trkpt>"
    }

    private func document(_ points: String) -> Data {
        Data("<gpx version=\"1.1\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><trkseg>\(points)</trkseg></trk></gpx>".utf8)
    }
}
