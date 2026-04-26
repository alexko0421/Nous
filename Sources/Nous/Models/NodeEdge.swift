import Foundation

enum EdgeType: String, Codable {
    case semantic
    case manual
}

struct NodeEdge: Identifiable, Codable {
    let id: UUID
    let sourceId: UUID
    let targetId: UUID
    var strength: Float
    let type: EdgeType

    init(
        id: UUID = UUID(),
        sourceId: UUID,
        targetId: UUID,
        strength: Float,
        type: EdgeType
    ) {
        self.id = id
        self.sourceId = sourceId
        self.targetId = targetId
        self.strength = strength
        self.type = type
    }
}
