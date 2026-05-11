import Foundation

@MainActor
final class ContextContinuationService {
    private let scratchPadStore: ScratchPadStore
    private let userMemoryScheduler: UserMemoryScheduler
    private let governanceTelemetry: GovernanceTelemetryStore
    private let perConversationReflectionAutoTrigger: PerConversationReflectionAutoTrigger?

    init(
        scratchPadStore: ScratchPadStore,
        userMemoryScheduler: UserMemoryScheduler,
        governanceTelemetry: GovernanceTelemetryStore,
        perConversationReflectionAutoTrigger: PerConversationReflectionAutoTrigger? = nil
    ) {
        self.scratchPadStore = scratchPadStore
        self.userMemoryScheduler = userMemoryScheduler
        self.governanceTelemetry = governanceTelemetry
        self.perConversationReflectionAutoTrigger = perConversationReflectionAutoTrigger
    }

    func run(_ plan: ContextContinuationPlan) async {
        if let scratchpadIngest = plan.scratchpadIngest {
            scratchPadStore.ingestAssistantMessage(
                content: scratchpadIngest.content,
                sourceMessageId: scratchpadIngest.sourceMessageId,
                conversationId: scratchpadIngest.conversationId
            )
        }

        guard let memoryRefresh = plan.memoryRefresh else {
            governanceTelemetry.recordMemoryStorageSuppressed(
                reason: plan.memorySuppressionReason ?? .unspecified
            )
            return
        }

        Task { [userMemoryScheduler] in
            await userMemoryScheduler.enqueueConversationRefresh(
                nodeId: memoryRefresh.nodeId,
                projectId: memoryRefresh.projectId,
                messages: memoryRefresh.messages
            )
        }

        // Per-conversation reflection auto-fire (Block 8 lite Phase 2,
        // 2026-05-10). Cheap gating runs synchronously here; the LLM call
        // is detached inside the trigger so the chat UI never waits.
        perConversationReflectionAutoTrigger?.considerFire(
            nodeId: memoryRefresh.nodeId,
            projectId: memoryRefresh.projectId,
            messages: memoryRefresh.messages
        )
    }
}
