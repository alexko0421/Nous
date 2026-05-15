import XCTest
@testable import Nous

final class InTurnPatternProposalServiceTests: XCTestCase {
    private var store: NodeStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    func testRepeatedHighConfidenceSignalsStagePendingPatternAfterSevenDaySpan() throws {
        let node = try seedConversation()
        let start = Date(timeIntervalSince1970: 10_000)
        let messages = try [
            seedUserMessage(nodeId: node.id, timestamp: start),
            seedUserMessage(nodeId: node.id, timestamp: start.addingTimeInterval(3 * 86_400)),
            seedUserMessage(nodeId: node.id, timestamp: start.addingTimeInterval(8 * 86_400))
        ]
        let service = InTurnPatternProposalService(nodeStore: store)

        XCTAssertEqual(
            try service.record(
                signal: signal(.learningInsteadOfShipping),
                sourceNodeId: node.id,
                sourceMessageId: messages[0].id,
                projectId: nil,
                now: messages[0].timestamp
            ),
            .recorded(evidenceCount: 1, daySpan: 0)
        )
        XCTAssertEqual(
            try service.record(
                signal: signal(.learningInsteadOfShipping),
                sourceNodeId: node.id,
                sourceMessageId: messages[1].id,
                projectId: nil,
                now: messages[1].timestamp
            ),
            .recorded(evidenceCount: 2, daySpan: 3)
        )

        let result = try service.record(
            signal: signal(.learningInsteadOfShipping),
            sourceNodeId: node.id,
            sourceMessageId: messages[2].id,
            projectId: nil,
            now: messages[2].timestamp
        )

        guard case let .staged(atom, evidenceMessageIds) = result else {
            return XCTFail("Expected third high-confidence signal across 7+ days to stage a pending pattern.")
        }
        XCTAssertEqual(atom.status, .pending)
        XCTAssertEqual(atom.type, .pattern)
        XCTAssertEqual(atom.scope, .selfReflection)
        XCTAssertEqual(atom.authority, .tentative)
        XCTAssertEqual(atom.sourceMessageId, messages[2].id)
        XCTAssertTrue(atom.statement.contains("learning instead of shipping"))
        XCTAssertTrue(atom.statement.contains("turn one insight into behavior or a test before consuming more"))
        XCTAssertEqual(Set(evidenceMessageIds), Set(messages.map(\.id)))
        XCTAssertEqual(try MemoryLifecycleEngine(nodeStore: store).inbox().map(\.atom.id), [atom.id])
        XCTAssertEqual(try store.fetchMemoryObservations().filter { $0.extractedType == .pattern }.count, 3)
    }

    func testDoesNotStageBeforeMinimumIndependentTurnsOrSevenDaySpan() throws {
        let node = try seedConversation()
        let start = Date(timeIntervalSince1970: 20_000)
        let messages = try [
            seedUserMessage(nodeId: node.id, timestamp: start),
            seedUserMessage(nodeId: node.id, timestamp: start.addingTimeInterval(2 * 86_400)),
            seedUserMessage(nodeId: node.id, timestamp: start.addingTimeInterval(4 * 86_400))
        ]
        let service = InTurnPatternProposalService(nodeStore: store)

        for message in messages {
            _ = try service.record(
                signal: signal(.notReadyRationalization),
                sourceNodeId: node.id,
                sourceMessageId: message.id,
                projectId: nil,
                now: message.timestamp
            )
        }

        XCTAssertTrue(try MemoryLifecycleEngine(nodeStore: store).inbox().isEmpty)
        XCTAssertEqual(try store.fetchMemoryObservations().filter { $0.extractedType == .pattern }.count, 3)
    }

