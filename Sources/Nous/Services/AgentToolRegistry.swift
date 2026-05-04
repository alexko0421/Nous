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
        contradictionProvider: any ContradictionFactProviding,
        skillStore: (any SkillStoring)? = nil
    ) -> AgentToolRegistry {
        var tools: [any AgentTool] = [
            SearchMemoryTool(memorySearchProvider: nodeStore, nodeReader: nodeStore),
            RecallRecentConversationsTool(recentProvider: nodeStore),
            FindContradictionsTool(contradictionProvider: contradictionProvider),
            SearchConversationsByTopicTool(
                vectorStore: vectorStore,
                embeddingService: embeddingService,
                nodeReader: nodeStore
            ),
            ReadNoteTool(nodeReader: nodeStore)
        ]
        if let skillStore {
            tools.append(LoadSkillTool(skillStore: skillStore))
        }
        return AgentToolRegistry(tools: tools)
    }
}

struct LoadSkillTool: AgentTool {
    let name = AgentToolNames.loadSkill
    let description = "Load the full prompt fragment for a matched skill id from the SKILL INDEX. Use only when the indexed skill is necessary for this answer."
    let inputSchema = AgentToolSchema(
        properties: [
            "skill_id": AgentToolSchemaProperty(type: .string, description: "UUID of the skill from the SKILL INDEX.")
        ],
        required: ["skill_id"]
    )

    let skillStore: any SkillStoring
    private let skillMatcher: any SkillMatching
    private let now: () -> Date

    init(
        skillStore: any SkillStoring,
        skillMatcher: any SkillMatching = SkillMatcher(),
        now: @escaping () -> Date = Date.init
    ) {
        self.skillStore = skillStore
        self.skillMatcher = skillMatcher
        self.now = now
    }

    func execute(input: AgentToolInput, context: AgentToolContext) async throws -> AgentToolResult {
        guard let activeMode = context.activeQuickActionMode else {
            throw AgentToolError.unavailable("loadSkill is only available inside an active quick mode.")
        }

        let rawId = try input.requiredString("skill_id")
        guard let skillID = UUID(uuidString: rawId) else {
            throw AgentToolError.invalidArgument("skill_id")
        }

        if let loaded = try skillStore.loadedSkills(in: context.conversationId)
            .first(where: { $0.skillID == skillID }) {
            return AgentToolResult(
                summary: Self.summary(for: loaded),
                traceContent: "Loaded skill: \(loaded.nameSnapshot)"
            )
        }

        guard context.indexedSkillIds.contains(skillID) else {
            throw AgentToolError.unauthorized("Skill")
        }

        guard let skill = try skillStore.fetchSkill(id: skillID) else {
            throw AgentToolError.notFound("Skill")
        }
        guard skill.state == .active else {
            throw AgentToolError.unavailable("Skill is \(skill.state.rawValue).")
        }
        guard skillMatcher.matchingSkills(
            from: [skill],
            context: SkillMatchContext(mode: activeMode, turnIndex: 1),
            cap: 1
        ).first?.id == skillID else {
            throw AgentToolError.unauthorized("Skill")
        }

        let loaded = try loadedSkill(skillID: skillID, context: context)
        return AgentToolResult(
            summary: Self.summary(for: loaded),
            traceContent: "Loaded skill: \(loaded.nameSnapshot)"
        )
    }

    private func loadedSkill(skillID: UUID, context: AgentToolContext) throws -> LoadedSkill {
        switch try skillStore.markSkillLoaded(skillID: skillID, in: context.conversationId, at: now()) {
        case .inserted(let loaded), .alreadyLoaded(let loaded):
            return loaded
        case .missingSkill:
            throw AgentToolError.notFound("Skill")
        case .unavailable(let state):
            throw AgentToolError.unavailable("Skill is \(state.rawValue).")
        }
    }

    private static func summary(for loaded: LoadedSkill) -> String {
        """
        Loaded skill: \(loaded.nameSnapshot)
        <<skill source=user id=\(loaded.skillID.uuidString) name=\(loaded.nameSnapshot)>>
        \(loaded.contentSnapshot)
        <</skill>>
        """
    }
}
