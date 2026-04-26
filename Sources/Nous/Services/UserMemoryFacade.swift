import Foundation

/// Transitional facade over the split memory services.
///
/// Step 1 keeps the public `UserMemoryService` API stable while moving
/// ownership to projection / contradiction / synthesis collaborators.
final class UserMemoryService: MemorySynthesizing, @unchecked Sendable {

    typealias PersonalInferenceDisposition = UserMemoryCore.PersonalInferenceDisposition
    typealias AnnotatedContradictionFact = UserMemoryCore.AnnotatedContradictionFact

    static let globalBudget = UserMemoryCore.globalBudget
    static let essentialStoryBudget = UserMemoryCore.essentialStoryBudget
    static let projectBudget = UserMemoryCore.projectBudget
    static let conversationBudget = UserMemoryCore.conversationBudget
    static let evidenceSnippetBudget = UserMemoryCore.evidenceSnippetBudget
    static let userModelFacetLimit = UserMemoryCore.userModelFacetLimit
    static let contradictionFactKinds = UserMemoryCore.contradictionFactKinds

    private let core: UserMemoryCore
    private let projectionService: MemoryProjectionService
    private let contradictionService: ContradictionMemoryService
    private let synthesisService: MemorySynthesisService

    var synthesizer: any MemorySynthesizing {
        synthesisService
    }

    var projectionReader: MemoryProjectionService {
        projectionService
    }

    var contradictionReader: ContradictionMemoryService {
        contradictionService
    }

    init(
        nodeStore: NodeStore,
        llmServiceProvider: @escaping () -> (any LLMService)?,
        governanceTelemetry: GovernanceTelemetryStore? = nil
    ) {
        let core = UserMemoryCore(
            nodeStore: nodeStore,
            llmServiceProvider: llmServiceProvider,
            governanceTelemetry: governanceTelemetry
        )
        self.core = core
        self.projectionService = MemoryProjectionService(core: core)
        self.contradictionService = ContradictionMemoryService(core: core)
        self.synthesisService = MemorySynthesisService(core: core)
    }

    func currentGlobal() -> String? {
        projectionService.currentGlobal()
    }

    func currentProject(projectId: UUID) -> String? {
        projectionService.currentProject(projectId: projectId)
    }

    func currentConversation(nodeId: UUID) -> String? {
        projectionService.currentConversation(nodeId: nodeId)
    }

    func currentEssentialStory(
        projectId: UUID?,
        excludingConversationId: UUID? = nil
    ) -> String? {
        projectionService.currentEssentialStory(
            projectId: projectId,
            excludingConversationId: excludingConversationId
        )
    }

    func currentBoundedEvidence(
        projectId: UUID?,
        excludingConversationId: UUID? = nil,
        limit: Int = 2
    ) -> [MemoryEvidenceSnippet] {
        projectionService.currentBoundedEvidence(
            projectId: projectId,
            excludingConversationId: excludingConversationId,
            limit: limit
        )
    }

    func currentIdentityModel() -> [String] {
        projectionService.currentIdentityModel()
    }

    func currentGoalModel(projectId: UUID?, conversationId: UUID? = nil) -> [String] {
        projectionService.currentGoalModel(projectId: projectId, conversationId: conversationId)
    }

    func currentWorkStyleModel(projectId: UUID?, conversationId: UUID? = nil) -> [String] {
        projectionService.currentWorkStyleModel(projectId: projectId, conversationId: conversationId)
    }

    func currentMemoryBoundary(projectId: UUID?, conversationId: UUID? = nil) -> [String] {
        projectionService.currentMemoryBoundary(projectId: projectId, conversationId: conversationId)
    }

    func currentUserModel(projectId: UUID?, conversationId: UUID? = nil) -> UserModel? {
        projectionService.currentUserModel(projectId: projectId, conversationId: conversationId)
    }

    func shouldPersistMemory(messages: [Message], projectId: UUID?) -> Bool {
        projectionService.shouldPersistMemory(messages: messages, projectId: projectId)
    }

    func allMemoryEntries() -> [MemoryEntry] {
        core.allMemoryEntries()
    }

    func sourceSnippets(for entryId: UUID, limit: Int = 3) -> [MemoryEvidenceSnippet] {
        core.sourceSnippets(for: entryId, limit: limit)
    }

    @discardableResult
    func confirmMemoryEntry(id: UUID) -> Bool {
        core.confirmMemoryEntry(id: id)
    }

    @discardableResult
    func archiveMemoryEntry(id: UUID) -> Bool {
        core.archiveMemoryEntry(id: id)
    }

    @discardableResult
    func deleteMemoryEntry(id: UUID) -> Bool {
        core.deleteMemoryEntry(id: id)
    }

    func contradictionRecallFacts(projectId: UUID?, conversationId: UUID) throws -> [MemoryFactEntry] {
        try contradictionService.contradictionRecallFacts(projectId: projectId, conversationId: conversationId)
    }

    func annotateContradictionCandidates(
        currentMessage: String,
        facts: [MemoryFactEntry],
        maxCandidates: Int = 3
    ) -> [AnnotatedContradictionFact] {
        contradictionService.annotateContradictionCandidates(
            currentMessage: currentMessage,
            facts: facts,
            maxCandidates: maxCandidates
        )
    }

    func citableEntryPool(
        projectId: UUID?,
        conversationId: UUID,
        nodeHits: [UUID],
        hardRecallFacts: [MemoryFactEntry] = [],
        contradictionCandidateIds: Set<String> = [],
        capacity: Int = 15,
        recencySeedPerScope: Int = 3,
        reflectionSeed: Int = 2
    ) throws -> [CitableEntry] {
        try contradictionService.citableEntryPool(
            projectId: projectId,
            conversationId: conversationId,
            nodeHits: nodeHits,
            hardRecallFacts: hardRecallFacts,
            contradictionCandidateIds: contradictionCandidateIds,
            capacity: capacity,
            recencySeedPerScope: recencySeedPerScope,
            reflectionSeed: reflectionSeed
        )
    }

    func refreshConversation(nodeId: UUID, projectId: UUID?, messages: [Message]) async {
        await synthesisService.refreshConversation(nodeId: nodeId, projectId: projectId, messages: messages)
    }

    func refreshProject(projectId: UUID) async {
        await synthesisService.refreshProject(projectId: projectId)
    }

    func shouldRefreshProject(projectId: UUID, threshold: Int) -> Bool {
        synthesisService.shouldRefreshProject(projectId: projectId, threshold: threshold)
    }

    func promoteToGlobal(
        candidate: String,
        sourceNodeIds: [UUID] = [],
        confirmation: PersonalInferenceDisposition = .unconfirmed
    ) async -> Bool {
        await synthesisService.promoteToGlobal(
            candidate: candidate,
            sourceNodeIds: sourceNodeIds,
            confirmation: confirmation
        )
    }

    static func stripQuoteBlocks(_ content: String) -> String {
        UserMemoryCore.stripQuoteBlocks(content)
    }

    static func tokenJaccard(_ a: String, _ b: String) -> Double {
        UserMemoryCore.tokenJaccard(a, b)
    }

    static func extractSignatureMoments(from assistantMessages: [Message]) -> [String] {
        UserMemoryCore.extractSignatureMoments(from: assistantMessages)
    }
}
