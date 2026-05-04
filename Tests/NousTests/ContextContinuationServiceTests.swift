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
