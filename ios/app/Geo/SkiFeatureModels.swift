import Foundation

struct SkiFeatureSource: Codable, Hashable, Sendable {
    let type: String
    let id: String

    init(type: String, id: String) {
        self.type = type
        self.id = id
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        if let text = try? values.decode(String.self, forKey: .id) {
            id = text
        } else {
            id = String(try values.decode(Int64.self, forKey: .id))
        }
    }
}

/// Names and upstream identities are stored with history, independent of later dataset updates.
struct SkiResort: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String?
    let sources: [SkiFeatureSource]

    var displayName: String { name?.nonemptySkiLabel ?? "Unnamed ski area" }
}

struct SkiFeatureIdentity: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let kind: ActivityTimelineKind
    let sources: [SkiFeatureSource]
    let resorts: [SkiResort]
}

struct SkiFeature: Equatable, Sendable {
    let identity: SkiFeatureIdentity
    let coordinates: [Coordinate]
}

struct SkiFeatureMatch: Codable, Equatable, Sendable {
    let feature: SkiFeatureIdentity
    let startedAt: Timestamp
    let endedAt: Timestamp
    /// A geometric match score, not a calibrated probability or a sampling-quality rating.
    let confidence: Double
}

struct SkiTimelineMatches: Codable, Equatable, Sendable {
    let datasetVersion: String?
    /// Each list corresponds to the timeline entry at the same index, in traversal order.
    let entries: [[SkiFeatureMatch]]
    /// Includes overlapping ski-area groups; this is not a count of separately visited resorts.
    let resorts: [SkiResort]
    var failure: String? = nil
}

private extension String {
    var nonemptySkiLabel: String? {
        let text = trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
