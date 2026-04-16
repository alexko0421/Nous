import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
}

struct CardPayload: Codable, Equatable {
    let framing: String
    let options: [String]
}

struct Message: Identifiable, Codable {
    let id: UUID
    let nodeId: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    let cardPayload: CardPayload?

    init(
        id: UUID = UUID(),
        nodeId: UUID,
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        cardPayload: CardPayload? = nil
    ) {
        self.id = id
        self.nodeId = nodeId
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.cardPayload = cardPayload
    }
}
