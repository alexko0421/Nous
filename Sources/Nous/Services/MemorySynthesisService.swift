import Foundation

protocol MemorySynthesizing: Sendable {
    func refreshConversation(nodeId: UUID, projectId: UUID?, messages: [Message]) async
    func refreshProject(projectId: UUID) async
    func shouldRefreshProject(projectId: UUID, threshold: Int) -> Bool
    func promoteToGlobal(
        candidate: String,
        sourceNodeIds: [UUID],
        confirmation: UserMemoryCore.PersonalInferenceDisposition
    ) async -> Bool
}

final class MemorySynthesisService: MemorySynthesizing, @unchecked Sendable {
    private let core: UserMemoryCore

    init(core: UserMemoryCore) {
        self.core = core
    }

    func refreshConversation(nodeId: UUID, projectId: UUID?, messages: [Message]) async {
        await core.refreshConversation(nodeId: nodeId, projectId: projectId, messages: messages)
    }

    func refreshProject(projectId: UUID) async {
        await core.refreshProject(projectId: projectId)
    }

    func shouldRefreshProject(projectId: UUID, threshold: Int) -> Bool {
        core.shouldRefreshProject(projectId: projectId, threshold: threshold)
    }

    func promoteToGlobal(
        candidate: String,
        sourceNodeIds: [UUID],
        confirmation: UserMemoryCore.PersonalInferenceDisposition
    ) async -> Bool {
        await core.promoteToGlobal(
            candidate: candidate,
            sourceNodeIds: sourceNodeIds,
            confirmation: confirmation
        )
    }
}
