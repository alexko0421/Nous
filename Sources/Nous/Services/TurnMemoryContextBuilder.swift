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
}

final class TurnMemoryContextBuilder {
    private let nodeStore: NodeStore
    private let vectorStore: VectorStore
    private let embeddingService: EmbeddingService
    private let memoryProjectionService: MemoryProjectionService
    private let contradictionMemoryService: ContradictionMemoryService
    private let contextEvidenceSteward: ContextEvidenceSteward

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
    }

    func build(
        retrievalQuery: String,
        promptQuery: String,
        node: NousNode,
        policy: QuickActionMemoryPolicy,
        includeGraphPromptRecall: Bool = true,
        now: Date
    ) throws -> TurnMemoryContext {
        let citations = policy.includeCitations
            ? try retrieveCitations(retrievalQuery: retrievalQuery, excludingId: node.id)
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
            guard policy.includeContradictionRecall,
                  includeGraphPromptRecall,
                  embeddingService.isLoaded
            else { return nil }
            return try? embeddingService.embed(promptQuery)
        }()
        let memoryGraphRecall: [String] = policy.includeContradictionRecall && includeGraphPromptRecall
            ? memoryProjectionService.currentGraphMemoryRecall(
                currentMessage: promptQuery,
                projectId: node.projectId,
                conversationId: node.id,
                queryEmbedding: queryEmbedding,
                now: now
            )
            : []
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
            citablePool: citablePool
        )
    }

    private func retrieveCitations(retrievalQuery: String, excludingId: UUID) throws -> [SearchResult] {
        guard embeddingService.isLoaded else { return [] }
        do {
            let queryEmbedding = try embeddingService.embed(retrievalQuery)
            return try vectorStore.searchForChatCitations(
                query: queryEmbedding,
                queryText: retrievalQuery,
                topK: 5,
                excludeIds: [excludingId]
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
}
