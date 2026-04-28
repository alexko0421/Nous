import Foundation

enum AgentLoopMessage: Equatable, Sendable {
    case text(role: String, content: String)
    case assistantToolCalls(content: String?, toolCalls: [AgentToolCall])
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
}
