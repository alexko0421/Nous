import Foundation

struct AgentTraceRecord: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case toolCall
        case toolResult
        case toolError
        case capReached
    }

    enum ToolOutcome: String, Codable, Sendable {
        case success
        case failure
    }

    enum ToolErrorCategory: String, Codable, CaseIterable, Sendable {
        case invalidArguments = "invalid_arguments"
        case unauthorized
        case notFound = "not_found"
        case timeout
        case providerError = "provider_error"
        case unexpectedEnvironment = "unexpected_environment"
        case unknown
    }

    let id: UUID
    let kind: Kind
    let toolName: String?
    let title: String
    let detail: String
    let inputJSON: String?
    let createdAt: Date
    let provider: LLMProvider?
    let quickActionMode: QuickActionMode?
    let durationMilliseconds: Int?
    let iteration: Int?
    let outcome: ToolOutcome?
    let errorCategory: ToolErrorCategory?

    init(
        id: UUID = UUID(),
        kind: Kind,
        toolName: String? = nil,
        title: String,
        detail: String,
        inputJSON: String? = nil,
        createdAt: Date = Date(),
        provider: LLMProvider? = nil,
        quickActionMode: QuickActionMode? = nil,
        durationMilliseconds: Int? = nil,
        iteration: Int? = nil,
        outcome: ToolOutcome? = nil,
        errorCategory: ToolErrorCategory? = nil
    ) {
        self.id = id
        self.kind = kind
        self.toolName = toolName
        self.title = title
        self.detail = detail
        self.inputJSON = inputJSON
        self.createdAt = createdAt
        self.provider = provider
        self.quickActionMode = quickActionMode
        self.durationMilliseconds = durationMilliseconds
        self.iteration = iteration
        self.outcome = outcome
        self.errorCategory = errorCategory
    }
}

enum AgentTraceCodec {
    static func encode(_ records: [AgentTraceRecord]) -> String? {
        guard !records.isEmpty,
              let data = try? JSONEncoder().encode(records) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> [AgentTraceRecord] {
        guard let json,
              let data = json.data(using: .utf8),
              let records = try? JSONDecoder().decode([AgentTraceRecord].self, from: data) else {
            return []
        }
        return records
    }
}

extension Message {
    var decodedAgentTraceRecords: [AgentTraceRecord] {
        AgentTraceCodec.decode(agentTraceJson)
    }
}
