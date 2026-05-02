import XCTest
@testable import Nous

final class QuickActionOpeningRunnerTests: XCTestCase {
    func testOpeningRunnerCommitsOnlyAssistantMessageAndKeepsOpeningPromptHidden() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let conversationStore = ConversationSessionStore(nodeStore: nodeStore)
        let node = try conversationStore.startConversation()
        let llm = OpeningPromptCapturingLLM(output: "讲下而家最拉锯系咩。")
        let turnExecutor = TurnExecutor(
            llmServiceProvider: { llm },
            shouldUseGeminiHistoryCache: { false },
            shouldPersistAssistantThinking: { false }
        )
        let runner = QuickActionOpeningRunner(
            conversationSessionStore: conversationStore,
            memoryContextBuilder: makeMemoryContextBuilder(nodeStore: nodeStore),
            turnExecutor: turnExecutor,
            outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false })
        )
        let turnId = UUID()
        let capture = OpeningTurnEventCapture()
        let sink = TurnSequencedEventSink(turnId: turnId, sink: capture)

        let completion = await runner.run(
            mode: .direction,
            node: node,
            turnId: turnId,
            sink: sink,
            abortReason: { .unexpectedCancellation }
        )

        XCTAssertNotNil(completion)
        XCTAssertTrue(llm.receivedPromptText.contains("Alex just tapped the Direction chip"))
        XCTAssertTrue(llm.receivedPromptText.contains("ACTIVE QUICK MODE: Direction"))

        let storedMessages = try nodeStore.fetchMessages(nodeId: node.id)
        XCTAssertEqual(storedMessages.count, 1)
        XCTAssertEqual(storedMessages.first?.role, .assistant)
        XCTAssertEqual(storedMessages.first?.content, "讲下而家最拉锯系咩。")
        XCTAssertFalse(try nodeStore.fetchNode(id: node.id)?.content.contains("Alex just tapped the Direction chip") ?? true)

        let events = await capture.events()
        guard case .prepared(let prepared)? = events.first?.event else {
            return XCTFail("opening runner should emit a prepared event before streaming")
        }
        XCTAssertTrue(prepared.messagesAfterUserAppend.isEmpty)
        XCTAssertEqual(prepared.userMessage.content, DirectionAgent().openingPrompt())
    }

    func testOpeningRunnerUsesMemoryContextBuilderForOpeningPromptContext() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let conversationStore = ConversationSessionStore(nodeStore: nodeStore)
        let project = Project(
            title: "Architecture cleanup",
            goal: "Finish memory architecture cleanup"
        )
        try nodeStore.insertProject(project)
        let node = try conversationStore.startConversation(projectId: project.id)
        try nodeStore.insertMemoryEntry(memoryEntry(scope: .global, content: "- Alex owns the data layer."))

        let llm = OpeningPromptCapturingLLM(output: "先讲一个真实问题。")
        let runner = QuickActionOpeningRunner(
            conversationSessionStore: conversationStore,
            memoryContextBuilder: makeMemoryContextBuilder(nodeStore: nodeStore),
            turnExecutor: TurnExecutor(
                llmServiceProvider: { llm },
                shouldUseGeminiHistoryCache: { false },
                shouldPersistAssistantThinking: { false }
            ),
            outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false })
        )
        let turnId = UUID()
        let sink = TurnSequencedEventSink(turnId: turnId, sink: OpeningTurnEventCapture())

        _ = await runner.run(
            mode: .direction,
            node: node,
            turnId: turnId,
            sink: sink,
            abortReason: { .unexpectedCancellation }
        )

        XCTAssertTrue(llm.receivedPromptText.contains("LONG-TERM MEMORY ABOUT ALEX"))
        XCTAssertTrue(llm.receivedPromptText.contains("- Alex owns the data layer."))
        XCTAssertTrue(llm.receivedPromptText.contains("CURRENT PROJECT GOAL: Finish memory architecture cleanup"))
        XCTAssertFalse(llm.receivedPromptText.contains("RELEVANT KNOWLEDGE FROM ALEX'S NOTES AND CONVERSATIONS"))
        XCTAssertFalse(llm.receivedPromptText.contains("RECENT CONVERSATIONS WITH ALEX"))
    }

    func testOpeningRunnerTracesSingleShotAgentCoordination() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let conversationStore = ConversationSessionStore(nodeStore: nodeStore)
        let node = try conversationStore.startConversation()
        let llm = OpeningPromptCapturingLLM(output: "先定一个方向。")
        var capturedPlan: TurnPlan?
        let runner = QuickActionOpeningRunner(
            conversationSessionStore: conversationStore,
            memoryContextBuilder: makeMemoryContextBuilder(nodeStore: nodeStore),
            turnExecutor: TurnExecutor(
                llmServiceProvider: { llm },
                shouldUseGeminiHistoryCache: { false },
                shouldPersistAssistantThinking: { false }
            ),
            outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false }),
            currentProviderProvider: { .openrouter },
            onPlanReady: { capturedPlan = $0 }
        )
        let turnId = UUID()
        let capture = OpeningTurnEventCapture()
        let sink = TurnSequencedEventSink(turnId: turnId, sink: capture)

        _ = await runner.run(
            mode: .direction,
            node: node,
            turnId: turnId,
            sink: sink,
            abortReason: { .unexpectedCancellation }
        )

        let expected = AgentCoordinationTrace(
            executionMode: .singleShot,
            quickActionMode: .direction,
            provider: .openrouter,
            reason: .modeSingleShotByContract,
            indexedSkillCount: 0
        )
        XCTAssertEqual(capturedPlan?.promptTrace.agentCoordination, expected)
        XCTAssertTrue(capturedPlan?.promptTrace.promptLayers.contains("agent_coordination") == true)

        let events = await capture.events()
        guard case .prepared(let prepared)? = events.first?.event else {
            return XCTFail("opening runner should emit a prepared event")
        }
        XCTAssertEqual(prepared.promptTrace.agentCoordination, expected)
    }

    private func makeMemoryContextBuilder(nodeStore: NodeStore) -> TurnMemoryContextBuilder {
        let core = UserMemoryCore(nodeStore: nodeStore, llmServiceProvider: { nil })
        return TurnMemoryContextBuilder(
            nodeStore: nodeStore,
            vectorStore: VectorStore(nodeStore: nodeStore),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(nodeStore: nodeStore),
            contradictionMemoryService: ContradictionMemoryService(core: core)
        )
    }

    private func memoryEntry(
        scope: MemoryScope,
        scopeRefId: UUID? = nil,
        content: String
    ) -> MemoryEntry {
        MemoryEntry(
            scope: scope,
            scopeRefId: scopeRefId,
            kind: .thread,
            stability: .stable,
            content: content,
            confidence: 0.9,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}

private final class OpeningPromptCapturingLLM: LLMService {
    private let lock = NSLock()
    private let output: String
    private var storedSystem: String?
    private var storedMessages: [LLMMessage] = []

    var receivedPromptText: String {
        lock.withLock {
            ([storedSystem ?? ""] + storedMessages.map(\.content))
                .joined(separator: "\n\n")
        }
    }

    init(output: String) {
        self.output = output
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        lock.withLock {
            storedSystem = system
            storedMessages = messages
        }
        let output = output
        return AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}

private actor OpeningTurnEventCapture: TurnEventSink {
    private var capturedEvents: [TurnEventEnvelope] = []

    func emit(_ envelope: TurnEventEnvelope) async {
        capturedEvents.append(envelope)
    }

    func events() -> [TurnEventEnvelope] {
        capturedEvents
    }
}
