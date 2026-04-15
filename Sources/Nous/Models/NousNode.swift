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
    var embedding: [Float]?
    var projectId: UUID?
    var isFavorite: Bool
    var mode: ConversationMode?
    var emoji: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        type: NodeType,
        title: String,
        content: String = "",
        embedding: [Float]? = nil,
        projectId: UUID? = nil,
        isFavorite: Bool = false,
        mode: ConversationMode? = nil,
        emoji: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.content = content
        self.embedding = embedding
        self.projectId = projectId
        self.isFavorite = isFavorite
        self.mode = mode
        self.emoji = emoji
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
