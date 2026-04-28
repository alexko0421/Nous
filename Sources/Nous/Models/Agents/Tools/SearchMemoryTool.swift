import Foundation

struct SearchMemoryTool: AgentTool {
    let name = AgentToolNames.searchMemory
    let description = "Search active memory entries by keyword or theme. Use this before giving Direction or Plan advice that should be grounded in Alex's prior decisions, constraints, or preferences."
    let inputSchema = AgentToolSchema(
        properties: [
            "query": AgentToolSchemaProperty(type: .string, description: "Keyword, phrase, or theme to search for."),
            "limit": AgentToolSchemaProperty(type: .integer, description: "Maximum result count. Clamped to 1...8.")
        ],
        required: ["query"]
    )

    let memorySearchProvider: any MemoryEntrySearchProviding
    let nodeReader: any NodeReading

    func execute(input: AgentToolInput, context: AgentToolContext) async throws -> AgentToolResult {
        let query = try input.requiredString("query")
        let limit = try input.boundedInteger("limit", default: 5, range: 1...8)
        let entries = try memorySearchProvider.searchActiveMemoryEntries(
            query: query,
            projectId: context.projectId,
            conversationId: context.conversationId,
            limit: limit
        )
        guard !entries.isEmpty else {
            return AgentToolResult(summary: "No memory entries matched.")
        }

        var discoveredNodeIds: Set<UUID> = []
        let lines = entries.map { entry in
            var readableSourceIds: [UUID] = []
            for sourceNodeId in entry.sourceNodeIds {
                guard let node = try? nodeReader.fetchNode(id: sourceNodeId),
                      AgentRawNodeReadAuthorizer.canReadRawNode(
                        node,
                        context: context,
                        allowAlreadyDiscoveredIds: false
                      ) else {
                    continue
                }
                discoveredNodeIds.insert(sourceNodeId)
                readableSourceIds.append(sourceNodeId)
            }
            let idSuffix = readableSourceIds.isEmpty
                ? ""
                : " (readable ids: \(readableSourceIds.map(\.uuidString).joined(separator: ", ")))"
            return "[\(entry.scope.rawValue)/\(entry.kind.rawValue)] \(Self.excerpt(entry.content, maxCharacters: 360))\(idSuffix)"
        }

        return AgentToolResult(
            summary: lines.joined(separator: "\n"),
            discoveredNodeIds: discoveredNodeIds
        )
    }

    private static func excerpt(_ value: String, maxCharacters: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
