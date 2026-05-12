import XCTest
@testable import Nous

final class TurnPlannerSourceBriefingTests: XCTestCase {
    func testSourceAttachedTurnGeneratesBriefingBeforePromptAssembly() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let sourceId = UUID()
        let llm = PromptCapturingPlannerBriefingLLM(output: Self.briefingJSON(sourceId: sourceId, headline: "Margins improved"))
        let planner = makePlanner(
            nodeStore: nodeStore,
            sourceBriefingService: SourceBriefingService(llmServiceProvider: { llm })
        )
        let node = NousNode(type: .conversation, title: "Source briefing")
        try nodeStore.insertNode(node)
        let message = Message(nodeId: node.id, role: .user, content: "What changed in this filing?")
        let prepared = PreparedConversationTurn(node: node, userMessage: message, messagesAfterUserAppend: [message])
        let sourceMaterial = SourceMaterialContext(
            sourceNodeId: sourceId,
            title: "Company filing",
            originalURL: "https://example.com/filing",
            originalFilename: nil,
            chunks: [
                SourceChunkContext(
                    sourceNodeId: sourceId,
                    ordinal: 0,
                    text: "Supplier renegotiation improved gross margin in the latest quarter.",
                    similarity: nil
                )
            ]
        )

        let plan = try await planner.plan(
            from: prepared,
            request: makeRequest(node: node, message: message, sourceMaterials: [sourceMaterial]),
            stewardship: makeStewardship()
        )

        XCTAssertEqual(llm.capturedMessages.count, 1)
        XCTAssertEqual(plan.sourceBriefing.items.first?.headline, "Margins improved")
        XCTAssertTrue(plan.turnSlice.combinedString.contains("SOURCE ANALYST BRIEF"))
        XCTAssertTrue(plan.turnSlice.combinedString.contains("[S1] Margins improved"))
    }

    func testNoSourceMaterialSkipsBriefingAndPromptLayer() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let llm = PromptCapturingPlannerBriefingLLM(output: "{}")
        let planner = makePlanner(
            nodeStore: nodeStore,
            sourceBriefingService: SourceBriefingService(llmServiceProvider: { llm })
        )
        let node = NousNode(type: .conversation, title: "Ordinary turn")
        try nodeStore.insertNode(node)
        let message = Message(nodeId: node.id, role: .user, content: "What should I do next?")
        let prepared = PreparedConversationTurn(node: node, userMessage: message, messagesAfterUserAppend: [message])

        let plan = try await planner.plan(
            from: prepared,
            request: makeRequest(node: node, message: message, sourceMaterials: []),
            stewardship: makeStewardship(route: .ordinaryChat)
        )

        XCTAssertTrue(llm.capturedMessages.isEmpty)
        XCTAssertTrue(plan.sourceBriefing.items.isEmpty)
        XCTAssertFalse(plan.turnSlice.combinedString.contains("SOURCE ANALYST BRIEF"))
    }

    func testPreparedEventCarriesGeneratedBriefing() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let sourceId = UUID()
        let llm = PromptCapturingPlannerBriefingLLM(output: Self.briefingJSON(sourceId: sourceId, headline: "Gross margin improved"))
        let planner = makePlanner(
            nodeStore: nodeStore,
            sourceBriefingService: SourceBriefingService(llmServiceProvider: { llm })
        )
        let node = NousNode(type: .conversation, title: "Prepared source briefing")
        try nodeStore.insertNode(node)
        let message = Message(nodeId: node.id, role: .user, content: "Analyze this source")
        let prepared = PreparedConversationTurn(node: node, userMessage: message, messagesAfterUserAppend: [message])

        let plan = try await planner.plan(
            from: prepared,
            request: makeRequest(
                node: node,
                message: message,
                sourceMaterials: [
                    SourceMaterialContext(
                        sourceNodeId: sourceId,
                        title: "Pricing memo",
                        originalURL: nil,
                        originalFilename: "pricing.md",
                        chunks: [
                            SourceChunkContext(
                                sourceNodeId: sourceId,
                                ordinal: 0,
                                text: "Supplier renegotiation improved gross margin in the latest quarter.",
                                similarity: nil
                            )
                        ]
                    )
                ]
            ),
            stewardship: makeStewardship()
        )

        let preparedEvent = TurnOutcomeFactory(shouldPersistMemory: { _, _ in false })
            .makePrepared(from: plan)
        XCTAssertEqual(preparedEvent.sourceBriefing.items.first?.headline, "Gross margin improved")
    }

    private func makePlanner(
        nodeStore: NodeStore,
        sourceBriefingService: SourceBriefingService
    ) -> TurnPlanner {
        let core = UserMemoryCore(nodeStore: nodeStore, llmServiceProvider: { nil })
        return TurnPlanner(
            nodeStore: nodeStore,
            vectorStore: VectorStore(nodeStore: nodeStore),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(nodeStore: nodeStore),
            contradictionMemoryService: ContradictionMemoryService(core: core),
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            sourceBriefingService: sourceBriefingService
        )
    }

    private func makeRequest(
        node: NousNode,
        message: Message,
        sourceMaterials: [SourceMaterialContext]
    ) -> TurnRequest {
        TurnRequest(
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
            sourceMaterials: sourceMaterials,
            now: Date(timeIntervalSince1970: 7_000)
        )
    }

    private func makeStewardship(route: TurnRoute = .sourceAnalysis) -> TurnStewardDecision {
        TurnStewardDecision(
            route: route,
            memoryPolicy: .full,
            challengeStance: .useSilently,
            responseShape: .answerNow,
            source: .deterministic,
            reason: "source briefing test"
        )
    }

    private static func briefingJSON(sourceId: UUID, headline: String) -> String {
        """
        {
          "title": "Source analyst brief",
          "items": [
            {
              "source_node_id": "\(sourceId.uuidString)",
              "headline": "\(headline)",
              "what_changed": "Supplier renegotiation improved gross margin in the latest quarter.",
              "why_it_matters": "It changes whether the business is still margin-constrained.",
              "alex_relevance": "Relevant to Alex's quality filter.",
              "tension_or_risk": "This could be temporary.",
              "suggested_next_action": "Check whether the next quarter keeps the same margin level.",
              "evidence": "Supplier renegotiation improved gross margin",
              "confidence": 0.78
            }
          ]
        }
        """
    }
}

private final class PromptCapturingPlannerBriefingLLM: LLMService {
    let output: String
    private(set) var capturedMessages: [LLMMessage] = []

    init(output: String) {
        self.output = output
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        capturedMessages.append(contentsOf: messages)
        return AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}
