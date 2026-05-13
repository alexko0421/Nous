import XCTest
@testable import Nous

final class SourceLearningMemoryTests: XCTestCase {
    func testAbsorbStagesAlexInsightWithMatchingEvidenceAndSourceProvenance() async throws {
        let store = try NodeStore(path: ":memory:")
        let fixture = try makeRequestFixture(store: store)
        let service = SourceLearningMemoryService(
            nodeStore: store,
            llmServiceProvider: {
                StaticSourceLearningLLM(output: """
                {
                  "candidates": [
                    {
                      "type": "insight",
                      "statement": "Alex sees the leader-role framing as key to his community strategy.",
                      "scope": "project",
                      "confidence": 0.92,
                      "evidence_quote": "I think this leader-role idea is key to my community strategy"
                    }
                  ]
                }
                """)
            },
            now: { Date(timeIntervalSince1970: 10) }
        )

        let result = await service.absorb(fixture.request)

        XCTAssertEqual(result.insertedCount, 1)
        let atom = try XCTUnwrap(try store.fetchMemoryAtoms().first)
        XCTAssertEqual(atom.type, .insight)
        XCTAssertEqual(atom.scope, .project)
        XCTAssertEqual(atom.scopeRefId, fixture.projectId)
        XCTAssertEqual(atom.sourceNodeId, fixture.sourceNode.id)
        XCTAssertEqual(atom.sourceMessageId, fixture.userMessage.id)
        XCTAssertEqual(atom.confidence, 0.86, accuracy: 0.001)
        XCTAssertEqual(atom.status, .pending)

        let recall = try MemoryLifecycleEngine(nodeStore: store).hybridRecall(
            currentMessage: "community strategy leader role",
            projectId: fixture.projectId,
            conversationId: fixture.request.conversationId
        )
        XCTAssertTrue(recall.isEmpty, "Source-attached learning must not enter active recall before approval.")
    }

    func testAbsorbRejectsMissingEvidenceAndPureSourceFacts() async throws {
        let store = try NodeStore(path: ":memory:")
        let fixture = try makeRequestFixture(
            store: store,
            userText: "Explain this",
            evidenceLevel: .transcriptBacked
        )
        let service = SourceLearningMemoryService(
            nodeStore: store,
            llmServiceProvider: {
                StaticSourceLearningLLM(output: """
                {
                  "candidates": [
                    {
                      "type": "insight",
                      "statement": "Alex learned that Lulu says leaders create the initial worldview.",
                      "scope": "conversation",
                      "confidence": 0.8,
                      "evidence_quote": "leaders create the initial worldview"
                    },
                    {
                      "type": "belief",
                      "statement": "",
                      "scope": "conversation",
                      "confidence": 0.7,
                      "evidence_quote": "Explain this"
                    }
                  ]
                }
                """)
            }
        )

        let result = await service.absorb(fixture.request)

        XCTAssertEqual(result.insertedCount, 0)
        XCTAssertEqual(result.rejectedCount, 2)
        XCTAssertTrue(try store.fetchMemoryAtoms().isEmpty)
    }

    func testAbsorbRejectsGenericSourcePromptEvenIfLLMInventsMemoryCandidate() async throws {
        let store = try NodeStore(path: ":memory:")
        let fixture = try makeRequestFixture(
            store: store,
            userText: "Explain this",
            evidenceLevel: .transcriptBacked
        )
        let service = SourceLearningMemoryService(
            nodeStore: store,
            llmServiceProvider: {
                StaticSourceLearningLLM(output: """
                {
                  "candidates": [
                    {
                      "type": "insight",
                      "statement": "Alex asked to analyze this source for future use.",
                      "scope": "conversation",
                      "confidence": 0.8,
                      "evidence_quote": "Explain this"
                    }
                  ]
                }
                """)
            }
        )

        let result = await service.absorb(fixture.request)

        XCTAssertEqual(result.insertedCount, 0)
        XCTAssertEqual(result.rejectedCount, 1)
        XCTAssertTrue(try store.fetchMemoryAtoms().isEmpty)
    }

