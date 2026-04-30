import Foundation
import Observation

@Observable
@MainActor
final class ChatViewModel {

    // MARK: - State

    var currentNode: NousNode?
    var messages: [Message] = []
    var inputText: String = ""
    var isGenerating: Bool = false
    var currentResponse: String = ""
    var currentThinking: String = ""
    var currentAgentTrace: [AgentTraceRecord] = []
    var didHitBudgetExhaustion: Bool = false
    var citations: [SearchResult] = []
    var activeQuickActionMode: QuickActionMode?
    var activeChatMode: ChatMode? = nil
    var defaultProjectId: UUID?
    var lastPromptGovernanceTrace: PromptGovernanceTrace?
    private var judgeFeedbackVersion: Int = 0

    // MARK: - Dependencies

    private let nodeStore: NodeStore
    private let vectorStore: VectorStore
    private let embeddingService: EmbeddingService
    private let graphEngine: GraphEngine
    private let relationRefinementQueue: GalaxyRelationRefinementQueue?
    private let userMemoryService: UserMemoryService
    private let userMemoryScheduler: UserMemoryScheduler
    private let conversationSessionStore: ConversationSessionStore
    @ObservationIgnored private let explicitTurnRunner: ChatTurnRunner?
    @ObservationIgnored private let explicitTurnPlanner: TurnPlanner?
    @ObservationIgnored private let explicitTurnExecutor: TurnExecutor?
    @ObservationIgnored private let explicitContextContinuationService: ContextContinuationService?
    @ObservationIgnored private let explicitTurnHousekeepingService: TurnHousekeepingService?
    private let llmServiceProvider: () -> (any LLMService)?
    private let currentProviderProvider: () -> LLMProvider
    private let judgeLLMServiceFactory: () -> (any LLMService)?
    private let provocationJudgeFactory: (any LLMService) -> any Judging
    private let skillStore: SkillStore?
    private let skillMatcher: SkillMatcher?
    private let skillTracker: SkillTracker?
    /// Stored as a typed `Task<JudgeVerdict, Error>` — not `Task<Void, …>` — so tests can
    /// `await task.value` and inspect the verdict directly. The slot is guarded on clear:
    /// a later `send()` may have already overwritten it with a new task ID, so only the task
    /// that still owns the slot clears it (see `inFlightJudgeTaskId` guard in `send()`).
    @ObservationIgnored nonisolated(unsafe) private var inFlightJudgeTask: Task<JudgeVerdict, Error>?
    @ObservationIgnored nonisolated(unsafe) private var inFlightJudgeTaskId: UUID?
    @ObservationIgnored nonisolated(unsafe) private var inFlightResponseTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var inFlightResponseTaskId: UUID?
    @ObservationIgnored nonisolated(unsafe) private var inFlightResponseAbortReason: TurnAbortReason?
    private let governanceTelemetry: GovernanceTelemetryStore
    private let geminiPromptCache: GeminiPromptCacheService
    private let scratchPadStore: ScratchPadStore
    private let shouldUseGeminiHistoryCache: () -> Bool
    private let shouldPersistAssistantThinking: () -> Bool
    @ObservationIgnored private var cachedTurnPlanner: TurnPlanner?
    @ObservationIgnored private var cachedTurnExecutor: TurnExecutor?
    @ObservationIgnored private var cachedQuickActionOpeningRunner: QuickActionOpeningRunner?
    @ObservationIgnored private var cachedContextContinuationService: ContextContinuationService?
    @ObservationIgnored private var cachedTurnHousekeepingService: TurnHousekeepingService?
    private var memoryProjectionService: MemoryProjectionService {
        userMemoryService.projectionReader
    }
    private var turnOutcomeFactory: TurnOutcomeFactory {
        let projectionService = memoryProjectionService
        return TurnOutcomeFactory(
            shouldPersistMemory: { messages, projectId in
                projectionService.shouldPersistMemory(messages: messages, projectId: projectId)
            }
        )
    }
    private var turnRunner: ChatTurnRunner {
        if let explicitTurnRunner {
            return explicitTurnRunner
        }

        return ChatTurnRunner(
            conversationSessionStore: conversationSessionStore,
            turnPlanner: turnPlanner,
            turnExecutor: turnExecutor,
            agentLoopExecutorFactory: { [weak self] mode, _, _ in
                guard let self,
                      self.currentProviderProvider() == .openrouter,
                      let toolLLM = self.llmServiceProvider() as? any ToolCallingLLMService,
                      toolLLM.supportsAgentToolUse else {
                    return nil
                }
                let registry = AgentToolRegistry
                    .standard(
                        nodeStore: self.nodeStore,
                        vectorStore: self.vectorStore,
                        embeddingService: self.embeddingService,
                        contradictionProvider: self.userMemoryService.contradictionReader
                    )
                    .subset(mode.agent().toolNames)
                return AgentLoopExecutor(llmService: toolLLM, registry: registry)
            },
            outcomeFactory: turnOutcomeFactory,
            onPlanReady: { [governanceTelemetry] plan in
                governanceTelemetry.recordPromptTrace(plan.promptTrace)
                if let event = plan.judgeEventDraft {
                    governanceTelemetry.appendJudgeEvent(event)
                }
            }
        )
    }
    private var turnPlanner: TurnPlanner {
        if let explicitTurnPlanner {
            return explicitTurnPlanner
        }
        if let cachedTurnPlanner {
            return cachedTurnPlanner
        }

        let planner = TurnPlanner(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            memoryProjectionService: userMemoryService.projectionReader,
            contradictionMemoryService: userMemoryService.contradictionReader,
            currentProviderProvider: currentProviderProvider,
            judgeLLMServiceFactory: judgeLLMServiceFactory,
            provocationJudgeFactory: provocationJudgeFactory,
            governanceTelemetry: governanceTelemetry,
            skillStore: skillStore,
            skillMatcher: skillMatcher ?? SkillMatcher(),
            skillTracker: skillTracker,
            runJudge: { [weak self] operation in
                guard let self else { throw CancellationError() }
                return try await self.executeJudgeTask(operation)
            }
        )
        cachedTurnPlanner = planner
        return planner
    }
    private var turnExecutor: TurnExecutor {
        if let explicitTurnExecutor {
            return explicitTurnExecutor
        }
        if let cachedTurnExecutor {
            return cachedTurnExecutor
        }

        let executor = TurnExecutor(
            llmServiceProvider: llmServiceProvider,
            geminiPromptCache: geminiPromptCache,
            shouldUseGeminiHistoryCache: shouldUseGeminiHistoryCache,
            shouldPersistAssistantThinking: shouldPersistAssistantThinking,
            recordGeminiUsage: { [governanceTelemetry] usage in
                governanceTelemetry.recordGeminiUsage(usage)
            }
        )
        cachedTurnExecutor = executor
        return executor
    }
    private var quickActionOpeningRunner: QuickActionOpeningRunner {
        if let cachedQuickActionOpeningRunner {
            return cachedQuickActionOpeningRunner
        }

        let runner = QuickActionOpeningRunner(
            conversationSessionStore: conversationSessionStore,
            memoryContextBuilder: TurnMemoryContextBuilder(
                nodeStore: nodeStore,
                vectorStore: vectorStore,
                embeddingService: embeddingService,
                memoryProjectionService: memoryProjectionService,
                contradictionMemoryService: userMemoryService.contradictionReader
            ),
            turnExecutor: turnExecutor,
            outcomeFactory: turnOutcomeFactory,
            currentProviderProvider: currentProviderProvider,
            skillStore: skillStore,
            skillMatcher: skillMatcher ?? SkillMatcher(),
            skillTracker: skillTracker,
            onPlanReady: { [governanceTelemetry] plan in
                governanceTelemetry.recordPromptTrace(plan.promptTrace)
            }
        )
        cachedQuickActionOpeningRunner = runner
        return runner
    }
    private var contextContinuationService: ContextContinuationService {
        if let explicitContextContinuationService {
            return explicitContextContinuationService
        }
        if let cachedContextContinuationService {
            return cachedContextContinuationService
        }

        let service = ContextContinuationService(
            scratchPadStore: scratchPadStore,
            userMemoryScheduler: userMemoryScheduler,
            governanceTelemetry: governanceTelemetry
        )
        cachedContextContinuationService = service
        return service
    }
    private var turnHousekeepingService: TurnHousekeepingService {
        if let explicitTurnHousekeepingService {
            return explicitTurnHousekeepingService
        }
        if let cachedTurnHousekeepingService {
            return cachedTurnHousekeepingService
        }

        let service = TurnHousekeepingService(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            relationRefinementQueue: relationRefinementQueue,
            geminiPromptCache: geminiPromptCache,
            llmServiceProvider: llmServiceProvider,
            shouldUseGeminiHistoryCache: shouldUseGeminiHistoryCache,
            onConversationNodeUpdated: { [weak self] refreshedNode in
                guard let self, self.currentNode?.id == refreshedNode.id else { return }
                self.currentNode = refreshedNode
            }
        )
        cachedTurnHousekeepingService = service
        return service
    }

