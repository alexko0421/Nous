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

    func testRunnerEmitsJudgeThinkingBeforePreparedTurn() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let judgeLLM = ThinkingFixedLLMService(
            output: """
            {"tension_exists":false,"user_state":"exploring","should_provoke":false,
             "entry_id":null,"reason":"no tension","inferred_mode":"strategist"}
            """,
            thinkingDelta: "I checked whether retrieved memory creates tension."
        )
        let runner = ChatTurnRunner(
            conversationSessionStore: ConversationSessionStore(nodeStore: nodeStore),
            turnPlanner: makePlanner(nodeStore: nodeStore, judgeLLMServiceFactory: { judgeLLM }),
            turnExecutor: TurnExecutor(
                llmServiceProvider: {
                    FixedLLMService(output: "Done\n<chat_title>Judge thinking</chat_title>")
                },
                shouldUseGeminiHistoryCache: { false },
                shouldPersistAssistantThinking: { true }
            ),
            outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false })
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
            inputText: "Help me decide the next step",
            attachments: [],
            now: Date(timeIntervalSince1970: 5_000)
        )
        let capture = RecordingTurnEventSink()
        let sink = TurnSequencedEventSink(turnId: request.turnId, sink: capture)

        _ = await runner.run(
            request: request,
            sink: sink,
            abortReason: { .unexpectedCancellation }
        )

        let events = await capture.events()
        let thinkingIndex = events.firstIndex { envelope in
            guard case .thinkingDelta(let delta) = envelope.event else { return false }
            return delta.contains("Gemini judge thought summary")
                && delta.contains("I checked whether retrieved memory creates tension.")
        }
        let preparedIndex = events.firstIndex { envelope in
            guard case .prepared = envelope.event else { return false }
            return true
        }
        XCTAssertNotNil(thinkingIndex)
        XCTAssertNotNil(preparedIndex)
        XCTAssertLessThan(try XCTUnwrap(thinkingIndex), try XCTUnwrap(preparedIndex))
    }

    private func makePlanner(
        nodeStore: NodeStore,
        judgeLLMServiceFactory: @escaping () -> (any LLMService)? = { nil }
    ) -> TurnPlanner {
        let core = UserMemoryCore(nodeStore: nodeStore, llmServiceProvider: { nil })
        return TurnPlanner(
            nodeStore: nodeStore,
            vectorStore: VectorStore(nodeStore: nodeStore),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(nodeStore: nodeStore),
            contradictionMemoryService: ContradictionMemoryService(core: core),
            currentProviderProvider: { .gemini },
            judgeLLMServiceFactory: judgeLLMServiceFactory
        )
    }
}

private struct NoOpTurnEventSink: TurnEventSink {
    func emit(_ envelope: TurnEventEnvelope) async {}
}

private actor RecordingTurnEventSink: TurnEventSink {
    private var capturedEvents: [TurnEventEnvelope] = []

    func emit(_ envelope: TurnEventEnvelope) async {
        capturedEvents.append(envelope)
    }

    func events() -> [TurnEventEnvelope] {
        capturedEvents
    }
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

private struct ThinkingFixedLLMService: LLMService, ThinkingDeltaConfigurableLLMService {
    let output: String
    let thinkingDelta: String
    var onThinkingDelta: ThinkingDeltaHandler?

    func withThinkingDeltaHandler(_ handler: @escaping ThinkingDeltaHandler) -> any LLMService {
        ThinkingFixedLLMService(
            output: output,
            thinkingDelta: thinkingDelta,
            onThinkingDelta: handler
        )
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        let output = output
        let thinkingDelta = thinkingDelta
        let onThinkingDelta = onThinkingDelta
        return AsyncThrowingStream { continuation in
            Task {
                if let onThinkingDelta {
                    await onThinkingDelta(thinkingDelta)
                }
                continuation.yield(output)
                continuation.finish()
            }
        }
    }
}
