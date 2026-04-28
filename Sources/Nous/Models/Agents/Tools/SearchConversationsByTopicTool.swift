import Foundation

protocol AgentConversationEmbeddingProviding {
    var isLoaded: Bool { get }

    func embed(_ text: String) throws -> [Float]
}

protocol AgentVectorSearching {
    func search(query: [Float], topK: Int, excludeIds: Set<UUID>) throws -> [SearchResult]
}

extension EmbeddingService: AgentConversationEmbeddingProviding {}
extension VectorStore: AgentVectorSearching {}

struct SearchConversationsByTopicTool: AgentTool {
    let name = AgentToolNames.searchConversationsByTopic
    let description = "Search conversation nodes by semantic similarity. Use when the agent needs older conversation context by topic, not just recent memory summaries."
    let inputSchema = AgentToolSchema(
        properties: [
            "query": AgentToolSchemaProperty(type: .string, description: "Topic or phrase to search conversations for."),
            "limit": AgentToolSchemaProperty(type: .integer, description: "Maximum result count. Clamped to 1...8.")
        ],
        required: ["query"]
    )

    let vectorStore: any AgentVectorSearching
    let embeddingService: any AgentConversationEmbeddingProviding
    let nodeReader: any NodeReading

    func execute(input: AgentToolInput, context: AgentToolContext) async throws -> AgentToolResult {
        guard embeddingService.isLoaded else {
            throw AgentToolError.unavailable("Embedding model is not loaded.")
        }

        let query = try input.requiredString("query")
        let limit = try input.boundedInteger("limit", default: 5, range: 1...8)
        let embedding = try embeddingService.embed(query)
        let candidatePoolSize = max(40, limit * 8)
        let rawResults = try vectorStore.search(
            query: embedding,
            topK: candidatePoolSize,
            excludeIds: context.excludeNodeIds
        )
        let results = Array(rawResults
            .filter { result in
                result.node.type == .conversation &&
                AgentRawNodeReadAuthorizer.canReadRawNode(
                    result.node,
                    context: context,
                    allowAlreadyDiscoveredIds: false
                )
            }
            .prefix(limit))

        guard !results.isEmpty else {
            return AgentToolResult(summary: "No readable conversations matched that topic.")
        }

        let lines = results.map { result in
            "- [id: \(result.node.id.uuidString)] \(result.node.title): \(result.surfacedSnippet)"
        }

        return AgentToolResult(
            summary: lines.joined(separator: "\n"),
            discoveredNodeIds: Set(results.map { $0.node.id })
        )
    }
}