    // MARK: - Init

    init(
        nodeStore: NodeStore,
        vectorStore: VectorStore,
        embeddingService: EmbeddingService,
        graphEngine: GraphEngine,
        relationRefinementQueue: GalaxyRelationRefinementQueue? = nil,
        userMemoryService: UserMemoryService,
        userMemoryScheduler: UserMemoryScheduler,
        conversationSessionStore: ConversationSessionStore? = nil,
        turnRunner: ChatTurnRunner? = nil,
        turnPlanner: TurnPlanner? = nil,
        turnExecutor: TurnExecutor? = nil,
        contextContinuationService: ContextContinuationService? = nil,
        turnHousekeepingService: TurnHousekeepingService? = nil,
        llmServiceProvider: @escaping () -> (any LLMService)?,
        currentProviderProvider: @escaping () -> LLMProvider,
        judgeLLMServiceFactory: @escaping () -> (any LLMService)?,
        provocationJudgeFactory: @escaping (any LLMService) -> any Judging = { ProvocationJudge(llmService: $0) },
        skillStore: SkillStore? = nil,
        skillMatcher: SkillMatcher? = nil,
        skillTracker: SkillTracker? = nil,
        governanceTelemetry: GovernanceTelemetryStore = GovernanceTelemetryStore(),
        geminiPromptCache: GeminiPromptCacheService = GeminiPromptCacheService(),
        scratchPadStore: ScratchPadStore,
        shouldUseGeminiHistoryCache: @escaping () -> Bool = { true },
        shouldPersistAssistantThinking: @escaping () -> Bool = { true },
        defaultProjectId: UUID? = nil
    ) {
        self.nodeStore = nodeStore
        self.vectorStore = vectorStore
        self.embeddingService = embeddingService
        self.graphEngine = graphEngine
        self.relationRefinementQueue = relationRefinementQueue
        self.userMemoryService = userMemoryService
        self.userMemoryScheduler = userMemoryScheduler
        self.conversationSessionStore = conversationSessionStore ?? ConversationSessionStore(nodeStore: nodeStore)
        self.llmServiceProvider = llmServiceProvider
        self.currentProviderProvider = currentProviderProvider
        self.judgeLLMServiceFactory = judgeLLMServiceFactory
        self.provocationJudgeFactory = provocationJudgeFactory
        self.skillStore = skillStore
        self.skillMatcher = skillMatcher
        self.skillTracker = skillTracker
        self.governanceTelemetry = governanceTelemetry
        self.geminiPromptCache = geminiPromptCache
        self.scratchPadStore = scratchPadStore
        self.shouldUseGeminiHistoryCache = shouldUseGeminiHistoryCache
        self.shouldPersistAssistantThinking = shouldPersistAssistantThinking
        self.defaultProjectId = defaultProjectId
        self.explicitTurnRunner = turnRunner
        self.explicitTurnPlanner = turnPlanner
        self.explicitTurnExecutor = turnExecutor
        self.explicitContextContinuationService = contextContinuationService
        self.explicitTurnHousekeepingService = turnHousekeepingService
    }

