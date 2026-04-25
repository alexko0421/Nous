import Foundation

typealias PreparedTurnSession = PreparedConversationTurn

/// Output of prompt assembly, split into the slow-changing prefix that can ride
/// the Gemini prompt cache and the per-turn block that must refresh every
/// request. `combined` reconstructs the original single-string layout for
/// non-cache callers.
struct TurnSystemSlice: Equatable {
    let stable: String
    let volatile: String

    var combined: String {
        [stable, volatile].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

struct TurnSessionSnapshot {
    let currentNode: NousNode?
    let messages: [Message]
    let defaultProjectId: UUID?
    let activeChatMode: ChatMode?
    let activeQuickActionMode: QuickActionMode?
}

struct TurnRequest {
    let turnId: UUID
    let snapshot: TurnSessionSnapshot
    let inputText: String
    let attachments: [AttachedFileContext]
    let now: Date
}

struct ScratchpadIngestRequest {
    let content: String
    let sourceMessageId: UUID
    let conversationId: UUID
}

struct EnqueueMemoryRefreshRequest {
    let nodeId: UUID
    let projectId: UUID?
    let messages: [Message]
}

struct ContextContinuationPlan {
    let turnId: UUID
    let conversationId: UUID
    let assistantMessageId: UUID
    let scratchpadIngest: ScratchpadIngestRequest?
    let memoryRefresh: EnqueueMemoryRefreshRequest?
}

struct GeminiCacheRefreshRequest {
    let nodeId: UUID
    let stableSystem: String
    let persistedMessages: [Message]
}

struct EmbeddingRefreshRequest {
    let nodeId: UUID
    let fullContent: String
}

struct ConversationEmojiRefreshRequest {
    let node: NousNode
    let messages: [Message]
}

struct TurnHousekeepingPlan {
    let turnId: UUID
    let conversationId: UUID
    let geminiCacheRefresh: GeminiCacheRefreshRequest?
    let embeddingRefresh: EmbeddingRefreshRequest?
    let emojiRefresh: ConversationEmojiRefreshRequest?
}

struct TurnPrepared {
    let turnId: UUID
    let node: NousNode
    let userMessage: Message
    let messagesAfterUserAppend: [Message]
    let citations: [SearchResult]
    let promptTrace: PromptGovernanceTrace
    let effectiveMode: ChatMode
}

enum TurnAbortReason {
    case cancelledByUser
    case supersededByNewTurn
    case conversationSwitched
    case unexpectedCancellation
}

enum TurnFailureStage {
    case planning
    case execution
    case commit
}

struct TurnFailure {
    let stage: TurnFailureStage
    let message: String
}

struct TurnCompletion {
    let turnId: UUID
    let node: NousNode
    let assistantMessage: Message
    let messagesAfterAssistantAppend: [Message]
    let nextQuickActionMode: QuickActionMode?
    let continuationPlan: ContextContinuationPlan
    let housekeepingPlan: TurnHousekeepingPlan
}

enum TurnEvent {
    case prepared(TurnPrepared)
    case thinkingDelta(String)
    case textDelta(String)
    case completed(TurnCompletion)
    case aborted(TurnAbortReason)
    case failed(TurnFailure)
}

struct TurnEventEnvelope {
    let turnId: UUID
    let sequence: Int
    let event: TurnEvent
}

protocol TurnEventSink: Sendable {
    func emit(_ envelope: TurnEventEnvelope) async
}

final class TurnSequencedEventSink: @unchecked Sendable {
    private let turnId: UUID
    private let sink: any TurnEventSink
    private var nextSequence: Int = 0

    init(turnId: UUID, sink: any TurnEventSink) {
        self.turnId = turnId
        self.sink = sink
    }

    func emit(_ event: TurnEvent) async {
        let envelope = TurnEventEnvelope(
            turnId: turnId,
            sequence: nextSequence,
            event: event
        )
        nextSequence += 1
        await sink.emit(envelope)
    }
}

enum TurnExecutionFailure: Error {
    case invalidPlan(String)
    case infrastructure(String)
}

struct TurnExecutionResult {
    let rawAssistantContent: String
    let assistantContent: String
    let persistedThinking: String?
    let conversationTitle: String?
    let didHitBudgetExhaustion: Bool
}

struct TurnPlan {
    let turnId: UUID
    let prepared: PreparedTurnSession
    let citations: [SearchResult]
    let promptTrace: PromptGovernanceTrace
    let effectiveMode: ChatMode
    let nextQuickActionModeIfCompleted: QuickActionMode?
    let judgeEventDraft: JudgeEvent?
    let turnSlice: TurnSystemSlice
    let transcriptMessages: [LLMMessage]
    let focusBlock: String?
    let provider: LLMProvider
}
