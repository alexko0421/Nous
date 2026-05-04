import Foundation

protocol AgentTool {
    var name: String { get }
    var description: String { get }
    var inputSchema: AgentToolSchema { get }

    func execute(
        input: AgentToolInput,
        context: AgentToolContext
    ) async throws -> AgentToolResult
}

enum AgentToolNames {
    static let searchMemory = "search_memory"
    static let recallRecentConversations = "recall_recent_conversations"
    static let findContradictions = "find_contradictions"
    static let searchConversationsByTopic = "search_conversations_by_topic"
    static let readNote = "read_note"
    static let loadSkill = "loadSkill"

    static let standard = [
        searchMemory,
        recallRecentConversations,
        findContradictions,
        searchConversationsByTopic,
        readNote,
        loadSkill
    ]
}

struct AgentToolContext: Equatable, Sendable {
    let conversationId: UUID
    let projectId: UUID?
    let currentNodeId: UUID
    let currentMessage: String
    let activeQuickActionMode: QuickActionMode?
    let indexedSkillIds: Set<UUID>
    let excludeNodeIds: Set<UUID>
    let allowedReadNodeIds: Set<UUID>
    let maxToolResultCharacters: Int

    init(
        conversationId: UUID,
        projectId: UUID?,
        currentNodeId: UUID,
        currentMessage: String,
        activeQuickActionMode: QuickActionMode? = nil,
        indexedSkillIds: Set<UUID> = [],
        excludeNodeIds: Set<UUID>,
        allowedReadNodeIds: Set<UUID>,
        maxToolResultCharacters: Int
    ) {
        self.conversationId = conversationId
        self.projectId = projectId
        self.currentNodeId = currentNodeId
        self.currentMessage = currentMessage
        self.activeQuickActionMode = activeQuickActionMode
        self.indexedSkillIds = indexedSkillIds
        self.excludeNodeIds = excludeNodeIds
        self.allowedReadNodeIds = allowedReadNodeIds
        self.maxToolResultCharacters = maxToolResultCharacters
    }
}

struct AgentToolInput {
    private let raw: [String: Any]

    init(raw: [String: Any]) {
        self.raw = raw
    }

    init(argumentsJSON: String) throws {
        guard let data = argumentsJSON.data(using: .utf8) else {
            throw AgentToolError.invalidArgument("arguments")
        }
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AgentToolError.invalidArgument("arguments")
        }
        guard let object = decoded as? [String: Any] else {
            throw AgentToolError.invalidArgument("arguments")
        }
        self.raw = object
    }

    func string(_ key: String) -> String? {
        raw[key] as? String
    }

    func requiredString(_ key: String) throws -> String {
        guard raw.keys.contains(key) else { throw AgentToolError.missingArgument(key) }
        guard let value = string(key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.invalidArgument(key)
        }
        return value
    }

    func integer(_ key: String) -> Int? {
        if let int = raw[key] as? Int { return int }
        if let double = raw[key] as? Double { return Int(double) }
        return nil
    }

    func boundedInteger(_ key: String, default defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        guard raw.keys.contains(key) else { return defaultValue }
        guard let value = integer(key) else { throw AgentToolError.invalidArgument(key) }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    func canonicalJSONString() -> String {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

enum AgentToolError: LocalizedError, Equatable {
    case missingArgument(String)
    case invalidArgument(String)
    case notFound(String)
    case unauthorized(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return "Missing required argument: \(name)."
        case .invalidArgument(let name):
            return "Invalid argument: \(name)."
        case .notFound(let value):
            return "\(value) was not found."
        case .unauthorized(let value):
            return "\(value) is outside the readable scope for this turn."
        case .unavailable(let value):
            return value
        }
    }
}

struct AgentToolResult: Equatable, Sendable {
    let summary: String
    let traceContent: String
    let discoveredNodeIds: Set<UUID>

    init(summary: String, traceContent: String? = nil, discoveredNodeIds: Set<UUID> = []) {
        self.summary = summary
        self.traceContent = traceContent ?? summary
        self.discoveredNodeIds = discoveredNodeIds
    }
}

struct AgentToolDeclaration: Encodable, Equatable, Sendable {
    let type: String = "function"
    let function: AgentToolFunctionDeclaration
}

struct AgentToolFunctionDeclaration: Encodable, Equatable, Sendable {
    let name: String
    let description: String
    let parameters: AgentToolSchema
}

struct AgentToolSchema: Encodable, Equatable, Sendable {
    let type: String = "object"
    let properties: [String: AgentToolSchemaProperty]
    let required: [String]
    let additionalProperties: Bool = false
}

struct AgentToolSchemaProperty: Encodable, Equatable, Sendable {
    enum ValueType: String, Encodable, Sendable {
        case string
        case integer
    }

    let type: ValueType
    let description: String
}

enum AgentRawNodeReadAuthorizer {
    static func canReadRawNode(
        _ node: NousNode,
        context: AgentToolContext,
        allowAlreadyDiscoveredIds: Bool
    ) -> Bool {
        if node.id == context.currentNodeId { return true }
        if allowAlreadyDiscoveredIds && context.allowedReadNodeIds.contains(node.id) { return true }
        if let contextProjectId = context.projectId,
           let nodeProjectId = node.projectId,
           nodeProjectId == contextProjectId {
            return true
        }
        return false
    }
}

protocol MemoryEntrySearchProviding {
    func searchActiveMemoryEntries(
        query: String,
        projectId: UUID?,
        conversationId: UUID,
        limit: Int
    ) throws -> [MemoryEntry]
}

protocol RecentConversationMemoryProviding {
    func fetchRecentConversationMemories(limit: Int, excludingId: UUID?) throws -> [(title: String, memory: String)]
}

protocol ContradictionFactProviding {
    func contradictionRecallFacts(projectId: UUID?, conversationId: UUID) throws -> [MemoryFactEntry]

    func annotateContradictionCandidates(
        currentMessage: String,
        facts: [MemoryFactEntry],
        maxCandidates: Int
    ) -> [UserMemoryCore.AnnotatedContradictionFact]
}

protocol NodeReading {
    func fetchNode(id: UUID) throws -> NousNode?
}
