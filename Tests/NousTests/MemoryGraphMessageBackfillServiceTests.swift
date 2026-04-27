import XCTest
@testable import Nous

final class MemoryGraphMessageBackfillServiceTests: XCTestCase {

    var store: NodeStore!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    func testBackfillsDecisionChainsFromRawUserMessages() async throws {
        let capture = PromptListCapture()
        let mock = QueueBackfillLLM(capture: capture, replies: [
            """
            {
              "decision_chains": [
                {
                  "rejected_proposal":"Rebuild the entire retrieval stack.",
                  "rejection":"Alex rejected turning this into a full retrieval rewrite.",
                  "reasons":["Cash runway is tight."],
                  "replacement":"Build the smallest graph-memory slice first.",
                  "evidence_quote":"No, don't turn this into a full retrieval rewrite. Cash runway is tight.",
                  "confidence":0.91
                }
              ]
            }
            """
        ])
        let service = MemoryGraphMessageBackfillService(nodeStore: store, llmServiceProvider: { mock })

        let conversation = NousNode(
            type: .conversation,
            title: "Memory architecture",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try store.insertNode(conversation)
        try store.insertMessage(Message(
            nodeId: conversation.id,
            role: .assistant,
            content: "You should rewrite the entire retrieval stack.",
            timestamp: Date(timeIntervalSince1970: 1)
        ))
        try store.insertMessage(Message(
            nodeId: conversation.id,
            role: .user,
            content: "No, don't turn this into a full retrieval rewrite. Cash runway is tight. Build the smallest graph-memory slice first.",
            timestamp: Date(timeIntervalSince1970: 2)
        ))

        let report = await service.runIfNeeded(maxConversations: 4)

        XCTAssertEqual(report.processedConversations, 1)
        XCTAssertEqual(report.insertedAtoms, 4)
        XCTAssertEqual(report.insertedEdges, 3)
        XCTAssertEqual(report.insertedMarkers, 1)

        let prompts = await capture.prompts()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("ALEX ONLY"))
        XCTAssertTrue(prompts[0].contains("Cash runway is tight"))
        XCTAssertFalse(prompts[0].contains("You should rewrite the entire retrieval stack."))

        let graphStore = MemoryGraphStore(nodeStore: store)
        let rejection = try XCTUnwrap(try store.fetchMemoryAtoms().first { $0.type == .rejection })
        let chain = try XCTUnwrap(graphStore.decisionChain(for: rejection.id))
        XCTAssertEqual(chain.rejectedProposal?.statement, "Rebuild the entire retrieval stack.")
        XCTAssertEqual(chain.reasons.map(\.statement), ["Cash runway is tight."])
        XCTAssertEqual(chain.replacement?.statement, "Build the smallest graph-memory slice first.")
        XCTAssertEqual(rejection.sourceNodeId, conversation.id)
        XCTAssertEqual(rejection.sourceMessageId, try store.fetchMessages(nodeId: conversation.id).last?.id)
        XCTAssertEqual(rejection.eventTime, Date(timeIntervalSince1970: 2))

        let recall = UserMemoryService(nodeStore: store, llmServiceProvider: { nil })
            .currentDecisionGraphRecall(
                currentMessage: "之前否決過邊個方案，點解？",
                projectId: nil,
                conversationId: UUID()
            )
        XCTAssertEqual(recall.count, 1)
        XCTAssertTrue(recall[0].contains("Rebuild the entire retrieval stack."))
        XCTAssertTrue(recall[0].contains("Cash runway is tight."))
        XCTAssertTrue(recall[0].contains("source_message_id="))
        XCTAssertTrue(recall[0].contains("event_time=1970-01-01T00:00:02Z"))
    }

    func testBackfillSkipsAlreadyProcessedFingerprint() async throws {
        let capture = PromptListCapture()
        let mock = QueueBackfillLLM(capture: capture, replies: [
            #"{"decision_chains":[]}"#,
            #"{"decision_chains":[{"rejected_proposal":"Should not run","rejection":"Should not run","reasons":[],"confidence":0.8}]}"#
        ])
        let service = MemoryGraphMessageBackfillService(nodeStore: store, llmServiceProvider: { mock })

        let conversation = NousNode(type: .conversation, title: "No durable decisions")
        try store.insertNode(conversation)
        try store.insertMessage(Message(
            nodeId: conversation.id,
            role: .user,
            content: "Let's just think out loud today.",
            timestamp: Date(timeIntervalSince1970: 1)
        ))

        let first = await service.runIfNeeded(maxConversations: 4)
        let second = await service.runIfNeeded(maxConversations: 4)

        XCTAssertEqual(first.processedConversations, 1)
        XCTAssertEqual(first.insertedMarkers, 1)
        XCTAssertEqual(second.processedConversations, 0)
        XCTAssertEqual(second.skippedAlreadyProcessed, 1)
        XCTAssertTrue(try store.fetchMemoryAtoms().isEmpty)
        XCTAssertEqual(try store.fetchMemoryObservations().count, 1)
        let promptCount = await capture.prompts().count
        XCTAssertEqual(promptCount, 1)
    }