    func testExplicitConfirmationCanStageBeforeSevenDaySpan() throws {
        let node = try seedConversation()
        let start = Date(timeIntervalSince1970: 30_000)
        let messages = try [
            seedUserMessage(nodeId: node.id, timestamp: start),
            seedUserMessage(nodeId: node.id, timestamp: start.addingTimeInterval(3_600)),
            seedUserMessage(nodeId: node.id, timestamp: start.addingTimeInterval(7_200))
        ]
        let service = InTurnPatternProposalService(nodeStore: store)

        for message in messages.dropLast() {
            _ = try service.record(
                signal: signal(.bigSystemEscape),
                sourceNodeId: node.id,
                sourceMessageId: message.id,
                projectId: nil,
                now: message.timestamp
            )
        }
        let result = try service.record(
            signal: signal(.bigSystemEscape),
            sourceNodeId: node.id,
            sourceMessageId: messages[2].id,
            projectId: nil,
            now: messages[2].timestamp,
            userConfirmed: true
        )

        guard case let .staged(atom, evidenceMessageIds) = result else {
            return XCTFail("Expected explicit confirmation to bypass the 7-day wait.")
        }
        XCTAssertEqual(atom.status, .pending)
        XCTAssertEqual(Set(evidenceMessageIds), Set(messages.map(\.id)))
    }

    func testRejectedPatternProposalStaysSticky() throws {
        let node = try seedConversation()
        let start = Date(timeIntervalSince1970: 40_000)
        let messages = try [
            seedUserMessage(nodeId: node.id, timestamp: start),
            seedUserMessage(nodeId: node.id, timestamp: start.addingTimeInterval(4 * 86_400)),
            seedUserMessage(nodeId: node.id, timestamp: start.addingTimeInterval(8 * 86_400)),
            seedUserMessage(nodeId: node.id, timestamp: start.addingTimeInterval(10 * 86_400))
        ]
        let service = InTurnPatternProposalService(nodeStore: store)
        var stagedAtom: MemoryAtom?

        for message in messages.prefix(3) {
            let result = try service.record(
                signal: signal(.externalJudgmentSensitivity),
                sourceNodeId: node.id,
                sourceMessageId: message.id,
                projectId: nil,
                now: message.timestamp
            )
            if case let .staged(atom, _) = result {
                stagedAtom = atom
            }
        }
        let atom = try XCTUnwrap(stagedAtom)
        _ = try MemoryLifecycleEngine(nodeStore: store).reject(atom.id, now: start.addingTimeInterval(9 * 86_400))

        let result = try service.record(
            signal: signal(.externalJudgmentSensitivity),
            sourceNodeId: node.id,
            sourceMessageId: messages[3].id,
            projectId: nil,
            now: messages[3].timestamp
        )

        guard case let .suppressedByRejectedProposal(rejected) = result else {
            return XCTFail("Expected matching rejected proposal to suppress future staging.")
        }
        XCTAssertEqual(rejected.id, atom.id)
        XCTAssertTrue(try MemoryLifecycleEngine(nodeStore: store).inbox().isEmpty)
        XCTAssertEqual(
            try store.fetchMemoryAtoms(types: [.pattern], statuses: [.archived], scope: .selfReflection, scopeRefId: nil, eventTimeStart: nil, eventTimeEnd: nil, limit: nil).map(\.id),
            [atom.id]
        )
    }

    func testRejectedPatternProposalIsOmittedFromWeeklyEvidenceContext() throws {
        let node = try seedConversation()
        let start = Date(timeIntervalSince1970: 45_000)
        let messages = try [
            seedUserMessage(nodeId: node.id, timestamp: start),
            seedUserMessage(nodeId: node.id, timestamp: start.addingTimeInterval(4 * 86_400)),
            seedUserMessage(nodeId: node.id, timestamp: start.addingTimeInterval(8 * 86_400))
        ]
        let service = InTurnPatternProposalService(nodeStore: store)
        var stagedAtom: MemoryAtom?

        for message in messages {
            let result = try service.record(
                signal: signal(.externalJudgmentSensitivity),
                sourceNodeId: node.id,
                sourceMessageId: message.id,
                projectId: nil,
                now: message.timestamp
            )
            if case let .staged(atom, _) = result {
                stagedAtom = atom
            }
        }
        let atom = try XCTUnwrap(stagedAtom)
        _ = try MemoryLifecycleEngine(nodeStore: store).reject(atom.id, now: start.addingTimeInterval(9 * 86_400))

        let context = try service.patternEvidenceContext(
            projectId: nil,
            weekStart: start.addingTimeInterval(-86_400),
            weekEnd: start.addingTimeInterval(10 * 86_400)
        )

        XCTAssertTrue(context.isEmpty)
    }

