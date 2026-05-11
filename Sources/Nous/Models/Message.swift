import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
}

struct Message: Identifiable, Codable {
    let id: UUID
    let nodeId: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    var thinkingContent: String?
    var agentTraceJson: String?
    var source: MessageSource
    var attachments: [AttachedFileContext]

    init(
        id: UUID = UUID(),
        nodeId: UUID,
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        thinkingContent: String? = nil,
        agentTraceJson: String? = nil,
        source: MessageSource = .typed,
        attachments: [AttachedFileContext] = []
    ) {
        self.id = id
        self.nodeId = nodeId
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.thinkingContent = thinkingContent
        self.agentTraceJson = agentTraceJson
        self.source = source
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey {
        case id, nodeId, role, content, timestamp
        case thinkingContent, agentTraceJson, source, attachments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.nodeId = try c.decode(UUID.self, forKey: .nodeId)
        self.role = try c.decode(MessageRole.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.thinkingContent = try c.decodeIfPresent(String.self, forKey: .thinkingContent)
        self.agentTraceJson = try c.decodeIfPresent(String.self, forKey: .agentTraceJson)
        self.source = try c.decodeIfPresent(MessageSource.self, forKey: .source) ?? .typed
        self.attachments = try c.decodeIfPresent([AttachedFileContext].self, forKey: .attachments) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(nodeId, forKey: .nodeId)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(thinkingContent, forKey: .thinkingContent)
        try c.encodeIfPresent(agentTraceJson, forKey: .agentTraceJson)
        try c.encode(source, forKey: .source)
        if !attachments.isEmpty {
            try c.encode(attachments, forKey: .attachments)
        }
    }
}
