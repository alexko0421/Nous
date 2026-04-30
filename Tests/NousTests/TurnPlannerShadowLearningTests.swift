import XCTest
@testable import Nous

final class TurnPlannerShadowLearningTests: XCTestCase {
    func testPlannerAddsShadowHintsToPromptTraceAndVolatilePrompt() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let planner = makePlanner(
            nodeStore: nodeStore,
            shadowPatternPromptProvider: FixedShadowPromptProvider(hints: ["Use pain test."])
        )
        let node = NousNode(type: .conversation, title: "Shadow prompt")
        let message = Message(nodeId: node.id, role: .user, content: "Should we build this product feature?")
        let prepared = PreparedConversationTurn(node: node, userMessage: message, messagesAfterUserAppend: [message])
        let request = TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: node,
                messages: [message],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: .plan
            ),
            inputText: message.content,
            attachments: [],
            now: Date(timeIntervalSince1970: 4_000)
        )
        let stewardship = TurnStewardDecision(
            route: .plan,
            memoryPolicy: .lean,
            challengeStance: .surfaceTension,
            responseShape: .producePlan,
            source: .deterministic,
            reason: "test"
        )

        let plan = try await planner.plan(from: prepared, request: request, stewardship: stewardship)

        XCTAssertTrue(plan.turnSlice.volatile.contains("SHADOW THINKING HINTS:"))
        XCTAssertTrue(plan.turnSlice.volatile.contains("- Use pain test."))
        XCTAssertTrue(plan.promptTrace.promptLayers.contains("shadow_learning"))
    }

    func testPlannerSwallowsShadowProviderErrors() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let planner = makePlanner(
            nodeStore: nodeStore,
            shadowPatternPromptProvider: ThrowingShadowPromptProvider()
        )
        let node = NousNode(type: .conversation, title: "Shadow prompt")
        let message = Message(nodeId: node.id, role: .user, content: "Should we build this product feature?")
        let prepared = PreparedConversationTurn(node: node, userMessage: message, messagesAfterUserAppend: [message])
        let request = TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: node,
                messages: [message],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: .plan
            ),
            inputText: message.content,
            attachments: [],
            now: Date(timeIntervalSince1970: 4_000)
        )
        let stewardship = TurnStewardDecision(
            route: .plan,
            memoryPolicy: .lean,
            challengeStance: .surfaceTension,
            responseShape: .producePlan,
            source: .deterministic,
            reason: "test"
        )

        let plan = try await planner.plan(from: prepared, request: request, stewardship: stewardship)

        XCTAssertFalse(plan.turnSlice.volatile.contains("SHADOW THINKING HINTS:"))
        XCTAssertFalse(plan.promptTrace.promptLayers.contains("shadow_learning"))
    }

    private func makePlanner(
        nodeStore: NodeStore,
        shadowPatternPromptProvider: (any ShadowPatternPromptProviding)?
    ) -> TurnPlanner {
        let core = UserMemoryCore(nodeStore: nodeStore, llmServiceProvider: { nil })
        return TurnPlanner(
            nodeStore: nodeStore,
            vectorStore: VectorStore(nodeStore: nodeStore),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(nodeStore: nodeStore),
            contradictionMemoryService: ContradictionMemoryService(core: core),
            currentProviderProvider: { .gemini },
            judgeLLMServiceFactory: { nil },
            shadowPatternPromptProvider: shadowPatternPromptProvider
        )
    }
}

private struct FixedShadowPromptProvider: ShadowPatternPromptProviding {
    let hints: [String]

    func promptHints(
        userId: String,
        currentInput: String,
        activeQuickActionMode: QuickActionMode?,
        now: Date
    ) throws -> [String] {
        hints
    }
}

private struct ThrowingShadowPromptProvider: ShadowPatternPromptProviding {
    func promptHints(
        userId: String,
        currentInput: String,
        activeQuickActionMode: QuickActionMode?,
        now: Date
    ) throws -> [String] {
        throw ShadowPromptTestError.expected
    }
}

private enum ShadowPromptTestError: Error {
    case expected
}
