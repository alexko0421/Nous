import XCTest
@testable import Nous

final class TurnPlannerSkillIntegrationTests: XCTestCase {

    func testStewardInferredModeUsesSkillsWhenExplicitQuickActionModeIsNil() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let skillStore = SkillStore(nodeStore: nodeStore)
        let skillId = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        try skillStore.insertSkill(makeSkill(
            id: skillId,
            name: "inferred-direction-skeleton",
            triggerKind: .mode,
            modes: [.direction],
            priority: 90,
            content: "INFERRED DIRECTION SKILL"
        ))

        let planner = makePlanner(nodeStore: nodeStore, skillStore: skillStore)
        let prepared = preparedTurn(userText: "I need a next step")
        let request = request(input: "I need a next step", activeQuickActionMode: nil)
        let stewardship = TurnStewardDecision(
            route: .direction,
            memoryPolicy: .lean,
            challengeStance: .surfaceTension,
            responseShape: .narrowNextStep,
            source: .deterministic,
            reason: "test inferred direction"
        )

        let plan = try await planner.plan(
            from: prepared,
            request: request,
            stewardship: stewardship
        )

        XCTAssertTrue(plan.turnSlice.combinedString.contains("SKILL INDEX"))
        XCTAssertTrue(plan.turnSlice.combinedString.contains("inferred-direction-skeleton"))
        XCTAssertTrue(plan.turnSlice.combinedString.contains("call loadSkill"))
        XCTAssertFalse(plan.turnSlice.combinedString.contains("INFERRED DIRECTION SKILL"))
    }

    func testPlannerInjectsSavedOperatingContextIntoStablePromptAndTrace() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let skillStore = SkillStore(nodeStore: nodeStore)
        let updatedAt = Date(timeIntervalSince1970: 1_234)
        let operatingContext = OperatingContext(
            identity: "Alex is testing the wiring.",
            currentWork: "Connect Operating Context end to end.",
            communicationStyle: "Be direct.",
            boundaries: "Ask before storing sensitive facts.",
            updatedAt: updatedAt
        )
        try nodeStore.saveOperatingContext(operatingContext, now: updatedAt)

        let node = NousNode(type: .conversation, title: "Operating Context wiring")
        try nodeStore.insertNode(node)
        let message = Message(
            nodeId: node.id,
            role: .user,
            content: "Check whether the profile is connected."
        )
        let prepared = PreparedConversationTurn(
            node: node,
            userMessage: message,
            messagesAfterUserAppend: [message]
        )
        let request = TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: node,
                messages: [message],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: nil
            ),
            inputText: message.content,
            attachments: [],
            now: Date(timeIntervalSince1970: 7_000)
        )
        let stewardship = TurnStewardDecision(
            route: .ordinaryChat,
            memoryPolicy: .lean,
            challengeStance: .useSilently,
            responseShape: .answerNow,
            source: .deterministic,
            reason: "test operating context wiring"
        )

        let planner = makePlanner(nodeStore: nodeStore, skillStore: skillStore)
        let plan = try await planner.plan(
            from: prepared,
            request: request,
            stewardship: stewardship
        )

        XCTAssertTrue(plan.turnSlice.stable.contains("USER-AUTHORED OPERATING CONTEXT"))
        XCTAssertTrue(plan.turnSlice.stable.contains("Identity:\n- Alex is testing the wiring."))
        XCTAssertTrue(plan.turnSlice.stable.contains("Current Work / Goals:\n- Connect Operating Context end to end."))
        XCTAssertTrue(plan.turnSlice.stable.contains("Communication Style:\n- Be direct."))
        XCTAssertTrue(plan.turnSlice.stable.contains("Hard Boundaries:\n- Ask before storing sensitive facts."))
        XCTAssertTrue(plan.promptTrace.promptLayers.contains("operating_context"))
        XCTAssertTrue(plan.promptTrace.hasMemorySignal)
    }

    private func makePlanner(
        nodeStore: NodeStore,
        skillStore: SkillStore
    ) -> TurnPlanner {
        let core = UserMemoryCore(nodeStore: nodeStore, llmServiceProvider: { nil })
        return TurnPlanner(
            nodeStore: nodeStore,
            vectorStore: VectorStore(nodeStore: nodeStore),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(nodeStore: nodeStore),
            contradictionMemoryService: ContradictionMemoryService(core: core),
            currentProviderProvider: { .openrouter },
            judgeLLMServiceFactory: { nil },
            skillStore: skillStore,
            skillMatcher: SkillMatcher(),
            skillTracker: NoOpSkillTracker()
        )
    }

    private func preparedTurn(userText: String) -> PreparedTurnSession {
        let node = NousNode(type: .conversation, title: "Skill integration test")
        let message = Message(nodeId: node.id, role: .user, content: userText)
        return PreparedConversationTurn(
            node: node,
            userMessage: message,
            messagesAfterUserAppend: [message]
        )
    }

    private func request(
        input: String,
        activeQuickActionMode: QuickActionMode?
    ) -> TurnRequest {
        TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: nil,
                messages: [],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: activeQuickActionMode
            ),
            inputText: input,
            attachments: [],
            now: Date(timeIntervalSince1970: 7_000)
        )
    }

    private func makeSkill(
        id: UUID,
        name: String,
        triggerKind: SkillTrigger.Kind,
        modes: [QuickActionMode],
        priority: Int,
        content: String
    ) -> Skill {
        Skill(
            id: id,
            userId: "alex",
            payload: SkillPayload(
                payloadVersion: 2,
                name: name,
                useWhen: "Use when the active mode needs this skill.",
                source: .alex,
                trigger: SkillTrigger(
                    kind: triggerKind,
                    modes: modes,
                    priority: priority
                ),
                action: SkillAction(kind: .promptFragment, content: content)
            ),
            state: .active,
            firedCount: 0,
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastModifiedAt: Date(timeIntervalSince1970: 1_000),
            lastFiredAt: nil
        )
    }
}

private final class NoOpSkillTracker: SkillTracking {
    func recordFire(skillIds: [UUID]) async throws {}
}
