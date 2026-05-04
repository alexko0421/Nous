import Foundation

struct FindContradictionsTool: AgentTool {
    let name = AgentToolNames.findContradictions
    let description = "Find scoped memory facts that may contradict the current direction or plan. Use when Alex is making a decision that may conflict with prior constraints, boundaries, or decisions."
    private static let updatedAtFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()

    let inputSchema = AgentToolSchema(
        properties: [
            "topic": AgentToolSchemaProperty(type: .string, description: "Decision, plan, or topic to check for contradictions."),
            "limit": AgentToolSchemaProperty(type: .integer, description: "Maximum candidate count. Clamped to 1...5.")
        ],
        required: ["topic"]
    )

    let contradictionProvider: any ContradictionFactProviding

    func execute(input: AgentToolInput, context: AgentToolContext) async throws -> AgentToolResult {
        let topic = try input.requiredString("topic")
        let limit = try input.boundedInteger("limit", default: 3, range: 1...5)
        let facts = try contradictionProvider.contradictionRecallFacts(
            projectId: context.projectId,
            conversationId: context.conversationId
        )
        let annotated = contradictionProvider
            .annotateContradictionCandidates(
                currentMessage: topic,
                facts: facts,
                maxCandidates: limit
            )
            .filter(\.isContradictionCandidate)
            .prefix(limit)

        guard !annotated.isEmpty else {
            return AgentToolResult(summary: "No contradiction candidates matched.")
        }

        let lines = annotated.map { candidate in
            let fact = candidate.fact
            let updatedAt = Self.updatedAtFormatter.string(from: fact.updatedAt)
            return "[\(fact.scope.rawValue)/\(fact.kind.rawValue), updated \(updatedAt)] \(fact.content)"
        }
        return AgentToolResult(summary: lines.joined(separator: "\n"))
    }
}
