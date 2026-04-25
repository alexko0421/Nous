import Foundation

struct TurnOutcomeFactory: Sendable {
    private let shouldPersistMemory: @Sendable ([Message], UUID?) -> Bool
    private let resolveNextQuickActionMode: @Sendable (QuickActionMode?, String) -> QuickActionMode?

    init(
        shouldPersistMemory: @escaping @Sendable ([Message], UUID?) -> Bool,
        resolveNextQuickActionMode: @escaping @Sendable (QuickActionMode?, String) -> QuickActionMode? = { currentMode, assistantContent in
            guard let currentMode else { return nil }
            let parsed = ClarificationCardParser.parse(assistantContent)
            return parsed.keepsQuickActionMode ? currentMode : nil
        }
    ) {
        self.shouldPersistMemory = shouldPersistMemory
        self.resolveNextQuickActionMode = resolveNextQuickActionMode
    }

    func makePrepared(from plan: TurnPlan) -> TurnPrepared {
        TurnPrepared(
            turnId: plan.turnId,
            node: plan.prepared.node,
            userMessage: plan.prepared.userMessage,
            messagesAfterUserAppend: plan.prepared.messagesAfterUserAppend,
            citations: plan.citations,
            promptTrace: plan.promptTrace,
            effectiveMode: plan.effectiveMode
        )
    }

    func makeCompletion(
        turnId: UUID,
        nextQuickActionModeIfCompleted: QuickActionMode?,
        committed: CommittedAssistantTurn,
        assistantContent: String,
        stableSystem: String
    ) -> TurnCompletion {
        let continuationPlan = ContextContinuationPlan(
            turnId: turnId,
            conversationId: committed.node.id,
            assistantMessageId: committed.assistantMessage.id,
            scratchpadIngest: ScratchpadIngestRequest(
                content: assistantContent,
                sourceMessageId: committed.assistantMessage.id,
                conversationId: committed.node.id
            ),
            memoryRefresh: shouldPersistMemory(
                committed.messagesAfterAssistantAppend,
                committed.node.projectId
            ) ? EnqueueMemoryRefreshRequest(
                nodeId: committed.node.id,
                projectId: committed.node.projectId,
                messages: committed.messagesAfterAssistantAppend
            ) : nil
        )
        let housekeepingPlan = TurnHousekeepingPlan(
            turnId: turnId,
            conversationId: committed.node.id,
            geminiCacheRefresh: GeminiCacheRefreshRequest(
                nodeId: committed.node.id,
                stableSystem: stableSystem,
                persistedMessages: committed.messagesAfterAssistantAppend
            ),
            embeddingRefresh: EmbeddingRefreshRequest(
                nodeId: committed.node.id,
                fullContent: committed.messagesAfterAssistantAppend.map(\.content).joined(separator: "\n")
            ),
            emojiRefresh: ConversationEmojiRefreshRequest(
                node: committed.node,
                messages: committed.messagesAfterAssistantAppend
            )
        )

        return TurnCompletion(
            turnId: turnId,
            node: committed.node,
            assistantMessage: committed.assistantMessage,
            messagesAfterAssistantAppend: committed.messagesAfterAssistantAppend,
            nextQuickActionMode: resolveNextQuickActionMode(
                nextQuickActionModeIfCompleted,
                assistantContent
            ),
            continuationPlan: continuationPlan,
            housekeepingPlan: housekeepingPlan
        )
    }
}
