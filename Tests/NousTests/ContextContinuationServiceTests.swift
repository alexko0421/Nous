import XCTest
@testable import Nous

private struct RefreshConversationCall: Sendable {
    let nodeId: UUID
    let projectId: UUID?
    let messageContents: [String]
}

private final class RecordingMemorySynthesizer: MemorySynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private var refreshConversationCalls: [RefreshConversationCall] = []

    func refreshConversation(nodeId: UUID, projectId: UUID?, messages: [Message]) async {
        lock.withLock {
            refreshConversationCalls.append(
                RefreshConversationCall(
                    nodeId: nodeId,
                    projectId: projectId,
                    messageContents: messages.map(\.content)
                )
            )
        }
    }

    func refreshProject(projectId: UUID) async {}

    func shouldRefreshProject(projectId: UUID, threshold: Int) -> Bool {
        false
    }

    func promoteToGlobal(
        candidate: String,
        sourceNodeIds: [UUID],
        confirmation: UserMemoryCore.PersonalInferenceDisposition
    ) async -> Bool {
        false
    }

    func recordedRefreshConversationCalls() -> [RefreshConversationCall] {
        lock.withLock {
            refreshConversationCalls
        }
    }
}

@MainActor
final class ContextContinuationServiceTests: XCTestCase {
    private func makeScratchPadStore(nodeStore: NodeStore) -> ScratchPadStore {
        let suiteName = "ContextContinuationServiceTests.scratchpad.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ScratchPadStore(nodeStore: nodeStore, defaults: defaults)
    }

    private func makeTelemetry(nodeStore: NodeStore? = nil) -> GovernanceTelemetryStore {
        let suiteName = "ContextContinuationServiceTests.telemetry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return GovernanceTelemetryStore(defaults: defaults, nodeStore: nodeStore)
    }

    func testRunIngestsScratchpadAndRecordsSuppressedMemoryWhenRefreshMissing() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let conversation = NousNode(type: .conversation, title: "Scratchpad")
        try nodeStore.insertNode(conversation)

        let scratchPadStore = makeScratchPadStore(nodeStore: nodeStore)
        scratchPadStore.activate(conversationId: conversation.id)

        let synthesizer = RecordingMemorySynthesizer()
        let scheduler = UserMemoryScheduler(service: synthesizer)
        let telemetry = makeTelemetry()
        let service = ContextContinuationService(
            scratchPadStore: scratchPadStore,
            userMemoryScheduler: scheduler,
            governanceTelemetry: telemetry
        )

        let assistantMessageId = UUID()
        await service.run(
            ContextContinuationPlan(
                turnId: UUID(),
                conversationId: conversation.id,
                assistantMessageId: assistantMessageId,
                scratchpadIngest: ScratchpadIngestRequest(
                    content: """
                    整好了。
                    <summary>
                    # 今次倾咗乜

                    ## 问题
                    想拆 Step 6 seam。

                    ## 思考
                    先拆 post-turn flow。

                    ## 结论
                    continuation 同 housekeeping 分开。

                    ## 下一步
                    - 落 test
                    </summary>
                    """,
                    sourceMessageId: assistantMessageId,
                    conversationId: conversation.id
                ),
                memoryRefresh: nil,
                memorySuppressionReason: .hardOptOut
            )
        )

        XCTAssertEqual(scratchPadStore.latestSummary?.sourceMessageId, assistantMessageId)
        XCTAssertTrue(scratchPadStore.latestSummary?.markdown.contains("Step 6 seam") == true)
        XCTAssertEqual(telemetry.memoryStorageSuppressedCount(), 1)
        XCTAssertEqual(telemetry.memoryStorageSuppressedCount(reason: .hardOptOut), 1)
        XCTAssertEqual(telemetry.memoryStorageSuppressedCount(reason: .sensitiveConsentRequired), 0)
        let calls = synthesizer.recordedRefreshConversationCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testRunRecordsUnspecifiedSuppressionReasonWhenLegacyPlanOmitsReason() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let conversation = NousNode(type: .conversation, title: "Legacy suppression")
        try nodeStore.insertNode(conversation)

