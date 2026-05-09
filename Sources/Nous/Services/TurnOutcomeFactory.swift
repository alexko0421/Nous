import Foundation

struct TurnOutcomeFactory: Sendable {
    private let memoryPersistenceDecision: @Sendable ([Message], UUID?) -> MemoryPersistenceDecision
    private let resolveNextQuickActionMode: @Sendable (QuickActionMode?, String, Int) -> QuickActionMode?

    init(
        memoryPersistenceDecision: @escaping @Sendable ([Message], UUID?) -> MemoryPersistenceDecision,
        resolveNextQuickActionMode: @escaping @Sendable (QuickActionMode?, String, Int) -> QuickActionMode? = { currentMode, assistantContent, turnIndex in
            TurnInteractionPolicy.updatedQuickActionMode(
                currentMode: currentMode,
                assistantContent: assistantContent,
                turnIndex: turnIndex
            )
        }
    ) {
        self.memoryPersistenceDecision = memoryPersistenceDecision
        self.resolveNextQuickActionMode = resolveNextQuickActionMode
    }

    init(
        shouldPersistMemory: @escaping @Sendable ([Message], UUID?) -> Bool,
        resolveNextQuickActionMode: @escaping @Sendable (QuickActionMode?, String, Int) -> QuickActionMode? = { currentMode, assistantContent, turnIndex in
            TurnInteractionPolicy.updatedQuickActionMode(
                currentMode: currentMode,
                assistantContent: assistantContent,
                turnIndex: turnIndex
            )
        }
    ) {
        self.init(
            memoryPersistenceDecision: { messages, projectId in
                shouldPersistMemory(messages, projectId) ? .persist : .suppress(.unspecified)
            },
            resolveNextQuickActionMode: resolveNextQuickActionMode
        )
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
        let memoryDecision = memoryPersistenceDecision(
            committed.messagesAfterAssistantAppend,
            committed.node.projectId
        )
        let continuationPlan = ContextContinuationPlan(
            turnId: turnId,
            conversationId: committed.node.id,
            assistantMessageId: committed.assistantMessage.id,
            scratchpadIngest: ScratchpadIngestRequest(
                content: assistantContent,
                sourceMessageId: committed.assistantMessage.id,
                conversationId: committed.node.id
            ),
            memoryRefresh: memoryDecision.shouldPersist ? EnqueueMemoryRefreshRequest(
                nodeId: committed.node.id,
                projectId: committed.node.projectId,
                messages: committed.messagesAfterAssistantAppend
            ) : nil,
            memorySuppressionReason: memoryDecision.suppressionReason
        )
        let housekeepingPlan = TurnHousekeepingPlan(
            turnId: turnId,
            conversationId: committed.node.id,
            geminiCacheRefresh: GeminiCacheRefreshRequest(
                nodeId: committed.node.id,
                stableSystem: stableSystem,
                persistedMessages: committed.messagesAfterAssistantAppend
            ),
            embeddingRefresh: memoryDecision.shouldPersist ? EmbeddingRefreshRequest(
                nodeId: committed.node.id,
                fullContent: committed.messagesAfterAssistantAppend.map(\.content).joined(separator: "\n")
            ) : nil,
            emojiRefresh: ConversationEmojiRefreshRequest(
                node: committed.node,
                messages: committed.messagesAfterAssistantAppend
            )
        )

        let turnIndex = committed.messagesAfterAssistantAppend.lazy.filter { $0.role == .user }.count
        return TurnCompletion(
            turnId: turnId,
            node: committed.node,
            assistantMessage: committed.assistantMessage,
            messagesAfterAssistantAppend: committed.messagesAfterAssistantAppend,
            nextQuickActionMode: resolveNextQuickActionMode(
                nextQuickActionModeIfCompleted,
                assistantContent,
                turnIndex
            ),
            continuationPlan: continuationPlan,
            housekeepingPlan: housekeepingPlan
        )
    }
}
