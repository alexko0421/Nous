import Foundation

/// Serialises memory-refresh work so it never overlaps the LLM reply stream.
///
/// Per v2.1 §5 scheduling decision (Q9=B): conversation refresh is enqueued
/// only AFTER the assistant message has been fully streamed and persisted,
/// and a prior in-flight refresh for the same node is cancelled (debounce).
///
/// Project refresh fires on a counter cadence (§14.1): every Nth
/// conversation-refresh within a project triggers `refreshProject` for that
/// project. Counter is per-project, in-memory, and resets on app launch.
actor UserMemoryScheduler {

    static let projectRefreshEveryN = 3

    private let service: UserMemoryService
    private var inFlightByNode: [UUID: Task<Void, Never>] = [:]
    private var projectCounter: [UUID: Int] = [:]

    init(service: UserMemoryService) {
        self.service = service
    }

    /// Enqueue a conversation refresh. If one is already in flight for the same
    /// `nodeId`, it is cancelled — the newer `messages` array is authoritative.
    /// If `projectId` is non-nil, bumps the per-project counter and fires
    /// `refreshProject` when the counter hits the threshold.
    func enqueueConversationRefresh(
        nodeId: UUID,
        projectId: UUID?,
        messages: [Message]
    ) {
        inFlightByNode[nodeId]?.cancel()

        let task = Task { [service] in
            await service.refreshConversation(nodeId: nodeId, messages: messages)
        }
        inFlightByNode[nodeId] = task

        guard let projectId else { return }
        let next = (projectCounter[projectId] ?? 0) + 1
        if next >= Self.projectRefreshEveryN {
            projectCounter[projectId] = 0
            Task { [service] in
                await service.refreshProject(projectId: projectId)
            }
        } else {
            projectCounter[projectId] = next
        }
    }

    // Test hook: inspect counter state without triggering side effects.
    func currentProjectCounter(for projectId: UUID) -> Int {
        projectCounter[projectId] ?? 0
    }
}
