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
    let thinkingContent: String?

    init(
        text: String,
        assistantMessage: AgentLoopMessage,
        toolCalls: [AgentToolCall],
        thinkingContent: String? = nil
    ) {
        self.text = text
        self.assistantMessage = assistantMessage
        self.toolCalls = toolCalls
        self.thinkingContent = thinkingContent
    }
}
