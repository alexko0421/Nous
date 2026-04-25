import Foundation

final class ContradictionMemoryService {
    private let core: UserMemoryCore

    init(core: UserMemoryCore) {
        self.core = core
    }

    func contradictionRecallFacts(projectId: UUID?, conversationId: UUID) throws -> [MemoryFactEntry] {
        try core.contradictionRecallFacts(projectId: projectId, conversationId: conversationId)
    }

    func annotateContradictionCandidates(
        currentMessage: String,
        facts: [MemoryFactEntry],
        maxCandidates: Int = 3
    ) -> [UserMemoryCore.AnnotatedContradictionFact] {
        core.annotateContradictionCandidates(
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
        try core.citableEntryPool(
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
}
