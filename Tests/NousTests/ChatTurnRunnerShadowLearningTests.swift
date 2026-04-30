import XCTest
@testable import Nous

final class ChatTurnRunnerShadowLearningTests: XCTestCase {
    func testRunnerRecordsShadowSignalAfterPreparingUserTurn() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let shadowStore = ShadowLearningStore(nodeStore: nodeStore)
        let recorder = ShadowLearningSignalRecorder(store: shadowStore)
        let conversationStore = ConversationSessionStore(nodeStore: nodeStore)
        let runner = ChatTurnRunner(
            conversationSessionStore: conversationStore,
            turnPlanner: makePlanner(nodeStore: nodeStore),
            turnExecutor: TurnExecutor(
                llmServiceProvider: {
                    FixedLLMService(output: "Done\n<chat_title>Shadow test</chat_title>")
                },
                shouldUseGeminiHistoryCache: { false },
                shouldPersistAssistantThinking: { false }
            ),
            outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false }),
            shadowLearningSignalRecorder: recorder
        )
        let request = TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: nil,
                messages: [],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: nil
            ),
            inputText: "先用 first principles 拆一下",
            attachments: [],
            now: Date(timeIntervalSince1970: 5_000)
        )
        let sink = TurnSequencedEventSink(turnId: request.turnId, sink: NoOpTurnEventSink())

        _ = await runner.run(
            request: request,
            sink: sink,
            abortReason: { .unexpectedCancellation }
        )

        let patterns = try shadowStore.fetchPatterns(userId: "alex")
        XCTAssertEqual(patterns.map(\.label), ["first_principles_decision_frame"])
    }

    private func makePlanner(nodeStore: NodeStore) -> TurnPlanner {
        let core = UserMemoryCore(nodeStore: nodeStore, llmServiceProvider: { nil })
        return TurnPlanner(
            nodeStore: nodeStore,
            vectorStore: VectorStore(nodeStore: nodeStore),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(nodeStore: nodeStore),
            contradictionMemoryService: ContradictionMemoryService(core: core),
            currentProviderProvider: { .gemini },
            judgeLLMServiceFactory: { nil }
        )
    }
}

private struct NoOpTurnEventSink: TurnEventSink {
    func emit(_ envelope: TurnEventEnvelope) async {}
}

private final class FixedLLMService: LLMService {
    let output: String

    init(output: String) {
        self.output = output
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}
