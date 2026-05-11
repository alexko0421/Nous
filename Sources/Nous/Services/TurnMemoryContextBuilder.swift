import Foundation

struct TurnMemoryContext {
    let citations: [SearchResult]
    let operatingContext: OperatingContext?
    let projectGoal: String?
    let recentConversations: [(title: String, memory: String)]
    let globalMemory: String?
    let essentialStory: String?
    let userModel: UserModel?
    let memoryEvidence: [MemoryEvidenceSnippet]
    let memoryGraphRecall: [String]
    let projectMemory: String?
    let conversationMemory: String?
    let hardRecallFacts: [MemoryFactEntry]
    let contradictionCandidateIds: Set<String>
    let citablePool: [CitableEntry]
    let memoryProvenance: [String: ContextManifestMemoryProvenance]
    /// Block 4a side-by-side: built every turn but NOT yet injected into the
    /// prompt. Available for tests and telemetry. Block 4a inject-half wires
    /// it into PromptContextAssembler; Block 4b makes cards primary.
    let corpusContext: CitableContext
    /// Block 4b Phase 1A — `corpusContext.entries` paired with their resolved
    /// source nodes (when `sourceNodeId` is non-nil and the node still exists).
    /// Reflection claims pass through with `node = nil`. Surfaced here so
    /// `TurnPlan` / `TurnPrepared` carry a UI-ready shape without leaking
    /// `NodeStore` access into view models.
    let resolvedCorpusEntries: [ResolvedCitableEntry]
}

final class TurnMemoryContextBuilder {
    private let nodeStore: NodeStore
    private let vectorStore: VectorStore
    private let embeddingService: EmbeddingService
    private let memoryProjectionService: MemoryProjectionService
    private let contradictionMemoryService: ContradictionMemoryService
    private let contextEvidenceSteward: ContextEvidenceSteward
    private let citableContextBuilder: CitableContextBuilder

    init(
        nodeStore: NodeStore,
        vectorStore: VectorStore,
        embeddingService: EmbeddingService,
        memoryProjectionService: MemoryProjectionService,
        contradictionMemoryService: ContradictionMemoryService,
        contextEvidenceSteward: ContextEvidenceSteward = ContextEvidenceSteward()
    ) {
        self.nodeStore = nodeStore
        self.vectorStore = vectorStore
        self.embeddingService = embeddingService
        self.memoryProjectionService = memoryProjectionService
        self.contradictionMemoryService = contradictionMemoryService
        self.contextEvidenceSteward = contextEvidenceSteward
        self.citableContextBuilder = CitableContextBuilder(
            nodeStore: nodeStore,
            lexicalIndex: nodeStore.lexicalIndex,
            feedbackStore: CitationFeedbackStore(nodeStore: nodeStore)
        )
    }