        let telemetry = makeTelemetry()
        let service = ContextContinuationService(
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore),
            userMemoryScheduler: UserMemoryScheduler(service: RecordingMemorySynthesizer()),
            governanceTelemetry: telemetry
        )

        await service.run(
            ContextContinuationPlan(
                turnId: UUID(),
                conversationId: conversation.id,
                assistantMessageId: UUID(),
                scratchpadIngest: nil,
                memoryRefresh: nil
            )
        )

        XCTAssertEqual(telemetry.memoryStorageSuppressedCount(), 1)
        XCTAssertEqual(telemetry.memoryStorageSuppressedCount(reason: .unspecified), 1)
    }

    func testTurnOutcomeFactoryCarriesSuppressionReasonIntoContinuationPlan() {
        let conversation = NousNode(type: .conversation, title: "Suppression reason")
        let userMessage = Message(nodeId: conversation.id, role: .user, content: "Sensitive turn")
        let assistantMessage = Message(nodeId: conversation.id, role: .assistant, content: "I will not store that.")
        let factory = TurnOutcomeFactory(
            memoryPersistenceDecision: { _, _ in .suppress(.sensitiveConsentRequired) }
        )

        let completion = factory.makeCompletion(
            turnId: UUID(),
            nextQuickActionModeIfCompleted: nil,
            committed: CommittedAssistantTurn(
                node: conversation,
                assistantMessage: assistantMessage,
                messagesAfterAssistantAppend: [userMessage, assistantMessage]
            ),
            assistantContent: assistantMessage.content,
            stableSystem: "stable"
        )

        XCTAssertNil(completion.continuationPlan.memoryRefresh)
        XCTAssertEqual(completion.continuationPlan.memorySuppressionReason, .sensitiveConsentRequired)
        XCTAssertNil(
            completion.housekeepingPlan.embeddingRefresh,
            "suppressed memory turns must not enqueue a full-transcript embedding candidate"
        )
    }

    func testTurnOutcomeFactorySuppressesHeavyPostTurnWorkForFastLatencyTier() {
        let conversation = NousNode(type: .conversation, title: "Fast utility")
        let userMessage = Message(nodeId: conversation.id, role: .user, content: "what does TTFT mean?")
        let assistantMessage = Message(nodeId: conversation.id, role: .assistant, content: "Time to first token.")
        let factory = TurnOutcomeFactory(
            memoryPersistenceDecision: { _, _ in .persist }
        )

        let completion = factory.makeCompletion(
            turnId: UUID(),
            nextQuickActionModeIfCompleted: nil,
            committed: CommittedAssistantTurn(
                node: conversation,
                assistantMessage: assistantMessage,
                messagesAfterAssistantAppend: [userMessage, assistantMessage]
            ),
            assistantContent: assistantMessage.content,
            stableSystem: "stable",
            userMessage: userMessage,
            latencyTier: .fast
        )

        XCTAssertNil(completion.continuationPlan.scratchpadIngest)
        XCTAssertNil(completion.continuationPlan.memoryRefresh)
        XCTAssertEqual(completion.continuationPlan.memorySuppressionReason, .fastLatencyTier)
        XCTAssertNil(completion.continuationPlan.sourceLearningDigest)
        XCTAssertNil(completion.housekeepingPlan.geminiCacheRefresh)
        XCTAssertNil(completion.housekeepingPlan.embeddingRefresh)
        XCTAssertNil(completion.housekeepingPlan.emojiRefresh)
    }

    func testTurnOutcomeFactoryCreatesSourceLearningDigestForAttachedSourceTurnWhenMemoryPersists() {
        let conversation = NousNode(type: .conversation, title: "YouTube discussion", projectId: UUID())
        let sourceNodeId = UUID()
        let userMessage = Message(
            nodeId: conversation.id,
            role: .user,
            content: "I think this leader-role idea is key to my community strategy"
        )
        let assistantMessage = Message(nodeId: conversation.id, role: .assistant, content: "Let's unpack that section.")
        let sourceMaterial = SourceMaterialContext(
            sourceNodeId: sourceNodeId,
            title: "How to Start a Cult",
            originalURL: "https://www.youtube.com/watch?v=OQ0OOzOwsJY",
            originalFilename: nil,
            chunks: [
                SourceChunkContext(
                    sourceNodeId: sourceNodeId,
                    ordinal: 0,
                    text: "00:18 Leaders create the initial shared worldview.",
                    similarity: nil
                )
            ],
            evidenceLevel: .transcriptBacked
        )
        let factory = TurnOutcomeFactory(
            memoryPersistenceDecision: { _, _ in .persist }
        )

        let completion = factory.makeCompletion(
            turnId: UUID(),
            nextQuickActionModeIfCompleted: nil,
            committed: CommittedAssistantTurn(
                node: conversation,
                assistantMessage: assistantMessage,
                messagesAfterAssistantAppend: [userMessage, assistantMessage]
            ),
            assistantContent: assistantMessage.content,
            stableSystem: "stable",
            userMessage: userMessage,
            sourceMaterials: [sourceMaterial]
        )

        let digest = completion.continuationPlan.sourceLearningDigest
        XCTAssertEqual(digest?.conversationId, conversation.id)
        XCTAssertEqual(digest?.projectId, conversation.projectId)
        XCTAssertEqual(digest?.userMessage.id, userMessage.id)
        XCTAssertEqual(digest?.assistantMessage.id, assistantMessage.id)
        XCTAssertEqual(digest?.sourceMaterials.first?.sourceNodeId, sourceNodeId)
        XCTAssertEqual(digest?.sourceMaterials.first?.evidenceLevel, .transcriptBacked)
    }

    func testTurnOutcomeFactorySuppressesSourceLearningWhenMemoryIsSuppressed() {
        let conversation = NousNode(type: .conversation, title: "YouTube discussion", projectId: UUID())
        let userMessage = Message(
            nodeId: conversation.id,
            role: .user,
            content: "I think this leader-role idea is key to my community strategy"
        )
        let assistantMessage = Message(nodeId: conversation.id, role: .assistant, content: "Let's unpack that section.")
        let sourceNodeId = UUID()
        let sourceMaterial = SourceMaterialContext(
            sourceNodeId: sourceNodeId,
            title: "How to Start a Cult",
            originalURL: "https://www.youtube.com/watch?v=OQ0OOzOwsJY",
            originalFilename: nil,
            chunks: [
                SourceChunkContext(
                    sourceNodeId: sourceNodeId,
                    ordinal: 0,
                    text: "00:18 Leaders create the initial shared worldview.",
                    similarity: nil
                )
            ],
            evidenceLevel: .transcriptBacked
        )
        let factory = TurnOutcomeFactory(
            memoryPersistenceDecision: { _, _ in .suppress(.hardOptOut) }
        )

        let completion = factory.makeCompletion(
            turnId: UUID(),
            nextQuickActionModeIfCompleted: nil,
            committed: CommittedAssistantTurn(
                node: conversation,
                assistantMessage: assistantMessage,
                messagesAfterAssistantAppend: [userMessage, assistantMessage]
            ),
            assistantContent: assistantMessage.content,
            stableSystem: "stable",
            userMessage: userMessage,
            sourceMaterials: [sourceMaterial]
        )

        XCTAssertNil(completion.continuationPlan.memoryRefresh)
        XCTAssertEqual(completion.continuationPlan.memorySuppressionReason, .hardOptOut)
        XCTAssertNil(completion.continuationPlan.sourceLearningDigest)
    }

    func testRunDoesNotScheduleSourceLearningWhenMemoryRefreshIsSuppressed() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let projectId = UUID()
        try nodeStore.insertProject(Project(id: projectId, title: "Community"))
        let conversation = NousNode(type: .conversation, title: "YouTube chat", projectId: projectId)
        let sourceNode = NousNode(
            type: .source,
            title: "How to Start a Cult",
            content: "00:18 Leaders create the initial shared worldview."
        )
        try nodeStore.insertNode(conversation)
        try nodeStore.insertNode(sourceNode)

        let userMessage = Message(
            nodeId: conversation.id,
            role: .user,
            content: "I think this leader-role idea is key to my community strategy"
        )
        let assistantMessage = Message(nodeId: conversation.id, role: .assistant, content: "This is about leader role.")
        try nodeStore.insertMessage(userMessage)
        try nodeStore.insertMessage(assistantMessage)

        let material = SourceMaterialContext(
            sourceNodeId: sourceNode.id,
            title: sourceNode.title,
            originalURL: "https://www.youtube.com/watch?v=OQ0OOzOwsJY",
            originalFilename: nil,
            chunks: [
                SourceChunkContext(
                    sourceNodeId: sourceNode.id,
                    ordinal: 0,
                    text: "00:18 Leaders create the initial shared worldview.",
                    similarity: nil
                )
            ],
            evidenceLevel: .transcriptBacked
        )
        let sourceLearningService = SourceLearningMemoryService(
            nodeStore: nodeStore,
            llmServiceProvider: {
                StaticContextSourceLearningLLM(output: """
                {
                  "candidates": [
                    {
                      "type": "insight",
                      "statement": "Alex sees the leader-role framing as key to his community strategy.",
                      "scope": "project",
                      "confidence": 0.83,
                      "evidence_quote": "I think this leader-role idea is key to my community strategy"
                    }
                  ]
                }
                """)
            },
            now: { Date(timeIntervalSince1970: 10) }
        )
        let sourceLearningScheduler = SourceLearningMemoryScheduler(service: sourceLearningService)
        let telemetry = makeTelemetry()
        let service = ContextContinuationService(
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore),
            userMemoryScheduler: UserMemoryScheduler(service: RecordingMemorySynthesizer()),
            governanceTelemetry: telemetry,
            sourceLearningScheduler: sourceLearningScheduler
        )

        await service.run(
            ContextContinuationPlan(
                turnId: UUID(),
                conversationId: conversation.id,
                assistantMessageId: assistantMessage.id,
                scratchpadIngest: nil,
                memoryRefresh: nil,
                memorySuppressionReason: .hardOptOut,
                sourceLearningDigest: SourceLearningDigestRequest(
                    conversationId: conversation.id,
                    projectId: projectId,
                    userMessage: userMessage,
                    assistantMessage: assistantMessage,
                    sourceMaterials: [material]
                )
            )
        )
        await sourceLearningScheduler.waitUntilIdle()

        XCTAssertEqual(telemetry.memoryStorageSuppressedCount(reason: .hardOptOut), 1)
        XCTAssertTrue(try nodeStore.fetchMemoryAtoms().isEmpty)
    }

    func testRunEnqueuesMemoryRefreshWhenRequested() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let conversation = NousNode(type: .conversation, title: "Memory refresh")
        try nodeStore.insertNode(conversation)

        let scratchPadStore = makeScratchPadStore(nodeStore: nodeStore)
        let synthesizer = RecordingMemorySynthesizer()
        let scheduler = UserMemoryScheduler(service: synthesizer)
        let telemetry = makeTelemetry()
        let service = ContextContinuationService(
            scratchPadStore: scratchPadStore,
            userMemoryScheduler: scheduler,
            governanceTelemetry: telemetry
        )

        let messages = [
            Message(nodeId: conversation.id, role: .user, content: "Should I keep this memory?"),
            Message(nodeId: conversation.id, role: .assistant, content: "Yes, this one matters.")
        ]
        let projectId = UUID()
        await service.run(
            ContextContinuationPlan(
                turnId: UUID(),
                conversationId: conversation.id,
                assistantMessageId: UUID(),
                scratchpadIngest: nil,
                memoryRefresh: EnqueueMemoryRefreshRequest(
                    nodeId: conversation.id,
                    projectId: projectId,
                    messages: messages
                )
            )
        )

        for _ in 0..<20 {
            if !synthesizer.recordedRefreshConversationCalls().isEmpty {
                break
            }
            await Task.yield()
        }
        await scheduler.waitUntilIdle()

        let calls = synthesizer.recordedRefreshConversationCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.nodeId, conversation.id)
        XCTAssertEqual(calls.first?.projectId, projectId)
        XCTAssertEqual(calls.first?.messageContents, messages.map(\.content))
        XCTAssertEqual(telemetry.memoryStorageSuppressedCount(), 0)
    }
}

private struct StaticContextSourceLearningLLM: LLMService {
    let output: String

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}
