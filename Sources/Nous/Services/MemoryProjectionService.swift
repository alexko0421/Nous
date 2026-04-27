import Foundation

final class MemoryProjectionService {
    private let core: UserMemoryCore

    init(core: UserMemoryCore) {
        self.core = core
    }

    func currentGlobal() -> String? {
        core.currentGlobal()
    }

    func currentProject(projectId: UUID) -> String? {
        core.currentProject(projectId: projectId)
    }

    func currentConversation(nodeId: UUID) -> String? {
        core.currentConversation(nodeId: nodeId)
    }

    func currentEssentialStory(
        projectId: UUID?,
        excludingConversationId: UUID? = nil
    ) -> String? {
        core.currentEssentialStory(
            projectId: projectId,
            excludingConversationId: excludingConversationId
        )
    }

    func currentBoundedEvidence(
        projectId: UUID?,
        excludingConversationId: UUID? = nil,
        limit: Int = 2
    ) -> [MemoryEvidenceSnippet] {
        core.currentBoundedEvidence(
            projectId: projectId,
            excludingConversationId: excludingConversationId,
            limit: limit
        )
    }

    func currentIdentityModel() -> [String] {
        core.currentIdentityModel()
    }

    func currentGoalModel(projectId: UUID?, conversationId: UUID? = nil) -> [String] {
        core.currentGoalModel(projectId: projectId, conversationId: conversationId)
    }

    func currentWorkStyleModel(projectId: UUID?, conversationId: UUID? = nil) -> [String] {
        core.currentWorkStyleModel(projectId: projectId, conversationId: conversationId)
    }

    func currentMemoryBoundary(projectId: UUID?, conversationId: UUID? = nil) -> [String] {
        core.currentMemoryBoundary(projectId: projectId, conversationId: conversationId)
    }

    func currentUserModel(projectId: UUID?, conversationId: UUID? = nil) -> UserModel? {
        core.currentUserModel(projectId: projectId, conversationId: conversationId)
    }

    func currentDecisionGraphRecall(
        currentMessage: String,
        projectId: UUID?,
        conversationId: UUID,
        limit: Int = 3,
        now: Date = Date()
    ) -> [String] {
        core.currentDecisionGraphRecall(
            currentMessage: currentMessage,
            projectId: projectId,
            conversationId: conversationId,
            limit: limit,
            now: now
        )
    }

    func currentGraphMemoryRecall(
        currentMessage: String,
        projectId: UUID?,
        conversationId: UUID,
        limit: Int = 4,
        queryEmbedding: [Float]? = nil,
        now: Date = Date()
    ) -> [String] {
        core.currentGraphMemoryRecall(
            currentMessage: currentMessage,
            projectId: projectId,
            conversationId: conversationId,
            limit: limit,
            queryEmbedding: queryEmbedding,
            now: now
        )
    }

    func shouldPersistMemory(messages: [Message], projectId: UUID?) -> Bool {
        core.shouldPersistMemory(messages: messages, projectId: projectId)
    }
}
