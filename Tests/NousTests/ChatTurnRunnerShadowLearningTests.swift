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

    func testRunnerEmitsSilentReviewerArtifactAfterPlanExecution() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let reviewer = RecordingCognitionReviewer()
        let capture = ReviewArtifactCapture()
        let runner = ChatTurnRunner(
            conversationSessionStore: ConversationSessionStore(nodeStore: nodeStore),
            turnPlanner: makePlanner(nodeStore: nodeStore),
            turnExecutor: TurnExecutor(
                llmServiceProvider: {
                    FixedLLMService(output: "Plan ready\n<chat_title>Reviewer test</chat_title>")
                },
                shouldUseGeminiHistoryCache: { false },
                shouldPersistAssistantThinking: { false }
            ),
            outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false }),
            cognitionReviewer: reviewer,
            onReviewArtifact: { capture.append($0) }
        )
        let request = TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: nil,
                messages: [],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: .plan
            ),
            inputText: "Help me plan the next long-turn cognition step",
            attachments: [],
            now: Date(timeIntervalSince1970: 5_000)
        )
        let sink = TurnSequencedEventSink(turnId: request.turnId, sink: NoOpTurnEventSink())

        let completion = await runner.run(
            request: request,
            sink: sink,
            abortReason: { .unexpectedCancellation }
        )

        XCTAssertNotNil(completion)
        XCTAssertEqual(reviewer.reviewedTurnIds, [request.turnId])
        XCTAssertEqual(reviewer.reviewedAssistantContents, ["Plan ready"])
        let artifacts = capture.values()
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts.first?.organ, .reviewer)
        XCTAssertEqual(artifacts.first?.trace.sourceJobId, "silent_post_turn_review")
    }

    func testRunnerRecordsTurnCognitionSnapshotAfterSuccessfulCommit() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let reviewer = RecordingCognitionReviewer()
        let snapshotCapture = TurnCognitionSnapshotCapture()
        let slowArtifact = CognitionArtifact(
            organ: .patternAnalyst,
            title: "Long-term mind system",
            summary: "Alex is designing Nous as a long-term mind system.",
            confidence: 0.82,
            jurisdiction: .selfReflection,
            evidenceRefs: [
                CognitionEvidenceRef(
                    source: .reflectionClaim,
                    id: UUID().uuidString,
                    quote: "long-term mind system"
                )
            ],
            suggestedSurfacing: "Use when Alex asks about long-term Nous direction.",
            trace: CognitionTrace(
                producer: .patternAnalyst,
                sourceJobId: BackgroundAIJobID.weeklyReflection.rawValue
            )
        )
        let runner = ChatTurnRunner(
            conversationSessionStore: ConversationSessionStore(nodeStore: nodeStore),
            turnPlanner: makePlanner(
                nodeStore: nodeStore,
                slowCognitionArtifactProvider: FixedSlowCognitionArtifactProvider(artifacts: [slowArtifact])
            ),
            turnExecutor: TurnExecutor(
                llmServiceProvider: {
                    FixedLLMService(output: "Plan ready\n<chat_title>Runtime snapshot</chat_title>")
                },
                shouldUseGeminiHistoryCache: { false },
                shouldPersistAssistantThinking: { false }
            ),
            outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false }),
            cognitionReviewer: reviewer,
            onTurnCognitionSnapshot: { snapshotCapture.append($0) }
        )
        let request = TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: nil,
                messages: [],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: .plan
            ),
            inputText: "How should we build the long-term mind system?",
            attachments: [],
            now: Date(timeIntervalSince1970: 5_000)
        )
        let sink = TurnSequencedEventSink(turnId: request.turnId, sink: NoOpTurnEventSink())

        let maybeCompletion = await runner.run(
            request: request,
            sink: sink,
            abortReason: { .unexpectedCancellation }
        )
        let completion = try XCTUnwrap(maybeCompletion)

        let snapshot = try XCTUnwrap(snapshotCapture.values().first)
        XCTAssertEqual(snapshotCapture.values().count, 1)
        XCTAssertEqual(snapshot.turnId, request.turnId)
        XCTAssertEqual(snapshot.conversationId, completion.node.id)
        XCTAssertEqual(snapshot.assistantMessageId, completion.assistantMessage.id)
        XCTAssertTrue(snapshot.slowCognitionAttached)
        XCTAssertTrue(snapshot.promptLayers.contains("slow_cognition"))
        XCTAssertEqual(snapshot.slowCognitionArtifactId, slowArtifact.id)
        XCTAssertEqual(snapshot.slowCognitionEvidenceRefIds, slowArtifact.evidenceRefs.map(\.id))
        XCTAssertEqual(snapshot.slowCognitionEvidenceRefCount, slowArtifact.evidenceRefs.count)
        XCTAssertNotNil(snapshot.reviewArtifactId)
        XCTAssertEqual(snapshot.reviewRiskFlags, [])
        XCTAssertEqual(snapshot.conversationRecoveryRebasedMessageCount, 0)

        let encoded = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains(request.inputText))
        XCTAssertFalse(encoded.contains("Plan ready"))
    }

    func testRunnerPreservesSlowCognitionProvenanceWhenAgentLoopFallsBackToSingleShot() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let snapshotCapture = TurnCognitionSnapshotCapture()
        let slowArtifact = CognitionArtifact(
            organ: .patternAnalyst,
            title: "Long-turn cognition direction",
            summary: "Alex is designing Nous as a long-term mind system.",
            confidence: 0.82,
            jurisdiction: .selfReflection,
            evidenceRefs: [
                CognitionEvidenceRef(
                    source: .reflectionClaim,
                    id: UUID().uuidString,
                    quote: "long-term mind system"
                )
            ],
            suggestedSurfacing: "Use when Alex asks about long-term Nous direction.",
            trace: CognitionTrace(
                producer: .patternAnalyst,
                sourceJobId: BackgroundAIJobID.weeklyReflection.rawValue
            )
        )
        let runner = ChatTurnRunner(
            conversationSessionStore: ConversationSessionStore(nodeStore: nodeStore),
            turnPlanner: makePlanner(
                nodeStore: nodeStore,
                currentProvider: .openrouter,
                slowCognitionArtifactProvider: FixedSlowCognitionArtifactProvider(artifacts: [slowArtifact])
            ),
            turnExecutor: TurnExecutor(
                llmServiceProvider: {
                    FixedLLMService(output: "Plan ready\n<chat_title>Fallback snapshot</chat_title>")
                },
                shouldUseGeminiHistoryCache: { false },
                shouldPersistAssistantThinking: { false }
            ),
            outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false }),
            onTurnCognitionSnapshot: { snapshotCapture.append($0) }
        )
        let request = TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: nil,
                messages: [],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: .plan
            ),
            inputText: "How should we build the long-term mind system?",
            attachments: [],
            now: Date(timeIntervalSince1970: 5_000)
        )
        let sink = TurnSequencedEventSink(turnId: request.turnId, sink: NoOpTurnEventSink())

        let completion = await runner.run(
            request: request,
            sink: sink,
            abortReason: { .unexpectedCancellation }
        )

        XCTAssertNotNil(completion)
        let snapshot = try XCTUnwrap(snapshotCapture.values().first)
        XCTAssertEqual(snapshotCapture.values().count, 1)
        XCTAssertTrue(snapshot.promptLayers.contains("slow_cognition"))
        XCTAssertTrue(snapshot.slowCognitionAttached)
        XCTAssertEqual(snapshot.slowCognitionArtifactId, slowArtifact.id)
        XCTAssertEqual(snapshot.slowCognitionEvidenceRefIds, slowArtifact.evidenceRefs.map(\.id))
        XCTAssertEqual(snapshot.slowCognitionEvidenceRefCount, slowArtifact.evidenceRefs.count)
    }

    func testSilentReviewerSkipsOrdinaryCompanionTurns() throws {
        let plan = makeReviewPlan(route: .ordinaryChat)
        let artifact = try CognitionReviewer().review(
            plan: plan,
            executionResult: makeExecutionResult(content: "普通倾偈")
        )

        XCTAssertNil(artifact)
    }

    func testSilentReviewerCreatesSourcedArtifactForDirectionTurns() throws {
        let plan = makeReviewPlan(route: .direction)
        let artifact = try XCTUnwrap(
            try CognitionReviewer().review(
                plan: plan,
                executionResult: makeExecutionResult(
                    content: "Three options exist. Based on your notes, choose the quieter path. Then review it tomorrow."
                )
            )
        )

        XCTAssertEqual(artifact.organ, .reviewer)
        XCTAssertEqual(artifact.jurisdiction, .turnContext)
        XCTAssertEqual(artifact.trace.producer, .reviewer)
        XCTAssertEqual(artifact.trace.sourceJobId, "silent_post_turn_review")
        XCTAssertTrue(artifact.evidenceRefs.contains {
            $0.source == .message && $0.id == plan.prepared.userMessage.id.uuidString
        })
        XCTAssertTrue(artifact.riskFlags.contains("unsupported_memory_reference"))
        let assistantDraftRef = artifact.evidenceRefs.first {
            $0.id == "\(plan.turnId.uuidString):assistant_draft"
        }
        XCTAssertEqual(assistantDraftRef?.source.rawValue, "assistant_draft")
        XCTAssertEqual(assistantDraftRef?.quote, "Based on your notes, choose the quieter path.")
        XCTAssertNoThrow(try artifact.validated())
    }

    func testSilentReviewerAssistantDraftQuoteCentersLongFlaggedPhrase() throws {
        let plan = makeReviewPlan(route: .direction)
        let longLeadIn = String(repeating: "context ", count: 40)
        let artifact = try XCTUnwrap(
            try CognitionReviewer().review(
                plan: plan,
                executionResult: makeExecutionResult(
                    content: "\(longLeadIn)Based on your notes, choose the quieter path after checking the tradeoffs carefully."
                )
            )
        )

        let assistantDraftRef = try XCTUnwrap(artifact.evidenceRefs.first {
            $0.id == "\(plan.turnId.uuidString):assistant_draft"
        })
        let quote = try XCTUnwrap(assistantDraftRef.quote)

        XCTAssertTrue(quote.contains("Based on your notes"))
        XCTAssertLessThanOrEqual(quote.count, 220)
    }

    func testSilentReviewerDoesNotFlagMemoryReferenceWhenSlowCognitionWasAttached() throws {
        let plan = makeReviewPlan(route: .direction, promptLayers: ["slow_cognition"])
        let artifact = try XCTUnwrap(
            try CognitionReviewer().review(
                plan: plan,
                executionResult: makeExecutionResult(content: "Based on your notes, choose the quieter path.")
            )
        )

        XCTAssertFalse(artifact.riskFlags.contains("unsupported_memory_reference"))
        XCTAssertNoThrow(try artifact.validated())
    }

    func testRunnerSwallowsSilentReviewerFailures() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let runner = ChatTurnRunner(
            conversationSessionStore: ConversationSessionStore(nodeStore: nodeStore),
            turnPlanner: makePlanner(nodeStore: nodeStore),
            turnExecutor: TurnExecutor(
                llmServiceProvider: {
                    FixedLLMService(output: "Still done\n<chat_title>Reviewer failure</chat_title>")
                },
                shouldUseGeminiHistoryCache: { false },
                shouldPersistAssistantThinking: { false }
            ),
            outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false }),
            cognitionReviewer: ThrowingCognitionReviewer()
        )
        let request = TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: nil,
                messages: [],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: .direction
            ),
            inputText: "Help me choose the next direction",
            attachments: [],
            now: Date(timeIntervalSince1970: 5_000)
        )
        let sink = TurnSequencedEventSink(turnId: request.turnId, sink: NoOpTurnEventSink())

        let completion = await runner.run(
            request: request,
            sink: sink,
            abortReason: { .unexpectedCancellation }
        )

        XCTAssertNotNil(completion)
    }

    func testRunnerDoesNotRecordSilentReviewArtifactWhenCommitFails() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let reviewer = RecordingCognitionReviewer()
        let capture = ReviewArtifactCapture()
        let snapshotCapture = TurnCognitionSnapshotCapture()
        let runner = ChatTurnRunner(
            conversationSessionStore: ConversationSessionStore(nodeStore: nodeStore),
            turnPlanner: makePlanner(nodeStore: nodeStore),
            turnExecutor: TurnExecutor(
                llmServiceProvider: {
                    NodeDeletingLLMService(
                        nodeStore: nodeStore,
                        output: "Plan ready\n<chat_title>Commit failure</chat_title>"
                    )
                },
                shouldUseGeminiHistoryCache: { false },
                shouldPersistAssistantThinking: { false }
            ),
            outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false }),
            cognitionReviewer: reviewer,
            onReviewArtifact: { capture.append($0) },
            onTurnCognitionSnapshot: { snapshotCapture.append($0) }
        )
        let request = TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: nil,
                messages: [],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: .plan
            ),
            inputText: "Help me plan the next long-turn cognition step",
            attachments: [],
            now: Date(timeIntervalSince1970: 5_000)
        )
        let sink = TurnSequencedEventSink(turnId: request.turnId, sink: NoOpTurnEventSink())

        let completion = await runner.run(
            request: request,
            sink: sink,
            abortReason: { .unexpectedCancellation }
        )

        XCTAssertNil(completion)
        XCTAssertTrue(reviewer.reviewedTurnIds.isEmpty)
        XCTAssertTrue(capture.values().isEmpty)
        XCTAssertTrue(snapshotCapture.values().isEmpty)
    }

    private func makePlanner(
        nodeStore: NodeStore,
        currentProvider: LLMProvider = .gemini,
        judgeLLMServiceFactory: @escaping () -> (any LLMService)? = { nil },
        slowCognitionArtifactProvider: (any SlowCognitionArtifactProviding)? = nil
    ) -> TurnPlanner {
        let core = UserMemoryCore(nodeStore: nodeStore, llmServiceProvider: { nil })
        return TurnPlanner(
            nodeStore: nodeStore,
            vectorStore: VectorStore(nodeStore: nodeStore),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(nodeStore: nodeStore),
            contradictionMemoryService: ContradictionMemoryService(core: core),
            currentProviderProvider: { currentProvider },
            judgeLLMServiceFactory: judgeLLMServiceFactory,
            slowCognitionArtifactProvider: slowCognitionArtifactProvider
        )
    }

    private func makeReviewPlan(
        route: TurnRoute,
        promptLayers: [String] = []
    ) -> TurnPlan {
        let node = NousNode(type: .conversation, title: "Review test")
        let message = Message(
            nodeId: node.id,
            role: .user,
            content: "Help me decide the next step for Nous."
        )
        let prepared = PreparedConversationTurn(
            node: node,
            userMessage: message,
            messagesAfterUserAppend: [message]
        )
        let stewardTrace = TurnStewardTrace(
            route: route,
            memoryPolicy: .lean,
            challengeStance: .surfaceTension,
            responseShape: route == .direction ? .listDirections : .answerNow,
            projectSignalKind: nil,
            source: .deterministic,
            reason: "test"
        )
        return TurnPlan(
            turnId: UUID(),
            prepared: prepared,
            citations: [],
            promptTrace: PromptGovernanceTrace(
                promptLayers: promptLayers,
                evidenceAttached: false,
                safetyPolicyInvoked: false,
                highRiskQueryDetected: false,
                turnSteward: stewardTrace
            ),
            effectiveMode: .companion,
            nextQuickActionModeIfCompleted: route.quickActionMode,
            judgeEventDraft: nil,
            turnSlice: TurnSystemSlice(stable: "Anchor", volatile: ""),
            transcriptMessages: [
                LLMMessage(role: "user", content: message.content)
            ],
            focusBlock: nil,
            provider: .gemini
        )
    }

    private func makeExecutionResult(content: String) -> TurnExecutionResult {
        TurnExecutionResult(
            rawAssistantContent: content,
            assistantContent: content,
            persistedThinking: nil,
            conversationTitle: nil,
            didHitBudgetExhaustion: false
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

private final class ReviewArtifactCapture {
    private var artifacts: [CognitionArtifact] = []

    func append(_ artifact: CognitionArtifact) {
        artifacts.append(artifact)
    }

    func values() -> [CognitionArtifact] {
        artifacts
    }
}

private final class TurnCognitionSnapshotCapture {
    private var snapshots: [TurnCognitionSnapshot] = []

    func append(_ snapshot: TurnCognitionSnapshot) {
        snapshots.append(snapshot)
    }

    func values() -> [TurnCognitionSnapshot] {
        snapshots
    }
}

private struct FixedSlowCognitionArtifactProvider: SlowCognitionArtifactProviding {
    let fixedArtifacts: [CognitionArtifact]

    init(artifacts: [CognitionArtifact]) {
        self.fixedArtifacts = artifacts
    }

    func artifacts(
        userId: String,
        currentInput: String,
        currentNode: NousNode,
        projectId: UUID?,
        now: Date
    ) throws -> [CognitionArtifact] {
        fixedArtifacts
    }
}

private final class RecordingCognitionReviewer: CognitionReviewing {
    private(set) var reviewedTurnIds: [UUID] = []
    private(set) var reviewedAssistantContents: [String] = []

    func review(plan: TurnPlan, executionResult: TurnExecutionResult) throws -> CognitionArtifact? {
        reviewedTurnIds.append(plan.turnId)
        reviewedAssistantContents.append(executionResult.assistantContent)
        return CognitionArtifact(
            organ: .reviewer,
            title: "Silent review",
            summary: "The reviewer checked this high-stakes turn.",
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
                sourceJobId: "silent_post_turn_review"
            )
        )
    }
}

private final class ThrowingCognitionReviewer: CognitionReviewing {
    func review(plan: TurnPlan, executionResult: TurnExecutionResult) throws -> CognitionArtifact? {
        throw ReviewerTestError.boom
    }
}

private enum ReviewerTestError: Error {
    case boom
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

private final class NodeDeletingLLMService: LLMService {
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
