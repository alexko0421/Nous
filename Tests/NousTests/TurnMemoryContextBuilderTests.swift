import XCTest
@testable import Nous

final class TurnMemoryContextBuilderTests: XCTestCase {
    func testCitationExclusionIdsIncludeFreshSourceMaterials() {
        let currentNodeId = UUID()
        let sourceA = UUID()
        let sourceB = UUID()

        let exclusions = TurnMemoryContextBuilder.citationExclusionIds(
            currentNodeId: currentNodeId,
            sourceMaterials: [
                SourceMaterialContext(
                    sourceNodeId: sourceA,
                    title: "First source",
                    originalURL: "https://example.com/a",
                    originalFilename: nil,
                    chunks: []
                ),
                SourceMaterialContext(
                    sourceNodeId: sourceB,
                    title: "Second source",
                    originalURL: nil,
                    originalFilename: "second.pdf",
                    chunks: []
                )
            ]
        )

        XCTAssertEqual(exclusions, [currentNodeId, sourceA, sourceB])
    }

    func testBuilderOwnsMemoryAndProjectContextGatheringWithoutTurnPlanner() throws {
        let store = try NodeStore(path: ":memory:")
        let project = Project(
            title: "Memory cleanup",
            goal: "Finish the memory architecture cleanup"
        )
        try store.insertProject(project)

        let current = NousNode(
            type: .conversation,
            title: "Current chat",
            projectId: project.id
        )
        let recent = NousNode(
            type: .conversation,
            title: "Earlier chat",
            projectId: project.id,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        try store.insertNode(current)
        try store.insertNode(recent)
        try store.insertMemoryEntry(memoryEntry(scope: .global, content: "- Alex owns the data layer."))
        try store.insertMemoryEntry(memoryEntry(scope: .project, scopeRefId: project.id, content: "- Project memory lives here."))
        try store.insertMemoryEntry(memoryEntry(scope: .conversation, scopeRefId: current.id, content: "- Current chat thread."))
        try store.insertMemoryEntry(memoryEntry(scope: .conversation, scopeRefId: recent.id, content: "- Earlier chat memory."))
        let operatingContext = OperatingContext(
            identity: "Alex is building Nous.",
            currentWork: "Make memory trustworthy.",
            communicationStyle: "Be direct.",
            boundaries: "Ask before storing sensitive facts.",
            updatedAt: Date(timeIntervalSince1970: 1_500)
        )
        try store.saveOperatingContext(operatingContext, now: operatingContext.updatedAt)

        let core = UserMemoryCore(nodeStore: store, llmServiceProvider: { nil })
        let builder = TurnMemoryContextBuilder(
            nodeStore: store,
            vectorStore: VectorStore(nodeStore: store),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(nodeStore: store),
            contradictionMemoryService: ContradictionMemoryService(core: core)
        )

        let context = try builder.build(
            retrievalQuery: "memory architecture",
            promptQuery: "memory architecture",
            node: current,
            policy: .full,
            now: Date(timeIntervalSince1970: 3_000)
        )

        XCTAssertEqual(context.projectGoal, "Finish the memory architecture cleanup")
        XCTAssertEqual(context.operatingContext, operatingContext)
        XCTAssertEqual(context.globalMemory, "- Alex owns the data layer.")
        XCTAssertEqual(context.projectMemory, "- Project memory lives here.")
        XCTAssertEqual(context.conversationMemory, "- Current chat thread.")
        XCTAssertEqual(context.recentConversations.map(\.title), ["Earlier chat"])
        XCTAssertEqual(context.recentConversations.map(\.memory), ["- Earlier chat memory."])
        XCTAssertTrue(context.citations.isEmpty)
    }

    func testBuilderAttachesActiveMemoryProvenance() throws {
        let store = try NodeStore(path: ":memory:")
        let current = NousNode(type: .conversation, title: "Current chat")
        let source = NousNode(type: .conversation, title: "Source chat")
        try store.insertNode(current)
        try store.insertNode(source)
        let sourceMessage = Message(
            nodeId: source.id,
            role: .user,
            content: "Remember that memory provenance matters."
        )
        try store.insertMessage(sourceMessage)
        try store.insertMemoryEntry(MemoryEntry(
            scope: .global,
            kind: .boundary,
            stability: .stable,
            content: "- Memory provenance matters.",
            confidence: 0.92,
            sourceNodeIds: [source.id],
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        try store.insertMemoryAtom(MemoryAtom(
            type: .boundary,
            statement: "Memory provenance matters.",
            scope: .global,
            status: .active,
            confidence: 0.92,
            sourceNodeId: source.id,
            sourceMessageId: sourceMessage.id
        ))

        let core = UserMemoryCore(nodeStore: store, llmServiceProvider: { nil })
        let builder = TurnMemoryContextBuilder(
            nodeStore: store,
            vectorStore: VectorStore(nodeStore: store),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(nodeStore: store),
            contradictionMemoryService: ContradictionMemoryService(core: core)
        )

        let context = try builder.build(
            retrievalQuery: "provenance",
            promptQuery: "provenance",
            node: current,
            policy: .full,
            now: Date(timeIntervalSince1970: 2_000)
        )

        let provenance = try XCTUnwrap(context.memoryProvenance["global_memory"])
        XCTAssertEqual(provenance.scope, .global)
        XCTAssertEqual(provenance.statuses, [.active])
        XCTAssertEqual(provenance.confidence, 0.92)
        XCTAssertEqual(provenance.sourceNodeIds, [source.id])
        XCTAssertEqual(provenance.sourceMessageIds, [sourceMessage.id])
    }

    func testBuilderFiltersUnrelatedRecentConversationMemory() throws {
        let store = try NodeStore(path: ":memory:")
        let current = NousNode(
            type: .conversation,
            title: "Grammar question",
            content: "",
            updatedAt: Date(timeIntervalSince1970: 3_000)
        )
        let unrelated = NousNode(
            type: .conversation,
            title: "Shoes",
            content: "",
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        try store.insertNode(current)
        try store.insertNode(unrelated)
        try store.insertMemoryEntry(memoryEntry(
            scope: .conversation,
            scopeRefId: unrelated.id,
            content: "- Alex compared Cloudmonster sizing after class."
        ))

        let core = UserMemoryCore(nodeStore: store, llmServiceProvider: { nil })
        let builder = TurnMemoryContextBuilder(
            nodeStore: store,
            vectorStore: VectorStore(nodeStore: store),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(nodeStore: store),
            contradictionMemoryService: ContradictionMemoryService(core: core)
        )

        let context = try builder.build(
            retrievalQuery: "compound complex sentence",
            promptQuery: "explain compound and complex sentences",
            node: current,
            policy: .full,
            now: Date(timeIntervalSince1970: 4_000)
        )

        XCTAssertTrue(context.recentConversations.isEmpty)
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
