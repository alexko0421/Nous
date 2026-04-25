import Foundation

@MainActor
final class ContextContinuationService {
    private let scratchPadStore: ScratchPadStore
    private let userMemoryScheduler: UserMemoryScheduler
    private let governanceTelemetry: GovernanceTelemetryStore

    init(
        scratchPadStore: ScratchPadStore,
        userMemoryScheduler: UserMemoryScheduler,
        governanceTelemetry: GovernanceTelemetryStore
    ) {
        self.scratchPadStore = scratchPadStore
        self.userMemoryScheduler = userMemoryScheduler
        self.governanceTelemetry = governanceTelemetry
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
            governanceTelemetry.recordMemoryStorageSuppressed()
            return
        }

        Task { [userMemoryScheduler] in
            await userMemoryScheduler.enqueueConversationRefresh(
                nodeId: memoryRefresh.nodeId,
                projectId: memoryRefresh.projectId,
                messages: memoryRefresh.messages
            )
        }
    }
}
