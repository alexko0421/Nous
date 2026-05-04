import Foundation

// The fixture runner compiles LLMService.swift directly, outside the main app
// target. These target-local shapes satisfy LLMService's tool-call API surface
// without pulling the whole agent runtime into the judge fixture binary.

enum AgentLoopMessage: Equatable, Sendable {
    case text(role: String, content: String)
    case assistantToolCalls(
        content: String?,
        toolCalls: [AgentToolCall],
        reasoningContent: String? = nil,
        reasoningDetailsJSON: String? = nil
    )
    case toolResult(toolCallId: String, name: String, content: String, isError: Bool)
}

struct AgentToolCall: Equatable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: String
}

struct AgentToolLLMResponse: Equatable, Sendable {
    let text: String
    let assistantMessage: AgentLoopMessage
    let toolCalls: [AgentToolCall]
    let thinkingContent: String?
    let reasoningContent: String?
    let reasoningDetailsJSON: String?

    init(
        text: String,
        assistantMessage: AgentLoopMessage,
        toolCalls: [AgentToolCall],
        thinkingContent: String? = nil,
        reasoningContent: String? = nil,
        reasoningDetailsJSON: String? = nil
    ) {
        self.text = text
        self.assistantMessage = assistantMessage
        self.toolCalls = toolCalls
        self.thinkingContent = thinkingContent
        self.reasoningContent = reasoningContent
        self.reasoningDetailsJSON = reasoningDetailsJSON
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

enum SystemPromptBlockID: Equatable {
    case anchorAndPolicies
    case slowMemory
    case activeSkills
    case skillIndex
    case volatile
}

enum CacheControlMarker: Equatable {
    case ephemeral
}

struct SystemPromptBlock: Equatable {
    let id: SystemPromptBlockID
    let content: String
    let cacheControl: CacheControlMarker?
}

struct TurnSystemSlice: Equatable {
    let blocks: [SystemPromptBlock]

    var combinedString: String {
        blocks
            .map(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