    // MARK: - Conversation Management

    @MainActor
    func startNewConversation(
        title: String = "New Conversation",
        projectId: UUID? = nil,
        cancelInFlightWork: Bool = true
    ) {
        if cancelInFlightWork {
            cancelInFlightResponse(clearDraft: true, reason: .supersededByNewTurn)
            cancelInFlightJudge()  // any in-flight judge belonged to the old conversation
        }
        guard let node = try? conversationSessionStore.startConversation(
            title: title,
            projectId: projectId
        ) else { return }
        currentNode = node
        scratchPadStore.activate(conversationId: node.id)
        messages = []
        citations = []
        currentResponse = ""
        currentThinking = ""
        currentAgentTrace = []
        didHitBudgetExhaustion = false
        activeQuickActionMode = nil
        activeChatMode = nil  // brand-new chat has no prior judgment
    }

    @MainActor
    func loadConversation(_ node: NousNode, cancelInFlightWork: Bool = true) {
        if cancelInFlightWork {
            cancelInFlightResponse(clearDraft: true, reason: .conversationSwitched)
            cancelInFlightJudge()  // switching conversations invalidates any pending verdict
        }
        currentNode = node
        scratchPadStore.activate(conversationId: node.id)
        messages = (try? nodeStore.fetchMessages(nodeId: node.id)) ?? []
        citations = []
        currentResponse = ""
        currentThinking = ""
        currentAgentTrace = []
        didHitBudgetExhaustion = false
        activeQuickActionMode = nil
        activeChatMode = (try? nodeStore.latestChatMode(forNode: node.id)) ?? nil
    }

