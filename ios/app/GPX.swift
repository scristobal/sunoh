import Foundation

/// The exchange format contains observations only. Statistics never enter this model.
struct GPXSegment: Equatable, Sendable { let points: [TrackPoint] }

struct GPXTrack: Equatable, Sendable {
    let segments: [GPXSegment]

    func validate() throws {
        guard !segments.isEmpty else { throw GPXError.invalid("The file contains an empty track.") }
        var previous: Int64?
        for segment in segments {
            guard !segment.points.isEmpty else { throw GPXError.invalid("The file contains an empty track segment.") }
            for point in segment.points {
                guard point.timestampMilliseconds <= GPX.maximumTimestamp else {
                    throw GPXError.invalid("A track point has an invalid coordinate, altitude, or timestamp.")
                }
                guard previous.map({ point.timestampMilliseconds > $0 }) ?? true else {
                    throw GPXError.invalid("Each track must have distinct timestamps in increasing order, including across segments.")
                }
                previous = point.timestampMilliseconds
            }
        }
    }
}

enum GPXError: LocalizedError, Equatable {
    case invalid(String)
    case tooLarge
    case noTracks

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .tooLarge: "This GPX file is too large. Import files of up to 50 MB and 250,000 points separately."
        case .noTracks: "No recorded tracks were found. Choose a GPX recording with a timestamp on every point."
        }
    }
}

enum GPX {
    static let maximumBytes = 50 * 1_024 * 1_024
    static let maximumPoints = 250_000
    static let maximumTimestamp: Int64 = 253_402_300_799_999 // End of year 9999, in milliseconds.
    static let documentStart = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Sunō\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n".utf8)
    static let documentEnd = Data("</gpx>\n".utf8)

    static func decode(_ data: Data) throws -> [GPXTrack] {
        guard data.count <= maximumBytes else { throw GPXError.tooLarge }
        try Task.checkCancellation()
        let delegate = GPXParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        let parsed = parser.parse()
        if let error = delegate.failure { throw error }
        guard parsed else { throw GPXError.invalid("The file is not valid GPX XML.") }
        guard !delegate.tracks.isEmpty else { throw GPXError.noTracks }
        return delegate.tracks
    }

    static func encode(_ track: GPXTrack) throws -> Data {
        try documentStart + encodeTrack(track) + documentEnd
    }

    /// One track fragment allows full-history exports to stream to disk without
    /// keeping every activity's samples or the entire XML document in memory.
    static func encodeTrack(_ track: GPXTrack) throws -> Data {
        try track.validate()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var xml = "  <trk>"
        for segment in track.segments {
            xml += "\n    <trkseg>"
            for point in segment.points {
                try Task.checkCancellation()
                xml += "\n      <trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\">"
                if let elevationMeters = point.elevationMeters { xml += "<ele>\(elevationMeters)</ele>" }
                let date = Date(timeIntervalSince1970: Double(point.timestampMilliseconds) / 1_000)
                xml += "<time>\(formatter.string(from: date))</time></trkpt>"
            }
            xml += "\n    </trkseg>"
        }
        xml += "\n  </trk>\n"
        return Data(xml.utf8)
    }
}

private final class GPXParser: NSObject, XMLParserDelegate {
    private(set) var tracks: [GPXTrack] = []
    private(set) var failure: Error?
    private var path: [String] = []
    private var namespace: String?
    private var segments: [GPXSegment] = []
    private var points: [TrackPoint] = []
    private var point: Point?
    private var text = ""
    private var pointCount = 0
    private let fractional = ISO8601DateFormatter()
    private let whole = ISO8601DateFormatter()

    private struct Point {
        let latitude: Double
        let longitude: Double
        var elevationMeters: Double?
        var timestamp: Int64?
    }

