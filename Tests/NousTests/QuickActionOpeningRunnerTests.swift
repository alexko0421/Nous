import XCTest
@testable import Nous

final class QuickActionOpeningRunnerTests: XCTestCase {
    func testOpeningRunnerCommitsLocalModeMessageWithoutCallingLLM() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let conversationStore = ConversationSessionStore(nodeStore: nodeStore)
        let node = try conversationStore.startConversation()
        let llm = OpeningPromptCapturingLLM(output: "LLM opening should not be used.")
        let runner = makeRunner(
            nodeStore: nodeStore,
            conversationStore: conversationStore,
            llm: llm
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
        XCTAssertEqual(llm.generateCallCount, 0)

        let storedMessages = try nodeStore.fetchMessages(nodeId: node.id)
        XCTAssertEqual(storedMessages.count, 1)
        XCTAssertEqual(storedMessages.first?.role, .assistant)
        XCTAssertEqual(storedMessages.first?.content, QuickActionMode.direction.openingMessage)
        XCTAssertNil(storedMessages.first?.thinkingContent)
        XCTAssertFalse(try nodeStore.fetchNode(id: node.id)?.content.contains("<phase>understanding</phase>") ?? true)

        let events = await capture.events()
        XCTAssertEqual(events.count, 1)
        guard case .completed(let completed)? = events.first?.event else {
            return XCTFail("opening runner should complete immediately")
        }
        XCTAssertEqual(completed.nextQuickActionMode, .direction)
        XCTAssertEqual(completed.messagesAfterAssistantAppend.map(\.content), [QuickActionMode.direction.openingMessage])
        XCTAssertNil(completed.continuationPlan.scratchpadIngest)
        XCTAssertNil(completed.continuationPlan.memoryRefresh)
        XCTAssertNil(completed.housekeepingPlan.geminiCacheRefresh)
        XCTAssertNil(completed.housekeepingPlan.embeddingRefresh)
        XCTAssertNil(completed.housekeepingPlan.emojiRefresh)
    }

    func testOpeningRunnerUsesDistinctMessageForEachMode() async throws {
        for mode in QuickActionMode.allCases {
            let nodeStore = try NodeStore(path: ":memory:")
            let conversationStore = ConversationSessionStore(nodeStore: nodeStore)
            let node = try conversationStore.startConversation()
            let llm = OpeningPromptCapturingLLM(output: "unused")
            let runner = makeRunner(
                nodeStore: nodeStore,
                conversationStore: conversationStore,
                llm: llm
            )
            let sink = TurnSequencedEventSink(turnId: UUID(), sink: OpeningTurnEventCapture())

            let completion = await runner.run(
                mode: mode,
                node: node,
                turnId: UUID(),
                sink: sink,
                abortReason: { .unexpectedCancellation }
            )

            XCTAssertEqual(completion?.assistantMessage.content, mode.openingMessage)
            XCTAssertTrue(mode.openingMessage.contains(mode.label))
            XCTAssertEqual(llm.generateCallCount, 0)
        }
    }

    func testOpeningRunnerAbortsBeforeCommitWhenCancelled() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let conversationStore = ConversationSessionStore(nodeStore: nodeStore)
        let node = try conversationStore.startConversation()
        let runner = makeRunner(
            nodeStore: nodeStore,
            conversationStore: conversationStore,
            llm: OpeningPromptCapturingLLM(output: "unused")
        )
        let capture = OpeningTurnEventCapture()
        let turnId = UUID()
        let sink = TurnSequencedEventSink(turnId: turnId, sink: capture)

        let task = Task {
            await runner.run(
                mode: .plan,
                node: node,
                turnId: turnId,
                sink: sink,
                abortReason: { .supersededByNewTurn }
            )
        }
        task.cancel()
        let completion = await task.value

        XCTAssertNil(completion)
        XCTAssertTrue(try nodeStore.fetchMessages(nodeId: node.id).isEmpty)
        let events = await capture.events()
        guard case .aborted(.supersededByNewTurn)? = events.first?.event else {
            return XCTFail("expected the cancelled opening to emit an abort")
        }
    }

    private func makeRunner(
        nodeStore: NodeStore,
        conversationStore: ConversationSessionStore,
        llm: OpeningPromptCapturingLLM
    ) -> QuickActionOpeningRunner {
        QuickActionOpeningRunner(
            conversationSessionStore: conversationStore,
            memoryContextBuilder: makeMemoryContextBuilder(nodeStore: nodeStore),
            turnExecutor: TurnExecutor(
                llmServiceProvider: { llm },
                shouldUseGeminiHistoryCache: { false },
                shouldPersistAssistantThinking: { false }
            ),
            outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false })
        )
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
}

private final class OpeningPromptCapturingLLM: LLMService {
    private let lock = NSLock()
    private let output: String
    private var callCount = 0

    var generateCallCount: Int {
        lock.withLock { callCount }
    }

    init(output: String) {
        self.output = output
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        lock.withLock {
            callCount += 1
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
