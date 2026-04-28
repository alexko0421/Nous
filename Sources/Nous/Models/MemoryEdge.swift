import Foundation

enum MemoryEdgeType: String, Codable, CaseIterable {
    case derivedFrom = "derived_from"
    case about
    case belongsToProject = "belongs_to_project"
    case because
    case supports
    case contradicts
    case supersedes
    case refines
    case rejected
    case replacedBy = "replaced_by"
    case dependsOn = "depends_on"
    case causedBy = "caused_by"
    case resultedIn = "resulted_in"
    case happenedBefore = "happened_before"
    case happenedAfter = "happened_after"
    case similarTo = "similar_to"
}

struct MemoryEdge: Identifiable, Codable, Equatable {
    let id: UUID
    let fromAtomId: UUID
    let toAtomId: UUID
    var type: MemoryEdgeType
    var weight: Double
    let createdAt: Date
    var sourceMessageId: UUID?

    init(
        id: UUID = UUID(),
        fromAtomId: UUID,
        toAtomId: UUID,
        type: MemoryEdgeType,
        weight: Double = 1.0,
        createdAt: Date = Date(),
        sourceMessageId: UUID? = nil
    ) {
        self.id = id
        self.fromAtomId = fromAtomId
        self.toAtomId = toAtomId
        self.type = type
        self.weight = weight
        self.createdAt = createdAt
        self.sourceMessageId = sourceMessageId
    }
}
