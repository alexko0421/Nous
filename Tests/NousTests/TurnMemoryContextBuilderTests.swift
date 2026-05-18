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

    func testBuilderPersistsCurrentConversationTopicContextTrace() throws {
        let store = try NodeStore(path: ":memory:")
        let current = NousNode(type: .conversation, title: "Current chat")
        try store.insertNode(current)

        let core = UserMemoryCore(nodeStore: store, llmServiceProvider: { nil })
        let builder = TurnMemoryContextBuilder(
            nodeStore: store,
            vectorStore: VectorStore(nodeStore: store),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(nodeStore: store),
            contradictionMemoryService: ContradictionMemoryService(core: core)
        )

        let context = try builder.build(
            retrievalQuery: "SMC F-1 visa school plan",
            promptQuery: "SMC F-1 visa school plan",
            node: current,
            policy: .full,
            now: Date(timeIntervalSince1970: 5_000)
        )

        XCTAssertEqual(context.topicContext?.primaryLane, .education)
        XCTAssertEqual(context.topicContext?.matchedAssignmentCount, 1)

        let assignment = try XCTUnwrap(store.fetchTopicContextAssignment(
            targetType: .conversation,
            targetId: current.id
        ))
        XCTAssertEqual(assignment.primaryLane, .education)
        XCTAssertEqual(assignment.source, .deterministic)
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

    func testBuilderAttachesCitableFactProvenanceForJudgeFocus() throws {
        let store = try NodeStore(path: ":memory:")
        let current = NousNode(type: .conversation, title: "Current chat")
        let source = NousNode(type: .conversation, title: "Source chat")
        try store.insertNode(current)
        try store.insertNode(source)
        let sourceMessage = Message(
            nodeId: source.id,
            role: .user,
            content: "Remember that memory provenance must include judge focus facts."
        )
        try store.insertMessage(sourceMessage)
        let fact = MemoryFactEntry(
            scope: .global,
            kind: .boundary,
            content: "Memory provenance must include judge focus facts.",
            confidence: 0.88,
            status: .active,
            stability: .stable,
            sourceNodeIds: [source.id],
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        try store.insertMemoryFactEntry(fact)
        try store.insertMemoryAtom(MemoryAtom(
            type: .boundary,
            statement: fact.content,
            scope: .global,
            status: .active,
            confidence: 0.88,
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
            retrievalQuery: "judge focus",
            promptQuery: "judge focus",
            node: current,
            policy: .full,
            now: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertTrue(context.citablePool.contains { $0.id == fact.id.uuidString })
        let provenance = try XCTUnwrap(context.memoryProvenance[fact.id.uuidString])
        XCTAssertEqual(provenance.scope, .global)
        XCTAssertEqual(provenance.statuses, [.active])
        XCTAssertEqual(provenance.confidence, 0.88)
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

    /// Block 4a build-half: TurnMemoryContext now carries a corpusContext
    /// that the builder populates each turn from the same NodeStore. Inject-
    /// half (next commit) wires it into PromptContextAssembler. Until then,
    /// this test guards that the side-by-side build path remains green.
    func testBuilderPopulatesCorpusContextSideBySide() throws {
        let store = try NodeStore(path: ":memory:")
        let current = NousNode(type: .conversation, title: "Decision discussion")
        let source = NousNode(type: .conversation, title: "Earlier decision")
        try store.insertNode(current)
        try store.insertNode(source)
        try store.insertMemoryAtom(MemoryAtom(
            type: .decision,
            statement: "Ship the notch preview before TTS, citing momentum over polish.",
            scope: .global,
            confidence: 0.85,
            sourceNodeId: source.id
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
            retrievalQuery: "remember the decision we made before",
            promptQuery: "remember the decision we made before",
            node: current,
            policy: .full,
            now: Date(timeIntervalSince1970: 5_000)
        )

        XCTAssertFalse(context.corpusContext.entries.isEmpty,
                       "decisionHistory query should surface at least one atom card")
        let admitted = try XCTUnwrap(context.corpusContext.entries.first)
        XCTAssertEqual(admitted.atomType, .decision)
        XCTAssertEqual(admitted.confidence, 0.85)
        XCTAssertEqual(admitted.sourceNodeId, source.id)
        XCTAssertEqual(context.corpusContext.manifest.intent, .decisionHistory)
        XCTAssertGreaterThan(context.corpusContext.manifest.admittedCount, 0)
    }

    func testCorpusContextEmptyOnEmptyStore() throws {
        let store = try NodeStore(path: ":memory:")
        let current = NousNode(type: .conversation, title: "fresh chat")
        try store.insertNode(current)

        let core = UserMemoryCore(nodeStore: store, llmServiceProvider: { nil })
        let builder = TurnMemoryContextBuilder(
            nodeStore: store,
            vectorStore: VectorStore(nodeStore: store),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(nodeStore: store),
            contradictionMemoryService: ContradictionMemoryService(core: core)
        )

        let context = try builder.build(
            retrievalQuery: "anything",
            promptQuery: "anything",
            node: current,
            policy: .full,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertTrue(context.corpusContext.entries.isEmpty)
        XCTAssertEqual(context.corpusContext.manifest.totalCandidates, 0)
        XCTAssertTrue(context.resolvedCorpusEntries.isEmpty)
    }

    // MARK: - resolveCorpusEntries (Block 4b Phase 1A)

    func testResolveCorpusEntriesPairsAtomWithExistingNode() throws {
        let store = try NodeStore(path: ":memory:")
        let source = NousNode(type: .conversation, title: "Earlier chat")
        try store.insertNode(source)

        let entry = CitableEntry(
            id: UUID().uuidString,
            text: "Networking events feel like a stage to me.",
            scope: .global,
            promptAnnotation: "atom-recall",
            confidence: 0.82,
            sourceNodeId: source.id,
            atomType: .insight,
            recordedAt: Date(timeIntervalSince1970: 1_000)
        )

        let resolved = TurnMemoryContextBuilder.resolveCorpusEntries(
            [entry],
            nodeStore: store
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].entry.id, entry.id)
        XCTAssertEqual(resolved[0].node?.id, source.id)
        XCTAssertEqual(resolved[0].node?.title, "Earlier chat")
    }

    func testResolveCorpusEntriesPassesThroughStaleSourceNodeIdsAsNilNode() throws {
        let store = try NodeStore(path: ":memory:")
        let staleId = UUID()

        let entry = CitableEntry(
            id: UUID().uuidString,
            text: "An atom whose source has since been deleted.",
            scope: .global,
            promptAnnotation: "atom-recall",
            confidence: 0.75,
            sourceNodeId: staleId,
            atomType: .preference
        )

        let resolved = TurnMemoryContextBuilder.resolveCorpusEntries(
            [entry],
            nodeStore: store
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertNil(resolved[0].node, "Stale sourceNodeId should resolve to node=nil")
        XCTAssertEqual(resolved[0].entry.id, entry.id)
    }

    func testResolveCorpusEntriesPassesThroughReflectionsWithNilNode() throws {
        let store = try NodeStore(path: ":memory:")

        let reflection = CitableEntry(
            id: UUID().uuidString,
            text: "You return to the same fear of being seen as performative.",
            scope: .selfReflection,
            promptAnnotation: "weekly-reflection",
            confidence: 0.9,
            sourceNodeId: nil,
            atomType: nil,
            recordedAt: Date(timeIntervalSince1970: 2_000)
        )

        let resolved = TurnMemoryContextBuilder.resolveCorpusEntries(
            [reflection],
            nodeStore: store
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertNil(resolved[0].node)
        XCTAssertEqual(resolved[0].entry.scope, .selfReflection)
    }

    func testResolveCorpusEntriesDedupesNodeFetchesAcrossMultipleAtoms() throws {
        let store = try NodeStore(path: ":memory:")
        let source = NousNode(type: .conversation, title: "Shared source")
        try store.insertNode(source)

        let entryA = CitableEntry(
            id: UUID().uuidString,
            text: "First atom from shared source.",
            scope: .global,
            promptAnnotation: "atom-recall",
            confidence: 0.8,
            sourceNodeId: source.id,
            atomType: .decision
        )
        let entryB = CitableEntry(
            id: UUID().uuidString,
            text: "Second atom from same shared source.",
            scope: .global,
            promptAnnotation: "atom-recall",
            confidence: 0.7,
            sourceNodeId: source.id,
            atomType: .insight
        )

        let resolved = TurnMemoryContextBuilder.resolveCorpusEntries(
            [entryA, entryB],
            nodeStore: store
        )

        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].node?.id, source.id)
        XCTAssertEqual(resolved[1].node?.id, source.id)
    }

    func testResolveCorpusEntriesPreservesEntryOrder() throws {
        let store = try NodeStore(path: ":memory:")
        let source = NousNode(type: .conversation, title: "Source")
        try store.insertNode(source)

        let entries: [CitableEntry] = (0..<3).map { idx in
            CitableEntry(
                id: "atom-\(idx)",
                text: "atom \(idx)",
                scope: .global,
                promptAnnotation: "atom-recall",
                confidence: 0.8,
                sourceNodeId: source.id,
                atomType: .insight
            )
        }

        let resolved = TurnMemoryContextBuilder.resolveCorpusEntries(
            entries,
            nodeStore: store
        )

        XCTAssertEqual(resolved.map(\.entry.id), ["atom-0", "atom-1", "atom-2"])
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
