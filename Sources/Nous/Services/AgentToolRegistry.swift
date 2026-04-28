import Foundation

final class AgentToolRegistry {
    private let toolsByName: [String: any AgentTool]

    init(tools: [any AgentTool]) {
        self.toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    var declarations: [AgentToolDeclaration] {
        toolsByName.values
            .sorted { $0.name < $1.name }
            .map {
                AgentToolDeclaration(
                    function: AgentToolFunctionDeclaration(
                        name: $0.name,
                        description: $0.description,
                        parameters: $0.inputSchema
                    )
                )
            }
    }

    func tool(named name: String) -> (any AgentTool)? {
        toolsByName[name]
    }

    func subset(_ names: [String]) -> AgentToolRegistry {
        AgentToolRegistry(tools: names.compactMap { toolsByName[$0] })
    }

    static func standard(
        nodeStore: NodeStore,
        vectorStore: VectorStore,
        embeddingService: EmbeddingService,
        contradictionProvider: any ContradictionFactProviding
    ) -> AgentToolRegistry {
        AgentToolRegistry(tools: [
            SearchMemoryTool(memorySearchProvider: nodeStore, nodeReader: nodeStore),
            RecallRecentConversationsTool(recentProvider: nodeStore),
            FindContradictionsTool(contradictionProvider: contradictionProvider),
            SearchConversationsByTopicTool(
                vectorStore: vectorStore,
                embeddingService: embeddingService,
                nodeReader: nodeStore
            ),
            ReadNoteTool(nodeReader: nodeStore)
        ])
    }
}
