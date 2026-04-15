import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
}

enum ConversationMode: String, Codable, CaseIterable {
    case general
    case business
    case direction
    case brainstorm
    case mentalHealth = "mental_health"

    var label: String {
        switch self {
        case .general:      return "General"
        case .business:     return "Business"
        case .direction:    return "Direction"
        case .brainstorm:   return "Brain Storm"
        case .mentalHealth: return "Mental Health"
        }
    }
}

struct Message: Identifiable, Codable {
    let id: UUID
    let nodeId: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date

    init(
        id: UUID = UUID(),
        nodeId: UUID,
        role: MessageRole,
        content: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.nodeId = nodeId
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}