    func activateQuickActionMode(_ mode: QuickActionMode) {
        activeQuickActionMode = mode
    }

    @MainActor
    func beginQuickActionConversation(_ mode: QuickActionMode) async {
        guard !isGenerating else { return }

        let responseTaskId = UUID()
        inFlightResponseAbortReason = nil
        let responseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runQuickActionConversation(mode, responseTaskId: responseTaskId)
        }
        inFlightResponseTask = responseTask
        inFlightResponseTaskId = responseTaskId
        await responseTask.value
        clearInFlightResponseTaskIfOwned(responseTaskId)
        if inFlightResponseTaskId == nil {
            inFlightResponseAbortReason = nil
        }
    }

    @MainActor
    private func runQuickActionConversation(_ mode: QuickActionMode, responseTaskId: UUID) async {
        guard isActiveResponseTask(responseTaskId) else { return }

        // Quick actions are a launch path, not the lasting chat label.
        startNewConversation(projectId: defaultProjectId, cancelInFlightWork: false)
        activeQuickActionMode = mode
        inputText = ""

        guard let node = currentNode else { return }

        isGenerating = true
        currentResponse = ""
        currentThinking = ""
        currentAgentTrace = []
        didHitBudgetExhaustion = false
        defer {
            if isActiveResponseTask(responseTaskId) {
                isGenerating = false
            }
        }

        let eventSink = makeTurnEventSink(turnId: responseTaskId)
        guard let completion = await quickActionOpeningRunner.run(
            mode: mode,
            node: node,
            turnId: responseTaskId,
            sink: eventSink,
            abortReason: { [unowned self] in
                self.responseAbortReason(for: responseTaskId)
            }
        ) else {
            return
        }
        await contextContinuationService.run(completion.continuationPlan)
        turnHousekeepingService.run(completion.housekeepingPlan)
    }

    // MARK: - Voice persistence

    /// Returns the ID of the conversation voice should bind to. If a current
    /// node exists, returns its ID. Otherwise creates an empty conversation
    /// and switches the in-memory state to it. Synchronous because
    /// ChatViewModel is @MainActor.
    func ensureConversationForVoice() throws -> UUID {
        if let current = currentNode {
            return current.id
        }
        let node = try conversationSessionStore.startConversation(
            title: "New Conversation",
            projectId: defaultProjectId
        )
        self.currentNode = node
        self.messages = []
        return node.id
    }

    /// Build a TurnHousekeepingPlan for a voice-user-only turn. Reuses the
    /// embedding / Galaxy / emoji refresh paths the typed flow uses; skips
    /// Gemini cache refresh because voice does not run through the
    /// typed-flow LLM service.
    private func voiceUserHousekeepingPlan(
        node: NousNode,
        messagesAfterAppend: [Message]
    ) -> TurnHousekeepingPlan {
        TurnHousekeepingPlan(
            turnId: UUID(),
            conversationId: node.id,
            geminiCacheRefresh: nil,
            embeddingRefresh: EmbeddingRefreshRequest(
                nodeId: node.id,
                fullContent: node.content
            ),
            emojiRefresh: ConversationEmojiRefreshRequest(
                node: node,
                messages: messagesAfterAppend
            )
        )
    }

    /// Append a voice user message to the conversation identified by nodeId,
    /// even if it is not the currently-loaded conversation. Updates the
    /// in-memory `messages` array only if the bound node is also the
    /// currently-loaded one. Fires the same housekeeping pipeline the typed
    /// flow fires after a turn (embedding + Galaxy + emoji refresh).
    func appendVoiceMessage(
        nodeId: UUID,
        text: String,
        timestamp: Date
    ) throws {
        let result = try conversationSessionStore.appendVoiceUserMessage(
            nodeId: nodeId,
            text: text,
            timestamp: timestamp
        )
        if currentNode?.id == nodeId {
            self.messages = result.messagesAfterAppend
        }
        let plan = voiceUserHousekeepingPlan(
            node: result.node,
            messagesAfterAppend: result.messagesAfterAppend
        )
        turnHousekeepingService.run(plan)
    }

    // MARK: - Send (RAG Pipeline)

    @MainActor
    func send(attachments: [AttachedFileContext] = []) async {
        let limitedAttachments = AttachmentLimitPolicy.limitingImageAttachments(attachments)
        guard (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !limitedAttachments.isEmpty), !isGenerating else { return }

        let responseTaskId = UUID()
        inFlightResponseAbortReason = nil
        let responseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSend(attachments: limitedAttachments, responseTaskId: responseTaskId)
        }
        inFlightResponseTask = responseTask
        inFlightResponseTaskId = responseTaskId
        await responseTask.value
        clearInFlightResponseTaskIfOwned(responseTaskId)
        if inFlightResponseTaskId == nil {
            inFlightResponseAbortReason = nil
        }
    }

    @MainActor
    func canRegenerateAssistantMessage(_ messageId: UUID) -> Bool {
        guard !isGenerating,
              let latestAssistant = messages.last,
              latestAssistant.id == messageId,
              latestAssistant.role == .assistant
        else { return false }

        return messages.dropLast().contains { $0.role == .user }
    }

    @MainActor
    func regenerateLatestAssistant() async {
        guard !isGenerating,
              let latestAssistant = messages.last,
              latestAssistant.role == .assistant,
              messages.dropLast().contains(where: { $0.role == .user })
        else { return }

        let responseTaskId = UUID()
        inFlightResponseAbortReason = nil
        let responseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runRegenerateLatestAssistant(responseTaskId: responseTaskId)
        }
        inFlightResponseTask = responseTask
        inFlightResponseTaskId = responseTaskId
        await responseTask.value
        clearInFlightResponseTaskIfOwned(responseTaskId)
        if inFlightResponseTaskId == nil {
            inFlightResponseAbortReason = nil
        }
    }

    @MainActor
    private func runSend(attachments: [AttachedFileContext], responseTaskId: UUID) async {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!query.isEmpty || !attachments.isEmpty), isActiveResponseTask(responseTaskId) else { return }

        let turnRequest = TurnRequest(
            turnId: responseTaskId,
            snapshot: TurnSessionSnapshot(
                currentNode: currentNode,
                messages: messages,
                defaultProjectId: defaultProjectId,
                activeChatMode: activeChatMode,
                activeQuickActionMode: activeQuickActionMode
            ),
            inputText: query,
            attachments: attachments,
            now: Date()
        )
        let eventSink = makeTurnEventSink(turnId: responseTaskId)

        inputText = ""
        isGenerating = true
        currentResponse = ""
        currentAgentTrace = []
        defer {
            if isActiveResponseTask(responseTaskId) {
                isGenerating = false
            }
        }

        guard let completion = await turnRunner.run(
            request: turnRequest,
            sink: eventSink,
            abortReason: { [unowned self] in
                self.responseAbortReason(for: responseTaskId)
            }
        ) else {
            return
        }
        bumpJudgeFeedbackVersion()
        await contextContinuationService.run(completion.continuationPlan)
        turnHousekeepingService.run(completion.housekeepingPlan)
    }

    @MainActor
    private func runRegenerateLatestAssistant(responseTaskId: UUID) async {
        guard isActiveResponseTask(responseTaskId),
              let node = currentNode,
              let latestAssistant = messages.last,
              latestAssistant.role == .assistant,
              let userMessage = messages.dropLast().last(where: { $0.role == .user })
        else { return }

        let retainedMessages = Array(messages.dropLast())
        let updatedNode: NousNode
        do {
            updatedNode = try conversationSessionStore.removeAssistantTurn(
                nodeId: node.id,
                assistantMessage: latestAssistant,
                retainedMessages: retainedMessages
            )
        } catch {
            presentAssistantFailure("Error: \(error.localizedDescription)")
            return
        }

        currentNode = updatedNode
        messages = retainedMessages
        citations = []
        currentResponse = ""
        currentThinking = ""
        currentAgentTrace = []
        didHitBudgetExhaustion = false

        let request = TurnRequest(
            turnId: responseTaskId,
            snapshot: TurnSessionSnapshot(
                currentNode: updatedNode,
                messages: retainedMessages,
                defaultProjectId: defaultProjectId,
                activeChatMode: activeChatMode,
                activeQuickActionMode: activeQuickActionMode
            ),
            inputText: userMessage.content,
            attachments: [],
            now: Date()
        )
        let prepared = PreparedConversationTurn(
            node: updatedNode,
            userMessage: userMessage,
            messagesAfterUserAppend: retainedMessages
        )
        let eventSink = makeTurnEventSink(turnId: responseTaskId)

        isGenerating = true
        defer {
            if isActiveResponseTask(responseTaskId) {
                isGenerating = false
            }
        }

        guard let completion = await turnRunner.runPreparedTurn(
            prepared: prepared,
            request: request,
            sink: eventSink,
            abortReason: { [unowned self] in
                self.responseAbortReason(for: responseTaskId)
            }
        ) else {
            return
        }
        bumpJudgeFeedbackVersion()
        await contextContinuationService.run(completion.continuationPlan)
        turnHousekeepingService.run(completion.housekeepingPlan)
    }

    @MainActor
    private func makeTurnEventSink(turnId: UUID) -> TurnSequencedEventSink {
        TurnSequencedEventSink(
            turnId: turnId,
            sink: ClosureTurnEventSink { [weak self] envelope in
                guard let self else { return }
                await self.handleTurnEvent(envelope)
            }
        )
    }

    @MainActor
    private func responseAbortReason(for taskId: UUID) -> TurnAbortReason {
        guard inFlightResponseTaskId == taskId else {
            return inFlightResponseAbortReason ?? .unexpectedCancellation
        }
        return inFlightResponseAbortReason ?? .unexpectedCancellation
    }

    @MainActor
    private func handleTurnEvent(_ envelope: TurnEventEnvelope) {
        guard isActiveResponseTask(envelope.turnId) else { return }

        switch envelope.event {
        case .prepared(let prepared):
            currentNode = prepared.node
            messages = prepared.messagesAfterUserAppend
            citations = prepared.citations
            lastPromptGovernanceTrace = prepared.promptTrace
            if !prepared.messagesAfterUserAppend.isEmpty {
                activeChatMode = prepared.effectiveMode
            }
            currentResponse = ""
            currentThinking = ""
            currentAgentTrace = []
            didHitBudgetExhaustion = false
        case .thinkingDelta(let delta):
            currentThinking.append(delta)
        case .agentTraceDelta(let record):
            currentAgentTrace.append(record)
        case .textDelta(let delta):
            currentResponse.append(delta)
        case .completed(let completion):
            currentNode = completion.node
            messages = completion.messagesAfterAssistantAppend
            activeQuickActionMode = completion.nextQuickActionMode
            currentResponse = ""
            currentThinking = ""
            currentAgentTrace = []
            didHitBudgetExhaustion = false
        case .aborted(let reason):
            currentThinking = ""
            currentAgentTrace = []
            didHitBudgetExhaustion = false
            if reason == .unexpectedCancellation {
                presentAssistantFailure(
                    "Error: The reply was interrupted before it finished. Please try again."
                )
            }
        case .failed(let failure):
            currentThinking = ""
            currentAgentTrace = []
            didHitBudgetExhaustion = false
            presentAssistantFailure("Error: \(failure.message)")
        }
    }

    @MainActor
    private func presentAssistantFailure(_ content: String) {
        guard let nodeId = currentNode?.id else {
            currentResponse = content
            return
        }
        if let committed = try? conversationSessionStore.commitAssistantTurn(
            nodeId: nodeId,
            currentMessages: messages,
            assistantContent: content
        ) {
            currentNode = committed.node
            messages = committed.messagesAfterAssistantAppend
        } else {
            messages.append(
                Message(
                    nodeId: nodeId,
                    role: .assistant,
                    content: content
                )
            )
        }
        currentResponse = ""
        currentAgentTrace = []
    }

    @MainActor
    private func executeJudgeTask(
        _ operation: @escaping () async throws -> JudgeVerdict
    ) async throws -> JudgeVerdict {
        inFlightJudgeTask?.cancel()

        let taskId = UUID()
        let task = Task { try await operation() }
        inFlightJudgeTask = task
        inFlightJudgeTaskId = taskId
        defer {
            if inFlightJudgeTaskId == taskId {
                inFlightJudgeTask = nil
                inFlightJudgeTaskId = nil
            }
        }
        return try await task.value
    }

    /// External hook to cancel an in-flight judge call (conversation switch, VM teardown, etc.).
    /// Safe to call at any time — no-op if no judge is running.
    @MainActor
    func cancelInFlightJudge() {
        inFlightJudgeTask?.cancel()
        inFlightJudgeTask = nil
        inFlightJudgeTaskId = nil
    }

    @MainActor
    func stopGenerating() {
        cancelInFlightJudge()
        cancelInFlightResponse(clearDraft: false, reason: .cancelledByUser)
    }

    @MainActor
    func purgePersistedThinkingFromLoadedMessages() {
        messages = messages.map { message in
            var updated = message
            updated.thinkingContent = nil
            return updated
        }
    }

    @MainActor
    func purgeGeminiHistoryCaches() async {
        await turnHousekeepingService.purgeGeminiHistoryCaches()
    }

    @MainActor
    private func cancelInFlightResponse(clearDraft: Bool, reason: TurnAbortReason) {
        if inFlightResponseTaskId != nil {
            inFlightResponseAbortReason = reason
        }
        inFlightResponseTask?.cancel()
        inFlightResponseTask = nil
        inFlightResponseTaskId = nil
        isGenerating = false
        if clearDraft {
            currentResponse = ""
            currentThinking = ""
            currentAgentTrace = []
            didHitBudgetExhaustion = false
        }
    }

    @MainActor
    private func isActiveResponseTask(_ taskId: UUID) -> Bool {
        inFlightResponseTaskId == taskId
    }

    @MainActor
    private func clearInFlightResponseTaskIfOwned(_ taskId: UUID) {
        guard inFlightResponseTaskId == taskId else { return }
        inFlightResponseTask = nil
        inFlightResponseTaskId = nil
        inFlightResponseAbortReason = nil
    }

}