    func build(
        retrievalQuery: String,
        promptQuery: String,
        node: NousNode,
        policy: QuickActionMemoryPolicy,
        citationSourceMaterials: [SourceMaterialContext] = [],
        includeGraphPromptRecall: Bool = true,
        now: Date
    ) throws -> TurnMemoryContext {
        let excludedCitationIds = Self.citationExclusionIds(
            currentNodeId: node.id,
            sourceMaterials: citationSourceMaterials
        )
        let citations = policy.includeCitations
            ? try retrieveCitations(retrievalQuery: retrievalQuery, excludingIds: excludedCitationIds)
            : []
        let operatingContext = try? nodeStore.fetchOperatingContext()
        let projectGoal = policy.includeProjectGoal
            ? try projectGoal(for: node.projectId)
            : nil
        let recentConversations: [(title: String, memory: String)] = policy.includeRecentConversations
            ? try nodeStore.fetchRecentConversationMemories(limit: 2, excludingId: node.id)
            : []

        let globalMemory = policy.includeGlobalMemory
            ? memoryProjectionService.currentGlobal()
            : nil
        let essentialStory = policy.includeEssentialStory
            ? memoryProjectionService.currentEssentialStory(
                projectId: node.projectId,
                excludingConversationId: node.id
            )
            : nil
        let userModel = policy.includeUserModel
            ? memoryProjectionService.currentUserModel(
                projectId: node.projectId,
                conversationId: node.id
            )
            : nil
        let memoryEvidence: [MemoryEvidenceSnippet] = policy.includeMemoryEvidence
            ? memoryProjectionService.currentBoundedEvidence(
                projectId: node.projectId,
                excludingConversationId: node.id
            )
            : []
        let filteredRecentConversations = contextEvidenceSteward
            .filterRecentConversations(recentConversations, promptQuery: promptQuery)
            .kept
        let filteredMemoryEvidence = contextEvidenceSteward
            .filterMemoryEvidence(memoryEvidence, promptQuery: promptQuery)
            .kept
        let queryEmbedding: [Float]? = {
            guard embeddingService.isLoaded else { return nil }
            return try? embeddingService.embed(promptQuery)
        }()
        let memoryGraphRecall: [String] = memoryProjectionService.currentGraphMemoryRecall(
            currentMessage: promptQuery,
            projectId: node.projectId,
            conversationId: node.id,
            queryEmbedding: queryEmbedding,
            now: now
        )
        let projectMemory = policy.includeProjectMemory
            ? node.projectId.flatMap {
                memoryProjectionService.currentProject(projectId: $0)
            }
            : nil
        let conversationMemory = policy.includeConversationMemory
            ? memoryProjectionService.currentConversation(nodeId: node.id)
            : nil
        let nodeHits = citations.map { $0.node.id }
        let hardRecallFacts: [MemoryFactEntry] = policy.includeContradictionRecall
            ? try contradictionMemoryService.contradictionRecallFacts(
                projectId: node.projectId,
                conversationId: node.id
            )
            : []
        let contradictionCandidateIds: Set<String> = policy.includeContradictionRecall
            ? Set(
                contradictionMemoryService
                    .annotateContradictionCandidates(
                        currentMessage: promptQuery,
                        facts: hardRecallFacts
                    )
                    .filter(\.isContradictionCandidate)
                    .map { $0.fact.id.uuidString }
            )
            : []
        let citablePool: [CitableEntry] = (policy.includeContradictionRecall || policy.includeJudgeFocus)
            ? try contradictionMemoryService.citableEntryPool(
                projectId: node.projectId,
                conversationId: node.id,
                nodeHits: nodeHits,
                hardRecallFacts: hardRecallFacts,
                contradictionCandidateIds: contradictionCandidateIds
            )
            : []
        let memoryProvenance = memoryProvenanceMap(
            policy: policy,
            projectId: node.projectId,
            conversationId: node.id,
            memoryEvidence: filteredMemoryEvidence,
            memoryGraphRecall: memoryGraphRecall,
            citablePool: citablePool
        )

        // Block 4a side-by-side: build the corpus context every turn so it's
        // observable in tests + telemetry. Inject-half (next commit) wires it
        // into PromptContextAssembler; for now this is dark code in the prompt.
        let corpusContext = citableContextBuilder.build(
            turnText: promptQuery,
            conversationId: node.id,
            projectId: node.projectId,
            queryEmbedding: queryEmbedding,
            now: now
        )

        let resolvedCorpusEntries = Self.resolveCorpusEntries(
            corpusContext.entries,
            nodeStore: nodeStore
        )

        return TurnMemoryContext(
            citations: citations,
            operatingContext: operatingContext,
            projectGoal: projectGoal,
            recentConversations: filteredRecentConversations,
            globalMemory: globalMemory,
            essentialStory: essentialStory,
            userModel: userModel,
            memoryEvidence: filteredMemoryEvidence,
            memoryGraphRecall: memoryGraphRecall,
            projectMemory: projectMemory,
            conversationMemory: conversationMemory,
            hardRecallFacts: hardRecallFacts,
            contradictionCandidateIds: contradictionCandidateIds,
            citablePool: citablePool,
            memoryProvenance: memoryProvenance,
            corpusContext: corpusContext,
            resolvedCorpusEntries: resolvedCorpusEntries
        )
    }

    /// Resolve each `CitableEntry` against the node store. Reflection claims
    /// (`sourceNodeId == nil`) and stale ids (node deleted since the atom was
    /// recorded) pass through with `node = nil`. Single batched dictionary
    /// lookup keeps DB access at one query per turn even at the `cardCap=8`
    /// ceiling. Errors from `fetchNode` are swallowed individually so a single
    /// stale id never breaks the whole resolution.
    static func resolveCorpusEntries(
        _ entries: [CitableEntry],
        nodeStore: NodeStore
    ) -> [ResolvedCitableEntry] {
        let uniqueIds: [UUID] = {
            var seen = Set<UUID>()
            return entries.compactMap(\.sourceNodeId).filter { seen.insert($0).inserted }
        }()
        var lookup: [UUID: NousNode] = [:]
        for id in uniqueIds {
            if let node = try? nodeStore.fetchNode(id: id) {
                lookup[id] = node
            }
        }
        return entries.map { entry in
            ResolvedCitableEntry(
                entry: entry,
                node: entry.sourceNodeId.flatMap { lookup[$0] }
            )
        }
    }

