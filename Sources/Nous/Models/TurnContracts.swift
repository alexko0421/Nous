import Foundation

typealias PreparedTurnSession = PreparedConversationTurn

enum ThinkingTraceTitles {
    static let judge = "Gemini judge thought summary"
    static let assistant = "Assistant reasoning"
    static let agentLoop = "Sonnet tool-loop reasoning"
}

struct ThinkingTraceAccumulator: Sendable {
    private var startedTitles: Set<String> = []
    private var hasContent = false

    mutating func append(_ delta: String, title: String) -> String? {
        guard !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if startedTitles.insert(title).inserted {
            let separator = hasContent ? "\n\n" : ""
            hasContent = true
            return "\(separator)\(title)\n\(delta)"
        }

        hasContent = true
        return delta
    }
}

actor ThinkingTraceStore {
    private var accumulator = ThinkingTraceAccumulator()
    private var content = ""

    func append(_ delta: String, title: String) -> String? {
        guard let displayDelta = accumulator.append(delta, title: title) else {
            return nil
        }
        content.append(displayDelta)
        return displayDelta
    }

    var persistedThinking: String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : content
    }
}

enum SystemPromptBlockID: Equatable {
    case anchorAndPolicies
    case slowMemory
    case activeSkills
    case skillIndex
    case volatile
}

enum CacheControlMarker: Equatable {
    case ephemeral
}

struct SystemPromptBlock: Equatable {
    let id: SystemPromptBlockID
    let content: String
    let cacheControl: CacheControlMarker?
}

/// Output of prompt assembly, represented as ordered prompt blocks while
/// preserving the previous stable/volatile string accessors.
struct TurnSystemSlice: Equatable {
    let blocks: [SystemPromptBlock]

    init(blocks: [SystemPromptBlock]) {
        self.blocks = blocks
    }

    init(stable: String, volatile: String) {
        self.blocks = [
            SystemPromptBlock(id: .anchorAndPolicies, content: stable, cacheControl: .ephemeral),
            SystemPromptBlock(id: .volatile, content: volatile, cacheControl: nil)
        ]
    }

    var stable: String {
        blocks
            .filter { $0.id != .volatile && !$0.content.isEmpty }
            .map(\.content)
            .joined(separator: "\n\n")
    }

    var volatile: String {
        blocks
            .filter { $0.id == .volatile && !$0.content.isEmpty }
            .map(\.content)
            .joined(separator: "\n\n")
    }

    var combined: String {
        combinedString
    }

    var combinedString: String {
        blocks
            .map(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
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

enum MemorySuppressionReason: String, Codable, Equatable, Sendable {
    case hardOptOut = "hard_opt_out"
    case sensitiveConsentRequired = "sensitive_consent_required"
    case unspecified
}

enum MemoryPersistenceDecision: Equatable, Sendable {
    case persist
    case suppress(MemorySuppressionReason)

    var shouldPersist: Bool {
        if case .persist = self { return true }
        return false
    }

    var suppressionReason: MemorySuppressionReason? {
        guard case let .suppress(reason) = self else { return nil }
        return reason
    }
}

struct ContextContinuationPlan {
    let turnId: UUID
    let conversationId: UUID
    let assistantMessageId: UUID
    let scratchpadIngest: ScratchpadIngestRequest?
    let memoryRefresh: EnqueueMemoryRefreshRequest?
    let memorySuppressionReason: MemorySuppressionReason?

    init(
        turnId: UUID,
        conversationId: UUID,
        assistantMessageId: UUID,
        scratchpadIngest: ScratchpadIngestRequest?,
        memoryRefresh: EnqueueMemoryRefreshRequest?,
        memorySuppressionReason: MemorySuppressionReason? = nil
    ) {
        self.turnId = turnId
        self.conversationId = conversationId
        self.assistantMessageId = assistantMessageId
        self.scratchpadIngest = scratchpadIngest
        self.memoryRefresh = memoryRefresh
        self.memorySuppressionReason = memorySuppressionReason
    }
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

struct TurnUserMessageAppended {
    let turnId: UUID
    let node: NousNode
    let userMessage: Message
    let messagesAfterUserAppend: [Message]
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
    case userMessageAppended(TurnUserMessageAppended)
    case prepared(TurnPrepared)
    case thinkingDelta(String)
    case agentTraceDelta(AgentTraceRecord)
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
    let agentTraceJson: String?

    init(
        rawAssistantContent: String,
        assistantContent: String,
        persistedThinking: String?,
        conversationTitle: String?,
        didHitBudgetExhaustion: Bool,
        agentTraceJson: String? = nil
    ) {
        self.rawAssistantContent = rawAssistantContent
        self.assistantContent = assistantContent
        self.persistedThinking = persistedThinking
        self.conversationTitle = conversationTitle
        self.didHitBudgetExhaustion = didHitBudgetExhaustion
        self.agentTraceJson = agentTraceJson
    }
}

struct TurnPlan {
    let turnId: UUID
    let prepared: PreparedTurnSession
    let citations: [SearchResult]
    let promptTrace: PromptGovernanceTrace
    let effectiveMode: ChatMode
    let nextQuickActionModeIfCompleted: QuickActionMode?
    let agentLoopMode: QuickActionMode?
    let judgeEventDraft: JudgeEvent?
    let turnSlice: TurnSystemSlice
    let transcriptMessages: [LLMMessage]
    let focusBlock: String?
    let provider: LLMProvider
    let indexedSkillIds: Set<UUID>

    init(
        turnId: UUID,
        prepared: PreparedTurnSession,
        citations: [SearchResult],
        promptTrace: PromptGovernanceTrace,
        effectiveMode: ChatMode,
        nextQuickActionModeIfCompleted: QuickActionMode?,
        agentLoopMode: QuickActionMode? = nil,
        judgeEventDraft: JudgeEvent?,
        turnSlice: TurnSystemSlice,
        transcriptMessages: [LLMMessage],
        focusBlock: String?,
        provider: LLMProvider,
        indexedSkillIds: Set<UUID> = []
    ) {
        self.turnId = turnId
        self.prepared = prepared
        self.citations = citations
        self.promptTrace = promptTrace
        self.effectiveMode = effectiveMode
        self.nextQuickActionModeIfCompleted = nextQuickActionModeIfCompleted
        self.agentLoopMode = agentLoopMode
        self.judgeEventDraft = judgeEventDraft
        self.turnSlice = turnSlice
        self.transcriptMessages = transcriptMessages
        self.focusBlock = focusBlock
        self.provider = provider
        self.indexedSkillIds = indexedSkillIds
    }
}
