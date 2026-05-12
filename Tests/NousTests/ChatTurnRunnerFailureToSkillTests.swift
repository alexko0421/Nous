import XCTest
@testable import Nous

final class ChatTurnRunnerFailureToSkillTests: XCTestCase {
    func testSuccessfulTurnWithIgnoredSourceMaterialRecordsCandidateAfterCommit() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let candidateStore = FailureSkillCandidateStore(nodeStore: nodeStore)
        let runner = makeFailurePipelineRunner(
            nodeStore: nodeStore,
            candidateStore: candidateStore,
            assistantReply: "This is a generic answer with no source grounding."
        )
        let turnId = UUID(uuidString: "00000000-0000-0000-0000-00000000B001")!
        let sourceNodeId = UUID(uuidString: "00000000-0000-0000-0000-00000000B002")!
        let sourceMaterial = SourceMaterialContext(
            sourceNodeId: sourceNodeId,
            title: "Attached Source",
            originalURL: nil,
            originalFilename: nil,
            chunks: [
                SourceChunkContext(
                    sourceNodeId: sourceNodeId,
                    ordinal: 0,
                    text: "The source says Nous should convert failures into reviewable skills.",
                    similarity: nil
                )
            ]
        )
        let sinkStore = FailurePipelineCapturingSink()
        let sink = TurnSequencedEventSink(turnId: turnId, sink: sinkStore)

        let completion = await runner.run(
            request: TurnRequest(
                turnId: turnId,
                snapshot: TurnSessionSnapshot(
                    currentNode: nil,
                    messages: [],
                    defaultProjectId: nil,
                    activeChatMode: nil,
                    activeQuickActionMode: nil
                ),
                inputText: "Summarise this source.",
                attachments: [],
                sourceMaterials: [sourceMaterial],
                now: Date(timeIntervalSince1970: 10)
            ),
            sink: sink,
            abortReason: { .cancelledByUser }
        )

        XCTAssertNotNil(completion)
        let candidates = try candidateStore.fetchRecentCandidates(userId: "alex", limit: 10)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].signature, .sourceMaterialIgnored)
        XCTAssertEqual(candidates[0].repairKind, .promptSkill)
        XCTAssertEqual(candidates[0].status, .proposed)
        XCTAssertEqual(candidates[0].turnId, turnId)
        XCTAssertEqual(candidates[0].conversationId, completion?.node.id)
        XCTAssertEqual(candidates[0].assistantMessageId, completion?.assistantMessage.id)
        XCTAssertEqual(candidates[0].activatedSkillId, nil)
        XCTAssertTrue(candidates[0].evidence.contains { $0.id == sourceNodeId.uuidString })
    }

    private func makeFailurePipelineRunner(
        nodeStore: NodeStore,
        candidateStore: FailureSkillCandidateStore,
        assistantReply: String
    ) -> ChatTurnRunner {
        let core = UserMemoryCore(nodeStore: nodeStore, llmServiceProvider: { nil })
        let planner = TurnPlanner(
            nodeStore: nodeStore,
            vectorStore: VectorStore(nodeStore: nodeStore),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(nodeStore: nodeStore),
            contradictionMemoryService: ContradictionMemoryService(core: core),
            currentProviderProvider: { .openrouter },
            judgeLLMServiceFactory: { nil }
        )
        return ChatTurnRunner(
            conversationSessionStore: ConversationSessionStore(nodeStore: nodeStore),
            turnPlanner: planner,
            turnExecutor: TurnExecutor(
                llmServiceProvider: { FailurePipelineStaticLLMService(text: assistantReply) },
                shouldUseGeminiHistoryCache: { false },
                shouldPersistAssistantThinking: { true }
            ),
            outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false }),
            failureSkillCandidateStore: candidateStore
        )
    }
}

private actor FailurePipelineCapturingSink: TurnEventSink {
    func emit(_ envelope: TurnEventEnvelope) async {}
}

private struct FailurePipelineStaticLLMService: LLMService {
    let text: String

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(text)
            continuation.finish()
        }
    }
}