    static func citationExclusionIds(
        currentNodeId: UUID,
        sourceMaterials: [SourceMaterialContext]
    ) -> Set<UUID> {
        Set([currentNodeId] + sourceMaterials.map(\.sourceNodeId))
    }

    private func retrieveCitations(retrievalQuery: String, excludingIds: Set<UUID>) throws -> [SearchResult] {
        guard embeddingService.isLoaded else { return [] }
        do {
            let queryEmbedding = try embeddingService.embed(retrievalQuery)
            return try vectorStore.searchForChatCitations(
                query: queryEmbedding,
                queryText: retrievalQuery,
                topK: 5,
                excludeIds: excludingIds
            )
        } catch {
            throw TurnPlanningError(message: "Failed to build retrieval context: \(error.localizedDescription)")
        }
    }

    private func projectGoal(for projectId: UUID?) throws -> String? {
        guard let projectId else { return nil }
        do {
            guard let project = try nodeStore.fetchProject(id: projectId) else { return nil }
            let trimmedGoal = project.goal.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedGoal.isEmpty ? nil : trimmedGoal
        } catch {
            throw TurnPlanningError(message: "Failed to load project context: \(error.localizedDescription)")
        }
    }

    private func memoryProvenanceMap(
        policy: QuickActionMemoryPolicy,
        projectId: UUID?,
        conversationId: UUID,
        memoryEvidence: [MemoryEvidenceSnippet],
        memoryGraphRecall: [String],
        citablePool: [CitableEntry]
    ) -> [String: ContextManifestMemoryProvenance] {
        var provenance: [String: ContextManifestMemoryProvenance] = [:]

        if policy.includeGlobalMemory,
           let global = activeMemoryProvenance(scope: .global, scopeRefId: nil) {
            provenance["global_memory"] = global
        }
        if policy.includeProjectMemory,
           let projectId,
           let project = activeMemoryProvenance(scope: .project, scopeRefId: projectId) {
            provenance["project_memory"] = project
        }
        if policy.includeConversationMemory,
           let conversation = activeMemoryProvenance(scope: .conversation, scopeRefId: conversationId) {
            provenance["conversation_memory"] = conversation
        }

        for evidence in memoryEvidence {
            if let source = evidenceProvenance(sourceNodeId: evidence.sourceNodeId) {
                provenance[evidence.sourceNodeId.uuidString] = source
            }
        }

        if policy.includeContradictionRecall,
           let graphRecall = graphRecallProvenance(memoryGraphRecall) {
            provenance["memory_graph_recall"] = graphRecall
        }

        for citable in citablePool {
            guard provenance[citable.id] == nil,
                  let citableProvenance = citableProvenance(citable) else {
                continue
            }
            provenance[citable.id] = citableProvenance
        }

        return provenance
    }

    private func activeMemoryProvenance(
        scope: MemoryScope,
        scopeRefId: UUID?
    ) -> ContextManifestMemoryProvenance? {
        guard let entry = try? nodeStore.fetchActiveMemoryEntry(scope: scope, scopeRefId: scopeRefId) else {
            return nil
        }
        return provenance(from: entry)
    }