    override init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        whole.formatOptions = [.withInternetDateTime]
        super.init()
    }

    private var isPointField: Bool {
        path == ["gpx", "trk", "trkseg", "trkpt", "ele"]
            || path == ["gpx", "trk", "trkseg", "trkpt", "time"]
    }

    private func fail(_ parser: XMLParser, _ error: Error) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        guard !Task.isCancelled else { fail(parser, CancellationError()); return }
        guard path.count < 32 else { fail(parser, GPXError.invalid("The GPX XML is nested too deeply.")); return }
        if path.isEmpty {
            let version = attributes["version"]
            guard elementName == "gpx", version == "1.0" || version == "1.1",
                  namespaceURI == nil || namespaceURI == "" || namespaceURI == "http://www.topografix.com/GPX/\(version == "1.0" ? "1/0" : "1/1")" else {
                fail(parser, GPXError.invalid("Choose a GPX 1.0 or 1.1 track recording.")); return
            }
            namespace = namespaceURI
        }
        if isPointField {
            fail(parser, GPXError.invalid("Track timestamps and altitude must contain plain values.")); return
        }
        // Namespace and full path checks keep metadata/extensions out of recorded samples.
        path.append(namespaceURI == namespace ? elementName : "")
        switch path {
        case ["gpx", "trk"]: segments = []
        case ["gpx", "trk", "trkseg"]: points = []
        case ["gpx", "trk", "trkseg", "trkpt"]:
            pointCount += 1
            guard pointCount <= GPX.maximumPoints else { fail(parser, GPXError.tooLarge); return }
            guard let lat = attributes["lat"].flatMap(Double.init), lat.isFinite, (-90...90).contains(lat),
                  let lon = attributes["lon"].flatMap(Double.init), lon.isFinite, (-180...180).contains(lon) else {
                fail(parser, GPXError.invalid("A track point has missing or invalid coordinates.")); return
            }
            point = Point(latitude: lat, longitude: lon)
        default: break
        }
        if isPointField { text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isPointField else { return }
        text += string
        if text.count > 128 { fail(parser, GPXError.invalid("A track point contains an invalid value.")) }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else {
            fail(parser, GPXError.invalid("The GPX text is not valid UTF-8.")); return
        }
        self.parser(parser, foundCharacters: string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        defer { if !path.isEmpty { path.removeLast() } }
        guard failure == nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch path {
        case ["gpx", "trk", "trkseg", "trkpt", "ele"]:
            guard point?.elevationMeters == nil, let elevationMeters = Double(value), elevationMeters.isFinite else {
                fail(parser, GPXError.invalid("A track point has invalid or repeated altitude.")); return
            }
            point?.elevationMeters = elevationMeters
        case ["gpx", "trk", "trkseg", "trkpt", "time"]:
            guard point?.timestamp == nil, let date = fractional.date(from: value) ?? whole.date(from: value) else {
                fail(parser, GPXError.invalid("A track point has an invalid or repeated timestamp.")); return
            }
            let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
            guard milliseconds.isFinite, milliseconds >= 0, milliseconds <= Double(GPX.maximumTimestamp) else {
                fail(parser, GPXError.invalid("A track timestamp is outside the supported date range.")); return
            }
            point?.timestamp = Int64(milliseconds)
        case ["gpx", "trk", "trkseg", "trkpt"]:
            guard let point, let timestamp = point.timestamp else {
                fail(parser, GPXError.invalid("Every track point needs a timestamp. No activities were imported.")); return
            }
            do { points.append(try TrackPoint(timestampMilliseconds: timestamp, latitude: point.latitude,
                                 longitude: point.longitude, elevationMeters: point.elevationMeters)) }
            catch { fail(parser, error); return }
            self.point = nil
        case ["gpx", "trk", "trkseg"]:
            guard !points.isEmpty else { fail(parser, GPXError.invalid("The file contains an empty track segment.")); return }
            segments.append(GPXSegment(points: points))
        case ["gpx", "trk"]:
            let track = GPXTrack(segments: segments)
            do { try track.validate(); tracks.append(track) }
            catch { fail(parser, error) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        fail(parser, GPXError.invalid("GPX files with custom XML entities are not supported."))
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        fail(parser, GPXError.invalid("GPX files with external XML entities are not supported."))
    }
}
