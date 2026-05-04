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

    func testOpeningRunnerRecordsReviewAndRuntimeSnapshotAfterSuccessfulCommit() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let conversationStore = ConversationSessionStore(nodeStore: nodeStore)
        let node = try conversationStore.startConversation()
        let reviewer = OpeningRecordingCognitionReviewer()
        let reviewCapture = OpeningReviewArtifactCapture()
        let snapshotCapture = OpeningTurnCognitionSnapshotCapture()
        let runner = QuickActionOpeningRunner(
            conversationSessionStore: conversationStore,
            memoryContextBuilder: makeMemoryContextBuilder(nodeStore: nodeStore),
            turnExecutor: TurnExecutor(
                llmServiceProvider: { OpeningPromptCapturingLLM(output: "先定一个方向。") },
                shouldUseGeminiHistoryCache: { false },
                shouldPersistAssistantThinking: { false }
            ),
            outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false }),
            cognitionReviewer: reviewer,
            onReviewArtifact: { reviewCapture.append($0) },
            onTurnCognitionSnapshot: { snapshotCapture.append($0) }
        )
        let turnId = UUID()
        let sink = TurnSequencedEventSink(turnId: turnId, sink: OpeningTurnEventCapture())

        let maybeCompletion = await runner.run(
            mode: .direction,
            node: node,
            turnId: turnId,
            sink: sink,
            abortReason: { .unexpectedCancellation }
        )
        let completion = try XCTUnwrap(maybeCompletion)

        let snapshot = try XCTUnwrap(snapshotCapture.values().first)
        XCTAssertEqual(snapshotCapture.values().count, 1)
        XCTAssertEqual(snapshot.turnId, turnId)
        XCTAssertEqual(snapshot.conversationId, completion.node.id)
        XCTAssertEqual(snapshot.assistantMessageId, completion.assistantMessage.id)
        XCTAssertEqual(snapshot.promptLayers.contains("agent_coordination"), true)
        XCTAssertFalse(snapshot.slowCognitionAttached)
        XCTAssertEqual(snapshot.slowCognitionEvidenceRefIds, [])
        XCTAssertNotNil(snapshot.reviewArtifactId)
        XCTAssertEqual(reviewer.reviewedTurnIds, [turnId])
        let reviewArtifact = try XCTUnwrap(reviewCapture.values().first)
        XCTAssertEqual(reviewArtifact.id, snapshot.reviewArtifactId)
        XCTAssertEqual(reviewArtifact.evidenceRefs.first?.source, .message)
        XCTAssertEqual(reviewArtifact.evidenceRefs.first?.id, completion.assistantMessage.id.uuidString)
        XCTAssertEqual(reviewArtifact.evidenceRefs.first?.quote, completion.assistantMessage.content)
        XCTAssertFalse(reviewArtifact.evidenceRefs.contains { ref in
            ref.source == .message && ref.id == reviewer.reviewedUserMessageIds.first?.uuidString
        })
    }

    func testOpeningRunnerDoesNotRecordReviewOrSnapshotWhenCommitFails() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let conversationStore = ConversationSessionStore(nodeStore: nodeStore)
        let node = try conversationStore.startConversation()
        let reviewer = OpeningRecordingCognitionReviewer()
        let reviewCapture = OpeningReviewArtifactCapture()
        let snapshotCapture = OpeningTurnCognitionSnapshotCapture()
        let runner = QuickActionOpeningRunner(
            conversationSessionStore: conversationStore,
            memoryContextBuilder: makeMemoryContextBuilder(nodeStore: nodeStore),
            turnExecutor: TurnExecutor(
                llmServiceProvider: {
                    OpeningNodeDeletingLLMService(
                        nodeStore: nodeStore,
                        output: "This commit will fail."
                    )
                },
                shouldUseGeminiHistoryCache: { false },
                shouldPersistAssistantThinking: { false }
            ),
            outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false }),
            cognitionReviewer: reviewer,
            onReviewArtifact: { reviewCapture.append($0) },
            onTurnCognitionSnapshot: { snapshotCapture.append($0) }
        )
        let turnId = UUID()
        let sink = TurnSequencedEventSink(turnId: turnId, sink: OpeningTurnEventCapture())

        let completion = await runner.run(
            mode: .direction,
            node: node,
            turnId: turnId,
            sink: sink,
            abortReason: { .unexpectedCancellation }
        )

        XCTAssertNil(completion)
        XCTAssertTrue(reviewer.reviewedTurnIds.isEmpty)
        XCTAssertTrue(reviewCapture.values().isEmpty)
        XCTAssertTrue(snapshotCapture.values().isEmpty)
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

private final class OpeningRecordingCognitionReviewer: CognitionReviewing {
    private(set) var reviewedTurnIds: [UUID] = []
    private(set) var reviewedUserMessageIds: [UUID] = []

    func review(plan: TurnPlan, executionResult: TurnExecutionResult) throws -> CognitionArtifact? {
        reviewedTurnIds.append(plan.turnId)
        reviewedUserMessageIds.append(plan.prepared.userMessage.id)
        return CognitionArtifact(
            organ: .reviewer,
            title: "Opening review",
            summary: "The reviewer checked the quick-action opening turn.",
            confidence: 0.8,
            jurisdiction: .turnContext,
            evidenceRefs: [
                CognitionEvidenceRef(
                    source: .message,
                    id: plan.prepared.userMessage.id.uuidString,
                    quote: plan.prepared.userMessage.content
                )
            ],
            trace: CognitionTrace(
                producer: .reviewer,
                sourceJobId: "opening_post_turn_review"
            )
        )
    }
}

private final class OpeningReviewArtifactCapture {
    private var artifacts: [CognitionArtifact] = []

    func append(_ artifact: CognitionArtifact) {
        artifacts.append(artifact)
    }

    func values() -> [CognitionArtifact] {
        artifacts
    }
}

private final class OpeningTurnCognitionSnapshotCapture {
    private var snapshots: [TurnCognitionSnapshot] = []

    func append(_ snapshot: TurnCognitionSnapshot) {
        snapshots.append(snapshot)
    }

    func values() -> [TurnCognitionSnapshot] {
        snapshots
    }
}

private final class OpeningNodeDeletingLLMService: LLMService {
    private let nodeStore: NodeStore
    private let output: String

    init(nodeStore: NodeStore, output: String) {
        self.nodeStore = nodeStore
        self.output = output
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        let nodeStore = nodeStore
        let output = output
        return AsyncThrowingStream { continuation in
            do {
                for node in try nodeStore.fetchAllNodes() {
                    try nodeStore.deleteNode(id: node.id)
                }
                continuation.yield(output)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
