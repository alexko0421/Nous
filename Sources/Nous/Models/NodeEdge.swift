import Foundation

enum EdgeOrigin: String, Codable {
    case semantic
    case manual
    case shared
}

typealias EdgeType = EdgeOrigin

enum GalaxyRelationKind: String, Codable, CaseIterable {
    case topicSimilarity = "topic_similarity"
    case samePattern = "same_pattern"
    case tension
    case supports
    case contradicts
    case causeEffect = "cause_effect"
}

struct NodeEdge: Identifiable, Codable {
    let id: UUID
    let sourceId: UUID
    let targetId: UUID
    var strength: Float
    let type: EdgeType
    var relationKind: GalaxyRelationKind
    var confidence: Float
    var explanation: String?
    var sourceEvidence: String?
    var targetEvidence: String?
    var sourceAtomId: UUID?
    var targetAtomId: UUID?

    init(
        id: UUID = UUID(),
        sourceId: UUID,
        targetId: UUID,
        strength: Float,
        type: EdgeType,
        relationKind: GalaxyRelationKind? = nil,
        confidence: Float? = nil,
        explanation: String? = nil,
        sourceEvidence: String? = nil,
        targetEvidence: String? = nil,
        sourceAtomId: UUID? = nil,
        targetAtomId: UUID? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.targetId = targetId
        self.strength = strength
        self.type = type
        self.relationKind = relationKind ?? Self.defaultRelationKind(for: type)
        self.confidence = confidence ?? strength
        self.explanation = explanation
        self.sourceEvidence = sourceEvidence
        self.targetEvidence = targetEvidence
        self.sourceAtomId = sourceAtomId
        self.targetAtomId = targetAtomId
    }

    private static func defaultRelationKind(for _: EdgeType) -> GalaxyRelationKind {
        .topicSimilarity
    }
}
