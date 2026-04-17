import Foundation

/// Serialises memory-refresh work so it never overlaps the LLM reply stream.
///
/// Per v2.1 §5 scheduling decision (Q9=B): conversation refresh is enqueued
/// only AFTER the assistant message has been fully streamed and persisted,
/// and prior in-flight refreshes for the same node are superseded by the
/// newer `messages` array. Cancellation is properly serialised — the new
/// task awaits the prior task's `.value` before doing its own work, so two
/// LLM streams can never run concurrently for the same node (MLX has one
/// mouth, one ear; overlap = contention + clobbered conversation_memory).
///
/// Project refresh uses a persisted event counter (`project_refresh_state`).
/// Each successful conversation refresh increments the counter for its project
/// atomically via SQLite UPSERT; `refreshProject` resets it to 0. Fires once
/// the counter crosses `projectRefreshThreshold`. Living in SQLite means the
/// signal survives app quit, and counting EVENTS (not rows) means a single
/// heavy-churn chat refreshed N times correctly triggers rollup — the earlier
/// row-counting version confused `INSERT OR REPLACE` (one row per chat) with
/// events and stranded single-active-chat projects at COUNT=1 forever.
actor UserMemoryScheduler {

    static let projectRefreshThreshold = 3

    private let service: UserMemoryService
    private var inFlightByNode: [UUID: Task<Void, Never>] = [:]
    /// Per-node monotonic generation counter. Each enqueue bumps the gen; the
    /// task's cleanup only clears the slot if its gen is still the latest —
    /// otherwise a newer task has already replaced us.
    private var generationByNode: [UUID: Int] = [:]
    /// Codex #3: per-projectId lock. Two refreshProject calls for the same
    /// project must not run concurrently — they'd each read a snapshot of
    /// conversation_memory, feed it to the LLM independently, and the later
    /// writer clobbers the earlier one with a stale-at-write-time summary.
    /// This set guards the critical section; concurrent attempts skip cleanly.
    private var refreshingProjects: Set<UUID> = []

    init(service: UserMemoryService) {
        self.service = service
    }

    /// Enqueue a conversation refresh. If one is already in flight for the same
    /// `nodeId`, the new task cancels it and awaits its completion before
    /// starting, guaranteeing serialisation. If `projectId` is non-nil, checks
    /// the timestamp-derived project-refresh threshold after the conversation
    /// refresh completes and fires `refreshProject` when it is met.
    func enqueueConversationRefresh(
        nodeId: UUID,
        projectId: UUID?,
        messages: [Message]
    ) {
        let pending = inFlightByNode[nodeId]
        let generation = (generationByNode[nodeId] ?? 0) + 1
        generationByNode[nodeId] = generation
        let threshold = Self.projectRefreshThreshold

        let task = Task { [service, weak self] in
            // Serialise on the prior in-flight task so two LLM streams can't
            // overlap for the same node. `Task.cancel()` alone is non-blocking;
            // without awaiting `.value` the prior stream could still be mid-
            // write to conversation_memory while we start the new one.
            if let pending {
                pending.cancel()
                _ = await pending.value
            }

            // A yet-newer enqueue may have cancelled us while we awaited the
            // prior task. If so, skip the refresh — the newer task owns the
            // fresher `messages` snapshot and will do the work.
            if !Task.isCancelled {
                await service.refreshConversation(nodeId: nodeId, projectId: projectId, messages: messages)
                if let projectId,
                   service.shouldRefreshProject(projectId: projectId, threshold: threshold),
                   await self?.tryAcquireProjectLock(projectId: projectId) == true {
                    await service.refreshProject(projectId: projectId)
                    await self?.releaseProjectLock(projectId: projectId)
                }
            }

            // Finally-path cleanup: drop the slot so stale entries don't cause
            // spurious cancels on future enqueues. Guarded by generation so a
            // newer task that replaced us doesn't get accidentally cleared.
            await self?.taskDidComplete(nodeId: nodeId, generation: generation)
        }
        inFlightByNode[nodeId] = task
    }

    /// Cleanup handler called from the end of every scheduled task. Only
    /// clears the slot if no newer enqueue has replaced this task.
    private func taskDidComplete(nodeId: UUID, generation: Int) {
        guard generationByNode[nodeId] == generation else { return }
        inFlightByNode.removeValue(forKey: nodeId)
        generationByNode.removeValue(forKey: nodeId)
    }

    /// Codex #3: atomically try to acquire the refresh lock for a project.
    /// Returns true if the caller should run refreshProject; false if another
    /// task has it and the caller should bail out. Actor isolation makes the
    /// check-and-insert atomic — no explicit mutex needed. Internal (not
    /// private) so the unit test can exercise the mechanism directly without
    /// having to race the full enqueue path.
    func tryAcquireProjectLock(projectId: UUID) -> Bool {
        if refreshingProjects.contains(projectId) { return false }
        refreshingProjects.insert(projectId)
        return true
    }

    func releaseProjectLock(projectId: UUID) {
        refreshingProjects.remove(projectId)
    }

    /// Test hook: whether the project-refresh lock is held for this project.
    func isRefreshingProject(projectId: UUID) -> Bool {
        refreshingProjects.contains(projectId)
    }

    // MARK: - Test hooks

    /// Awaits every in-flight task. After this returns, no refresh work is
    /// outstanding for any node (each task's last action is to clear its own
    /// slot via `taskDidComplete`). Used by tests to avoid timing-dependent
    /// sleeps.
    func waitUntilIdle() async {
        while let task = inFlightByNode.values.first {
            _ = await task.value
        }
    }

    /// Whether a refresh is currently scheduled for this node.
    func isInFlight(nodeId: UUID) -> Bool {
        inFlightByNode[nodeId] != nil
    }
}
