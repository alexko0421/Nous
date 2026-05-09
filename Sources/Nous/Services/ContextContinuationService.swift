import Foundation

@MainActor
final class ContextContinuationService {
    private let scratchPadStore: ScratchPadStore
    private let userMemoryScheduler: UserMemoryScheduler
    private let governanceTelemetry: GovernanceTelemetryStore
    private let sourceLearningScheduler: SourceLearningMemoryScheduler?

    init(
        scratchPadStore: ScratchPadStore,
        userMemoryScheduler: UserMemoryScheduler,
        governanceTelemetry: GovernanceTelemetryStore,
        sourceLearningScheduler: SourceLearningMemoryScheduler? = nil
    ) {
        self.scratchPadStore = scratchPadStore
        self.userMemoryScheduler = userMemoryScheduler
        self.governanceTelemetry = governanceTelemetry
        self.sourceLearningScheduler = sourceLearningScheduler
    }

    func run(_ plan: ContextContinuationPlan) async {
        if let scratchpadIngest = plan.scratchpadIngest {
            scratchPadStore.ingestAssistantMessage(
                content: scratchpadIngest.content,
                sourceMessageId: scratchpadIngest.sourceMessageId,
                conversationId: scratchpadIngest.conversationId
            )
        }

        if plan.memorySuppressionReason == nil,
           let sourceLearningDigest = plan.sourceLearningDigest,
           let sourceLearningScheduler {
            await sourceLearningScheduler.enqueue(sourceLearningDigest)
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
    }
}