    func testGeminiBackedSourceCanOnlyCreateMemoryFromAlexOwnStatement() async throws {
        let store = try NodeStore(path: ":memory:")
        let fixture = try makeRequestFixture(
            store: store,
            userText: "我觉得呢个 leader-role idea 真係同我做 community 有关",
            evidenceLevel: .geminiVideoAnalysis
        )
        let service = SourceLearningMemoryService(
            nodeStore: store,
            llmServiceProvider: {
                StaticSourceLearningLLM(output: """
                {
                  "candidates": [
                    {
                      "type": "insight",
                      "statement": "Alex connects the leader-role idea to his community building.",
                      "scope": "conversation",
                      "confidence": 0.82,
                      "evidence_quote": "我觉得呢个 leader-role idea 真係同我做 community 有关"
                    },
                    {
                      "type": "belief",
                      "statement": "Alex believes Lulu says charisma is unpredictable.",
                      "scope": "conversation",
                      "confidence": 0.78,
                      "evidence_quote": "charisma is unpredictable"
                    }
                  ]
                }
                """)
            }
        )

        let result = await service.absorb(fixture.request)

        XCTAssertEqual(result.insertedCount, 1)
        XCTAssertEqual(result.rejectedCount, 1)
        let atom = try XCTUnwrap(try store.fetchMemoryAtoms().first)
        XCTAssertEqual(atom.sourceNodeId, fixture.sourceNode.id)
        XCTAssertEqual(atom.sourceMessageId, fixture.userMessage.id)
        XCTAssertEqual(atom.scope, .conversation)
        XCTAssertEqual(atom.scopeRefId, fixture.request.conversationId)
        XCTAssertEqual(atom.status, .pending)
        XCTAssertTrue(atom.statement.contains("community building"))
    }
}

private struct SourceLearningFixture {
    let projectId: UUID
    let sourceNode: NousNode
    let userMessage: Message
    let request: SourceLearningDigestRequest
}

private func makeRequestFixture(
    store: NodeStore,
    userText: String = "I think this leader-role idea is key to my community strategy",
    evidenceLevel: SourceEvidenceLevel = .transcriptBacked
) throws -> SourceLearningFixture {
    let projectId = UUID()
    try store.insertProject(Project(id: projectId, title: "Community"))
    let conversation = NousNode(type: .conversation, title: "YouTube chat", projectId: projectId)
    let sourceNode = NousNode(
        type: .source,
        title: "How to Start a Cult",
        content: "00:18 Leaders create the initial shared worldview."
    )
    try store.insertNode(conversation)
    try store.insertNode(sourceNode)

    let userMessage = Message(nodeId: conversation.id, role: .user, content: userText)
    let assistantMessage = Message(nodeId: conversation.id, role: .assistant, content: "This section is about leader role.")
    try store.insertMessage(userMessage)
    try store.insertMessage(assistantMessage)

    let material = SourceMaterialContext(
        sourceNodeId: sourceNode.id,
        title: sourceNode.title,
        originalURL: "https://www.youtube.com/watch?v=OQ0OOzOwsJY",
        originalFilename: nil,
        chunks: [
            SourceChunkContext(
                sourceNodeId: sourceNode.id,
                ordinal: 0,
                text: "YouTube section: Leader role\nEvidence: \(evidenceLevel.label)\n00:18 Leaders create the initial shared worldview.",
                similarity: nil
            )
        ],
        evidenceLevel: evidenceLevel
    )

    return SourceLearningFixture(
        projectId: projectId,
        sourceNode: sourceNode,
        userMessage: userMessage,
        request: SourceLearningDigestRequest(
            conversationId: conversation.id,
            projectId: projectId,
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            sourceMaterials: [material]
        )
    )
}

private struct StaticSourceLearningLLM: LLMService {
    let output: String

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}
