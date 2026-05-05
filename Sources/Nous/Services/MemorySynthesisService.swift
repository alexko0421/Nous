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
    func absorbTemporaryBranchSummary(record: TemporaryBranchRecord) async
    func applyTemporaryBranchCandidate(
        _ candidate: TemporaryBranchMemoryCandidate,
        record: TemporaryBranchRecord
    ) async -> Bool
}

extension MemorySynthesizing {
    func absorbTemporaryBranchSummary(record: TemporaryBranchRecord) async {}

    func applyTemporaryBranchCandidate(
        _ candidate: TemporaryBranchMemoryCandidate,
        record: TemporaryBranchRecord
    ) async -> Bool {
        false
    }
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

    func absorbTemporaryBranchSummary(record: TemporaryBranchRecord) async {
        core.absorbTemporaryBranchSummary(record: record)
    }

    func applyTemporaryBranchCandidate(
        _ candidate: TemporaryBranchMemoryCandidate,
        record: TemporaryBranchRecord
    ) async -> Bool {
        core.applyTemporaryBranchCandidate(candidate, record: record)
    }
}
