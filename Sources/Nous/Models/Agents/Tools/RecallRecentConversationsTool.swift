import Foundation

struct RecallRecentConversationsTool: AgentTool {
    let name = AgentToolNames.recallRecentConversations
    let description = "Recall recent conversation memory summaries without reading raw transcripts. Use when the current question depends on recent context Alex may not repeat."
    let inputSchema = AgentToolSchema(
        properties: [
            "limit": AgentToolSchemaProperty(type: .integer, description: "Maximum result count. Clamped to 1...8.")
        ],
        required: []
    )

    let recentProvider: any RecentConversationMemoryProviding

    func execute(input: AgentToolInput, context: AgentToolContext) async throws -> AgentToolResult {
        let limit = try input.boundedInteger("limit", default: 5, range: 1...8)
        let memories = try recentProvider.fetchRecentConversationMemories(
            limit: limit,
            excludingId: context.currentNodeId
        )
        guard !memories.isEmpty else {
            return AgentToolResult(summary: "No recent conversation memories matched.")
        }

        let lines = memories.map { memory in
            "- \(memory.title): \(Self.excerpt(memory.memory, maxCharacters: 360))"
        }
        return AgentToolResult(summary: lines.joined(separator: "\n"))
    }

    private static func excerpt(_ value: String, maxCharacters: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