    func testBackfillSkipsAssistantOnlyConversationWithoutCallingLLM() async throws {
        let capture = PromptListCapture()
        let mock = QueueBackfillLLM(capture: capture, replies: [
            #"{"decision_chains":[{"rejected_proposal":"Should not run","rejection":"Should not run","reasons":[],"confidence":0.8}]}"#
        ])
        let service = MemoryGraphMessageBackfillService(nodeStore: store, llmServiceProvider: { mock })

        let conversation = NousNode(type: .conversation, title: "Assistant only")
        try store.insertNode(conversation)
        try store.insertMessage(Message(
            nodeId: conversation.id,
            role: .assistant,
            content: "No user evidence here.",
            timestamp: Date(timeIntervalSince1970: 1)
        ))

        let report = await service.runIfNeeded(maxConversations: 4)

        XCTAssertEqual(report.skippedNoUserTurns, 1)
        XCTAssertEqual(report.processedConversations, 0)
        let promptCount = await capture.prompts().count
        XCTAssertEqual(promptCount, 0)
        XCTAssertTrue(try store.fetchMemoryAtoms().isEmpty)
        XCTAssertTrue(try store.fetchMemoryObservations().isEmpty)
    }

    func testBackfillDropsDecisionChainWhenEvidenceQuoteDoesNotMatchUserMessage() async throws {
        let capture = PromptListCapture()
        let mock = QueueBackfillLLM(capture: capture, replies: [
            """
            {
              "decision_chains": [
                {
                  "rejected_proposal":"Rewrite every memory layer.",
                  "rejection":"Alex rejected a full rewrite.",
                  "reasons":["It would be too slow."],
                  "evidence_quote":"This quote never appeared in Alex's message.",
                  "confidence":0.95
                }
              ]
            }
            """
        ])
        let service = MemoryGraphMessageBackfillService(nodeStore: store, llmServiceProvider: { mock })

        let conversation = NousNode(type: .conversation, title: "Unverified chain")
        try store.insertNode(conversation)
        try store.insertMessage(Message(
            nodeId: conversation.id,
            role: .user,
            content: "Let's avoid a huge rewrite and do the smallest memory patch.",
            timestamp: Date(timeIntervalSince1970: 3)
        ))

        let report = await service.runIfNeeded(maxConversations: 4)

        XCTAssertEqual(report.processedConversations, 1)
        XCTAssertEqual(report.droppedUnverifiedChains, 1)
        XCTAssertTrue(try store.fetchMemoryAtoms().isEmpty)
        XCTAssertEqual(try store.fetchMemoryObservations().count, 2)
    }

    func testBackfillReturnsNoOpWithoutLLMProvider() async throws {
        let service = MemoryGraphMessageBackfillService(nodeStore: store, llmServiceProvider: { nil })

        let conversation = NousNode(type: .conversation, title: "No provider")
        try store.insertNode(conversation)
        try store.insertMessage(Message(
            nodeId: conversation.id,
            role: .user,
            content: "We rejected a plan, but no provider is configured.",
            timestamp: Date(timeIntervalSince1970: 1)
        ))

        let report = await service.runIfNeeded(maxConversations: 4)

        XCTAssertEqual(report, MemoryGraphMessageBackfillReport())
        XCTAssertTrue(try store.fetchMemoryAtoms().isEmpty)
    }
}

private actor PromptListCapture {
    private var captured: [String] = []

    func record(_ prompt: String) {
        captured.append(prompt)
    }

    func prompts() -> [String] {
        captured
    }
}

private actor BackfillReplyQueue {
    private var replies: [String]

    init(replies: [String]) {
        self.replies = replies
    }

    func next() -> String {
        guard !replies.isEmpty else { return "" }
        return replies.removeFirst()
    }
}

private struct QueueBackfillLLM: LLMService {
    let capture: PromptListCapture
    let replies: BackfillReplyQueue

    init(capture: PromptListCapture, replies: [String]) {
        self.capture = capture
        self.replies = BackfillReplyQueue(replies: replies)
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        let prompt = messages.first(where: { $0.role == "user" })?.content ?? ""
        await capture.record(prompt)
        let reply = await replies.next()

        return AsyncThrowingStream { continuation in
            continuation.yield(reply)
            continuation.finish()
        }
    }
}