    private func evidenceProvenance(sourceNodeId: UUID) -> ContextManifestMemoryProvenance? {
        let entries = ((try? nodeStore.fetchMemoryEntries(withSourceNodeId: sourceNodeId, activeOnly: false)) ?? [])
            .filter { $0.status == .active || $0.status == .superseded }
            .sorted { lhs, rhs in
                if lhs.status == rhs.status {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.status == .active
            }
        guard let first = entries.first else {
            return ContextManifestMemoryProvenance(
                scope: nil,
                statuses: [],
                confidence: nil,
                sourceNodeIds: [sourceNodeId],
                sourceMessageIds: sourceMessageIds(sourceNodeIds: [sourceNodeId])
            )
        }

        let sourceNodeIds = Self.uniqueUUIDs([sourceNodeId] + first.sourceNodeIds)
        return ContextManifestMemoryProvenance(
            scope: first.scope,
            statuses: Self.uniqueStatuses(entries.map(\.status)),
            confidence: entries.map(\.confidence).max(),
            sourceNodeIds: sourceNodeIds,
            sourceMessageIds: sourceMessageIds(sourceNodeIds: sourceNodeIds)
        )
    }

    private func graphRecallProvenance(_ recall: [String]) -> ContextManifestMemoryProvenance? {
        let atomIds = Self.atomIds(in: recall)
        guard !atomIds.isEmpty else { return nil }
        let atoms = atomIds.compactMap { try? nodeStore.fetchMemoryAtom(id: $0) }
        guard !atoms.isEmpty else { return nil }
        let scope = Set(atoms.map(\.scope.rawValue)).count == 1 ? atoms.first?.scope : nil
        return ContextManifestMemoryProvenance(
            scope: scope,
            statuses: Self.uniqueStatuses(atoms.map(\.status)),
            confidence: atoms.map(\.confidence).max(),
            sourceNodeIds: Self.uniqueUUIDs(atoms.compactMap(\.sourceNodeId)),
            sourceMessageIds: Self.uniqueUUIDs(atoms.compactMap(\.sourceMessageId))
        )
    }

    private func citableProvenance(_ citable: CitableEntry) -> ContextManifestMemoryProvenance? {
        guard let id = UUID(uuidString: citable.id) else { return nil }
        if let entry = try? nodeStore.fetchMemoryEntry(id: id) {
            return provenance(from: entry)
        }
        if let fact = try? nodeStore.fetchMemoryFactEntry(id: id) {
            return provenance(from: fact)
        }
        if citable.scope == .selfReflection {
            let evidence = (try? nodeStore.fetchReflectionEvidence(reflectionIds: [id])) ?? []
            return ContextManifestMemoryProvenance(
                scope: .selfReflection,
                statuses: [.active],
                confidence: nil,
                sourceNodeIds: [],
                sourceMessageIds: Self.uniqueUUIDs(evidence.map(\.messageId))
            )
        }
        return nil
    }

    private func provenance(from entry: MemoryEntry) -> ContextManifestMemoryProvenance {
        let sourceNodeIds = Self.uniqueUUIDs(entry.sourceNodeIds)
        return ContextManifestMemoryProvenance(
            scope: entry.scope,
            statuses: [entry.status],
            confidence: entry.confidence,
            sourceNodeIds: sourceNodeIds,
            sourceMessageIds: sourceMessageIds(sourceNodeIds: sourceNodeIds)
        )
    }

    private func provenance(from fact: MemoryFactEntry) -> ContextManifestMemoryProvenance {
        let sourceNodeIds = Self.uniqueUUIDs(fact.sourceNodeIds)
        return ContextManifestMemoryProvenance(
            scope: fact.scope,
            statuses: [fact.status],
            confidence: fact.confidence,
            sourceNodeIds: sourceNodeIds,
            sourceMessageIds: sourceMessageIds(sourceNodeIds: sourceNodeIds)
        )
    }

    private func sourceMessageIds(sourceNodeIds: [UUID]) -> [UUID] {
        guard !sourceNodeIds.isEmpty,
              let atoms = try? nodeStore.fetchMemoryAtoms(sourceNodeIds: sourceNodeIds)
        else {
            return []
        }
        return Self.uniqueUUIDs(atoms.compactMap(\.sourceMessageId))
    }

    private static func atomIds(in recall: [String]) -> [UUID] {
        var ids: [UUID] = []
        var seen = Set<String>()
        for token in recall.joined(separator: " ").split(whereSeparator: \.isWhitespace) {
            guard token.hasPrefix("atom_id=") else { continue }
            let raw = token.dropFirst("atom_id=".count)
            guard let id = UUID(uuidString: String(raw)),
                  seen.insert(id.uuidString).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

    private static func uniqueUUIDs(_ ids: [UUID]) -> [UUID] {
        var seen = Set<String>()
        return ids
            .filter { seen.insert($0.uuidString).inserted }
            .sorted { $0.uuidString < $1.uuidString }
    }

    private static func uniqueStatuses(_ statuses: [MemoryStatus]) -> [MemoryStatus] {
        var seen = Set<String>()
        return statuses.filter { seen.insert($0.rawValue).inserted }
    }
}
