import Foundation

struct ReadNoteTool: AgentTool {
    let name = AgentToolNames.readNote
    let description = "Read a bounded excerpt from a specific note or conversation that is already in scope. Use only after another tool surfaced a readable node id or for the current conversation."
    let inputSchema = AgentToolSchema(
        properties: [
            "id": AgentToolSchemaProperty(type: .string, description: "UUID of the note or conversation to read.")
        ],
        required: ["id"]
    )

    let nodeReader: any NodeReading

    func execute(input: AgentToolInput, context: AgentToolContext) async throws -> AgentToolResult {
        let rawId = try input.requiredString("id")
        guard let id = UUID(uuidString: rawId) else {
            throw AgentToolError.invalidArgument("id")
        }
        guard let node = try nodeReader.fetchNode(id: id),
              AgentRawNodeReadAuthorizer.canReadRawNode(
                node,
                context: context,
                allowAlreadyDiscoveredIds: true
              ) else {
            throw AgentToolError.unauthorized("Node")
        }

        let typeLabel = node.type == .conversation ? "conversation" : "note"
        let excerpt = Self.excerpt(node.content, maxCharacters: context.maxToolResultCharacters)
        let summary = """
        \(node.title) (\(typeLabel))
        \(excerpt)
        """
        return AgentToolResult(summary: summary)
    }

    private static func excerpt(_ value: String, maxCharacters: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