    func testLowConfidenceSignalDoesNotRecordEvidence() throws {
        let node = try seedConversation()
        let message = try seedUserMessage(nodeId: node.id, timestamp: Date(timeIntervalSince1970: 50_000))
        let service = InTurnPatternProposalService(nodeStore: store)

        let result = try service.record(
            signal: signal(.planningAsAvoidance, confidence: 0.80),
            sourceNodeId: node.id,
            sourceMessageId: message.id,
            projectId: nil,
            now: message.timestamp
        )

        XCTAssertEqual(result, .ignored(reason: .belowHighConfidenceThreshold))
        XCTAssertTrue(try store.fetchMemoryObservations().isEmpty)
    }

    func testChatTurnRunnerRecordsPatternSignalsAfterSuccessfulCommit() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let service = InTurnPatternProposalService(nodeStore: nodeStore)
        let conversationStore = ConversationSessionStore(nodeStore: nodeStore)
        let runner = ChatTurnRunner(
            conversationSessionStore: conversationStore,
            turnPlanner: makePlanner(nodeStore: nodeStore),
            turnExecutor: TurnExecutor(
                llmServiceProvider: {
                    PatternFixedLLMService(output: "Done\n<chat_title>Pattern</chat_title>")
                },
                shouldUseGeminiHistoryCache: { false },
                shouldPersistAssistantThinking: { false }
            ),
            outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false }),
            inTurnPatternProposalService: service
        )
        let start = Date(timeIntervalSince1970: 60_000)
        var node: NousNode?
        var messages: [Message] = []

        for day in [0, 4, 8] {
            let request = TurnRequest(
                turnId: UUID(),
                snapshot: TurnSessionSnapshot(
                    currentNode: node,
                    messages: messages,
                    defaultProjectId: nil,
                    activeChatMode: nil,
                    activeQuickActionMode: nil
                ),
                inputText: "I have enough for a small slice, but I need more research before shipping.",
                attachments: [],
                now: start.addingTimeInterval(TimeInterval(day) * 86_400)
            )
            let completion = await runner.run(
                request: request,
                sink: TurnSequencedEventSink(turnId: request.turnId, sink: PatternNoOpTurnEventSink()),
                abortReason: { .unexpectedCancellation }
            )
            let unwrapped = try XCTUnwrap(completion)
            node = unwrapped.node
            messages = unwrapped.messagesAfterAssistantAppend
        }

        let inbox = try MemoryLifecycleEngine(nodeStore: nodeStore).inbox()
        XCTAssertEqual(inbox.count, 1)
        XCTAssertEqual(inbox.first?.atom.type, .pattern)
        XCTAssertEqual(try nodeStore.fetchMemoryObservations().filter { $0.extractedType == .pattern }.count, 3)
    }

    private func seedConversation(projectId: UUID? = nil) throws -> NousNode {
        let node = NousNode(type: .conversation, title: "Pattern evidence", projectId: projectId)
        try store.insertNode(node)
        return node
    }

    private func seedUserMessage(nodeId: UUID, timestamp: Date) throws -> Message {
        let message = Message(
            nodeId: nodeId,
            role: .user,
            content: "pattern source",
            timestamp: timestamp
        )
        try store.insertMessage(message)
        return message
    }

    private func signal(
        _ kind: InTurnPatternKind,
        confidence: Double = 0.88
    ) -> InTurnPatternSignal {
        InTurnPatternSignal(
            kind: kind,
            confidence: confidence,
            surfacePolicy: .directName,
            reasonCode: "test"
        )
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

private struct PatternNoOpTurnEventSink: TurnEventSink {
    func emit(_ envelope: TurnEventEnvelope) async {}
}

private final class PatternFixedLLMService: LLMService {
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
