import Foundation

struct GlobalMemory: Codable {
    var content: String
    var updatedAt: Date

    init(content: String = "", updatedAt: Date = Date()) {
        self.content = content
        self.updatedAt = updatedAt
    }
}

struct ProjectMemory: Codable {
    var projectId: UUID
    var content: String
    var updatedAt: Date

    init(projectId: UUID, content: String = "", updatedAt: Date = Date()) {
        self.projectId = projectId
        self.content = content
        self.updatedAt = updatedAt
    }
}

struct ConversationMemory: Codable {
    var nodeId: UUID
    var content: String
    var updatedAt: Date

    init(nodeId: UUID, content: String = "", updatedAt: Date = Date()) {
        self.nodeId = nodeId
        self.content = content
        self.updatedAt = updatedAt
    }
}
