import Foundation

enum NodeType: String, Codable {
    case conversation
    case note
}

struct NousNode: Identifiable, Codable {
    let id: UUID
    var type: NodeType
    var title: String
    var content: String
    var emoji: String?
    var embedding: [Float]?
    var projectId: UUID?
    var isFavorite: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        type: NodeType,
        title: String,
        content: String = "",
        emoji: String? = nil,
        embedding: [Float]? = nil,
        projectId: UUID? = nil,
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.content = content
        self.emoji = emoji
        self.embedding = embedding
        self.projectId = projectId
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