private final class ClosureTurnEventSink: TurnEventSink, @unchecked Sendable {
    private let handler: @Sendable (TurnEventEnvelope) async -> Void

    init(handler: @escaping @Sendable (TurnEventEnvelope) async -> Void) {
        self.handler = handler
    }

    func emit(_ envelope: TurnEventEnvelope) async {
        await handler(envelope)
    }
}

extension ChatViewModel {
    @MainActor
    private func judgeEvent(forMessageId messageId: UUID) -> JudgeEvent? {
        _ = judgeFeedbackVersion
        let events = governanceTelemetry.recentJudgeEvents(limit: 500, filter: .none)
        return events.first(where: { $0.messageId == messageId })
    }

    @MainActor
    private func bumpJudgeFeedbackVersion() {
        judgeFeedbackVersion &+= 1
    }

    /// Returns the judge event id for a given assistant message when the turn
    /// that produced it logged one. Older pre-feature turns may still return nil.
    @MainActor
    func judgeEventId(forMessageId messageId: UUID) -> UUID? {
        judgeEvent(forMessageId: messageId)?.id
    }

    @MainActor
    func feedback(forMessageId messageId: UUID) -> JudgeFeedback? {
        judgeEvent(forMessageId: messageId)?.userFeedback
    }

    @MainActor
    func feedbackReason(forMessageId messageId: UUID) -> JudgeFeedbackReason? {
        judgeEvent(forMessageId: messageId)?.feedbackReason
    }

    @MainActor
    func feedbackNote(forMessageId messageId: UUID) -> String {
        judgeEvent(forMessageId: messageId)?.feedbackNote ?? ""
    }

    @MainActor
    func recordFeedback(forMessageId messageId: UUID, feedback: JudgeFeedback) {
        guard let eventId = judgeEventId(forMessageId: messageId) else { return }
        governanceTelemetry.recordFeedback(eventId: eventId, feedback: feedback)
        bumpJudgeFeedbackVersion()
    }

    @MainActor
    func recordFeedbackDetail(
        forMessageId messageId: UUID,
        feedback: JudgeFeedback,
        reason: JudgeFeedbackReason?,
        note: String?
    ) {
        guard let eventId = judgeEventId(forMessageId: messageId) else { return }
        governanceTelemetry.recordFeedback(eventId: eventId, feedback: feedback, reason: reason, note: note)
        bumpJudgeFeedbackVersion()
    }

    @MainActor
    func clearFeedback(forMessageId messageId: UUID) {
        guard let eventId = judgeEventId(forMessageId: messageId) else { return }
        governanceTelemetry.clearFeedback(eventId: eventId)
        bumpJudgeFeedbackVersion()
    }
}
