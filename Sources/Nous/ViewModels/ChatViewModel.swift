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
        self.userMemoryService = userMemoryService
        self.userMemoryScheduler = userMemoryScheduler
        self.conversationSessionStore = conversationSessionStore ?? ConversationSessionStore(nodeStore: nodeStore)
        self.llmServiceProvider = llmServiceProvider
        self.currentProviderProvider = currentProviderProvider
        self.judgeLLMServiceFactory = judgeLLMServiceFactory
        self.provocationJudgeFactory = provocationJudgeFactory
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
        defer {
            if isActiveResponseTask(responseTaskId) {
                isGenerating = false
            }
        }

        var projectGoal: String? = nil
        if let projectId = node.projectId,
           let project = try? nodeStore.fetchProject(id: projectId),
           !project.goal.isEmpty {
            projectGoal = project.goal
        }
        let memoryProjection = memoryProjectionService

        let contextSlice = ChatViewModel.assembleContext(
            chatMode: .companion,
            currentUserInput: ChatViewModel.quickActionOpeningPrompt(for: mode),
            globalMemory: memoryProjection.currentGlobal(),
            essentialStory: memoryProjection.currentEssentialStory(
                projectId: node.projectId,
                excludingConversationId: node.id
            ),
            userModel: memoryProjection.currentUserModel(
                projectId: node.projectId,
                conversationId: node.id
            ),
            memoryEvidence: memoryProjection.currentBoundedEvidence(
                projectId: node.projectId,
                excludingConversationId: node.id
            ),
            projectMemory: node.projectId.flatMap { memoryProjection.currentProject(projectId: $0) },
            conversationMemory: memoryProjection.currentConversation(nodeId: node.id),
            recentConversations: [],
            citations: [],
            projectGoal: projectGoal,
            activeQuickActionMode: mode,
            allowInteractiveClarification: false
        )
        let promptTrace = ChatViewModel.governanceTrace(
            chatMode: .companion,
            currentUserInput: ChatViewModel.quickActionOpeningPrompt(for: mode),
            globalMemory: memoryProjection.currentGlobal(),
            essentialStory: memoryProjection.currentEssentialStory(
                projectId: node.projectId,
                excludingConversationId: node.id
            ),
            userModel: memoryProjection.currentUserModel(
                projectId: node.projectId,
                conversationId: node.id
            ),
            memoryEvidence: memoryProjection.currentBoundedEvidence(
                projectId: node.projectId,
                excludingConversationId: node.id
            ),
            projectMemory: node.projectId.flatMap { memoryProjection.currentProject(projectId: $0) },
            conversationMemory: memoryProjection.currentConversation(nodeId: node.id),
            recentConversations: [],
            citations: [],
            projectGoal: projectGoal,
            attachments: [],
            activeQuickActionMode: mode,
            allowInteractiveClarification: false
        )
        lastPromptGovernanceTrace = promptTrace
        governanceTelemetry.recordPromptTrace(promptTrace)

        guard let llm = llmServiceProvider() else {
            guard isActiveResponseTask(responseTaskId) else { return }
            let errorContent = "Please configure an LLM in Settings."
            guard let committed = try? conversationSessionStore.commitAssistantTurn(
                nodeId: node.id,
                currentMessages: messages,
                assistantContent: errorContent
            ) else { return }
            currentNode = committed.node
            messages = committed.messagesAfterAssistantAppend
            activeQuickActionMode = ChatViewModel.updatedQuickActionMode(
                currentMode: activeQuickActionMode,
                assistantContent: errorContent
            )
            currentResponse = ""
            return
        }

        let quickActionUserText = ChatViewModel.quickActionOpeningPrompt(for: mode)
        let transcriptForCache = [LLMMessage(role: "user", content: quickActionUserText)]
        let resolvedCacheEntry = activeGeminiHistoryCache(
            nodeId: node.id,
            llm: llm,
            stableSystem: contextSlice.stable,
            transcriptMessages: transcriptForCache
        )
        let streamingService = configuredStreamingService(
            from: configuredGeminiService(from: llm, cacheEntry: resolvedCacheEntry),
            responseTaskId: responseTaskId,
            captureThinking: false
        )

        let requestMessages = requestMessages(
            forSlice: contextSlice,
            transcriptMessages: transcriptForCache,
            cacheEntry: resolvedCacheEntry
        )
        let requestSystem = requestSystem(
            forSlice: contextSlice,
            cacheEntry: resolvedCacheEntry
        )

        do {
            let stream = try await streamingService.generate(
                messages: requestMessages,
                system: requestSystem
            )
            for try await chunk in stream {
                try Task.checkCancellation()
                guard isActiveResponseTask(responseTaskId) else { return }
                currentResponse += chunk
            }
            guard isActiveResponseTask(responseTaskId) else { return }
        } catch is CancellationError {
            return
        } catch {
            guard isActiveResponseTask(responseTaskId) else { return }
            // If a cached-content handle was attached, the server may have evicted the
            // cache before our local TTL. Drop the stale entry so the next turn rebuilds
            // instead of repeatedly failing against a dead handle.
            if resolvedCacheEntry != nil {
                geminiPromptCache.removeEntry(for: node.id)
            }
            currentResponse = "Error: \(error.localizedDescription)"
        }

        guard isActiveResponseTask(responseTaskId) else { return }
        let rawAssistantContent = currentResponse
        let assistantContent = ClarificationCardParser.stripChatTitle(from: rawAssistantContent)
        let conversationTitle = ChatViewModel.sanitizedConversationTitle(
            from: ClarificationCardParser.extractChatTitle(from: rawAssistantContent)
        )
        guard let committed = try? conversationSessionStore.commitAssistantTurn(
            nodeId: node.id,
            currentMessages: messages,
            assistantContent: assistantContent,
            conversationTitle: conversationTitle
        ) else { return }
        currentNode = committed.node
        messages = committed.messagesAfterAssistantAppend
        activeQuickActionMode = ChatViewModel.updatedQuickActionMode(
            currentMode: activeQuickActionMode,
            assistantContent: assistantContent
        )
        let completion = turnOutcomeFactory.makeCompletion(
            turnId: responseTaskId,
            nextQuickActionModeIfCompleted: activeQuickActionMode,
            committed: committed,
            assistantContent: assistantContent,
            stableSystem: contextSlice.stable
        )
        await contextContinuationService.run(completion.continuationPlan)
        turnHousekeepingService.run(completion.housekeepingPlan)
        currentResponse = ""
    }

    // MARK: - Send (RAG Pipeline)

    @MainActor
    func send(attachments: [AttachedFileContext] = []) async {
        guard (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty), !isGenerating else { return }

        let responseTaskId = UUID()
        inFlightResponseAbortReason = nil
        let responseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSend(attachments: attachments, responseTaskId: responseTaskId)
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
            activeChatMode = prepared.effectiveMode
            currentResponse = ""
            currentThinking = ""
            didHitBudgetExhaustion = false
        case .thinkingDelta(let delta):
            currentThinking.append(delta)
        case .textDelta(let delta):
            currentResponse.append(delta)
        case .completed(let completion):
            currentNode = completion.node
            messages = completion.messagesAfterAssistantAppend
            activeQuickActionMode = completion.nextQuickActionMode
            currentResponse = ""
            currentThinking = ""
            didHitBudgetExhaustion = false
        case .aborted(let reason):
            currentThinking = ""
            didHitBudgetExhaustion = false
            if reason == .unexpectedCancellation {
                presentAssistantFailure(
                    "Error: The reply was interrupted before it finished. Please try again."
                )
            }
        case .failed(let failure):
            currentThinking = ""
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

    // MARK: - Anchor (Core Identity)

    /// Loads the anchor document — Nous's immutable core identity and thinking methods.
    /// This is who Nous is. It does not change with context.
    nonisolated private static let anchor: String = {
        guard let url = Bundle.main.url(forResource: "anchor", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            print("[Nous] WARNING: anchor.md not found in bundle, using fallback")
            return "You are Nous, Alex 最信任嘅朋友。用广东话回应，语气好似同好朋友倾偈咁。Be warm, genuine, and direct."
        }
        print("[Nous] Anchor loaded: \(content.prefix(80))...")
        return content
    }()

    nonisolated private static let memoryInterpretationPolicy = """
    ---

    MEMORY INTERPRETATION POLICY:
    If you notice a personal pattern, state it as a hypothesis unless Alex clearly confirmed it or it is strongly supported across multiple moments.
    Prefer wording like: "I might be wrong, but...", "One hypothesis is...", "Does this fit, or is something else more true?"
    Do not present diagnoses or identity labels as certainty.
    """

    nonisolated private static let coreSafetyPolicy = """
    ---

    CORE SAFETY POLICY:
    Do not encourage Alex to become emotionally dependent on Nous.
    Do not present medical, psychological, or legal certainty when the situation is ambiguous.
    Respect memory boundaries: if Alex asks not to store something, or asked for consent before sensitive storage, do not silently turn that into durable memory.
    """

    nonisolated private static let stoicGroundingPolicy = """
    ---

    STOIC GROUNDING POLICY:
    Let Stoic thinking quietly shape your judgment, not your surface style.
    Help Alex separate what is in his control from what is not.
    Do not spend energy arguing with reality once something has already happened; focus on the next right move.
    When fear, anger, ego, or external pressure is driving the frame, name that plainly and return to facts, choices, and consequences.
    Bias toward steadiness, proportion, self-command, and aligned action.
    Keep this human and grounded. Do not sound like a philosophy book, do not quote Stoics unless Alex asks, and do not turn real emotion into cold detachment.
    """

    nonisolated private static let summaryOutputPolicy = """
    ---

    SUMMARY OUTPUT POLICY:
    When Alex asks you to summarize the current conversation (keywords and intents include "总结", "summarize", "repo", "做笔记", "summary", "整份笔记", or equivalents), wrap the summary body in <summary>…</summary>. Inside the tag, use four H2 sections in this order, followed by a bullet list:

      1. Problem / what triggered the discussion
      2. Thinking / the path the conversation took, including pivots
      3. Conclusion / consensus or decisions reached
      4. Next steps / short actionable bullets

    CRITICAL — match the conversation language for ALL of: the # title, the ## section headers, and the body prose. Do not translate to another language. Do not default to Mandarin. Use:
      - 广东话 section headers (问题 / 思考 / 结论 / 下一步) when Alex is writing in Cantonese.
      - 普通话 section headers (问题 / 思考 / 结论 / 下一步) when Alex is writing in Mandarin.
      - English section headers (Problem / Thinking / Conclusion / Next steps) when Alex is writing in English.
      - If Alex mixes Cantonese and English, prefer Cantonese headers with English kept verbatim inside the prose.

    Sections 1–3 must be narrative prose paragraphs, not bullet dumps. Section 4 is a short bullet list. The # title must contain no filename-unsafe characters (avoid /\\:*?"<>|) and should also follow the conversation language.

    Text outside the tag is allowed for a brief conversational wrapper in the same language (e.g. Cantonese: "整好了，睇下右边嘅白纸"; English: "Done, check the right panel."). The summary content itself must strictly live inside the tag. Never emit the tag when Alex is not asking for a summary.
    """

    nonisolated private static let conversationTitleOutputPolicy = """
    ---

    CONVERSATION TITLE POLICY:
    At the very end of every assistant reply, append exactly one hidden line in this format:
    <chat_title>short topic title here</chat_title>

    Rules:
    - This tag is hidden from Alex and is only used to label the chat.
    - Match the conversation language and dialect. Do not translate Cantonese into Mandarin.
    - Make it a concise topic label, not a full sentence, not a quote, and not a question.
    - No markdown, no emoji, no surrounding quotes, and no trailing punctuation.
    - Keep it specific. Good: "AI 时代仲要唔要生细路". Bad: "Actually you think that in the future..."
    - Prefer 2 to 6 words for spaced languages, or a short phrase for Chinese.
    - Put the tag on its own final line after all visible text, summary tags, or clarification blocks.
    """

    nonisolated private static let highRiskSafetyModeBlock = """
    ---

    HIGH-RISK SAFETY MODE:
    Alex may be describing imminent danger, self-harm, abuse, or another acute safety issue.
    Prioritize immediate safety, grounding, and real-world human support over abstract analysis.
    Be calm, direct, and practical.
    If he may be in immediate danger, encourage contacting local emergency services or a trusted nearby person right now.
    Do not romanticize self-destruction, isolation, or dependency.
    """

    nonisolated private static func activeChatModeBlock(_ chatMode: ChatMode) -> String {
        "---\n\nACTIVE CHAT MODE: \(chatMode.label)\n\(chatMode.contextBlock)"
    }

    // MARK: - Context Assembly

    nonisolated static func assembleContext(
        chatMode: ChatMode = .companion,
        currentUserInput: String? = nil,
        globalMemory: String?,
        essentialStory: String? = nil,
        userModel: UserModel? = nil,
        memoryEvidence: [MemoryEvidenceSnippet] = [],
        projectMemory: String?,
        conversationMemory: String?,
        recentConversations: [(title: String, memory: String)],
        citations: [SearchResult],
        projectGoal: String?,
        attachments: [AttachedFileContext] = [],
        activeQuickActionMode: QuickActionMode? = nil,
        allowInteractiveClarification: Bool = false,
        now: Date = Date()
    ) -> TurnSystemSlice {
        var stable: [String] = []
        var volatilePieces: [String] = []

        // Stable prefix: identity + policies + slow-changing memory layers. This is what
        // gets frozen into cachedContents.systemInstruction; any per-turn additions here
        // would invalidate the cache hash every request and defeat the whole point.
        stable.append(anchor)
        stable.append(memoryInterpretationPolicy)
        stable.append(coreSafetyPolicy)
        stable.append(stoicGroundingPolicy)
        stable.append(summaryOutputPolicy)
        stable.append(conversationTitleOutputPolicy)

        if let globalMemory, !globalMemory.isEmpty {
            stable.append("---\n\nLONG-TERM MEMORY ABOUT ALEX:\n\(globalMemory)")
        }

        if let essentialStory, !essentialStory.isEmpty {
            stable.append("---\n\nBROADER SITUATION RIGHT NOW:\n\(essentialStory)")
        }

        if let projectMemory, !projectMemory.isEmpty {
            stable.append("---\n\nTHIS PROJECT'S CONTEXT:\n\(projectMemory)")
        }

        if let conversationMemory, !conversationMemory.isEmpty {
            stable.append("---\n\nTHIS CHAT'S THREAD SO FAR:\n\(conversationMemory)")
        }

        if !memoryEvidence.isEmpty {
            stable.append("---\n\nSHORT SOURCE EVIDENCE FOR THE ABOVE MEMORY:")
            for evidence in memoryEvidence {
                stable.append("- \(evidence.label) · \"\(evidence.sourceTitle)\": \(evidence.snippet)")
            }
        }

        if let userModel,
           let promptBlock = userModel.promptBlock(includeIdentity: globalMemory?.isEmpty ?? true) {
            stable.append("---\n\nDERIVED USER MODEL:\n\(promptBlock)")
        }

        if let goal = projectGoal, !goal.isEmpty {
            stable.append("---\n\nCURRENT PROJECT GOAL: \(goal)")
        }

        if !recentConversations.isEmpty {
            stable.append("---\n\nRECENT CONVERSATIONS WITH ALEX:")
            for conversation in recentConversations {
                let snippet = String(conversation.memory.prefix(280))
                stable.append("\"\(conversation.title)\": \(snippet)")
            }
        }

        // Volatile: per-turn signals. The judge re-infers chat mode each turn, citations
        // come from fresh RAG, attachments are turn-specific, etc. Keeping these out of
        // the cache costs ~300 tokens/turn in re-send but keeps hit rate near 100%.
        volatilePieces.append(activeChatModeBlock(chatMode))

        if SafetyGuardrails.isHighRiskQuery(currentUserInput) {
            volatilePieces.append(highRiskSafetyModeBlock)
        }

        if !attachments.isEmpty {
            volatilePieces.append("---\n\nATTACHED FILES:")
            for attachment in attachments {
                if let extractedText = attachment.extractedText, !extractedText.isEmpty {
                    volatilePieces.append("FILE: \(attachment.name)\n\(extractedText)")
                } else {
                    volatilePieces.append("FILE: \(attachment.name)\nContent preview unavailable. Ask Alex for the relevant excerpt if more detail is needed.")
                }
            }
        }

        if !citations.isEmpty {
            volatilePieces.append("---\n\nRELEVANT KNOWLEDGE FROM ALEX'S NOTES AND CONVERSATIONS:")
            for (index, result) in citations.enumerated() {
                let percent = Int(result.similarity * 100)
                let snippet = result.surfacedSnippet
                let laneNote = result.lane == .longGap ? ", older cross-time connection" : ""
                volatilePieces.append("[\(index + 1)] \"\(result.node.title)\" (\(percent)% relevance\(laneNote)): \(snippet)")
            }
            volatilePieces.append("Reference the above when relevant. Cite by title. If knowledge contradicts something Alex said before, surface the tension.")
        }

        if let longGapGuidance = longGapConnectionGuidance(
            chatMode: chatMode,
            currentUserInput: currentUserInput,
            citations: citations,
            now: now
        ) {
            volatilePieces.append(longGapGuidance)
        }

        if let activeQuickActionMode {
            volatilePieces.append("ACTIVE QUICK MODE: \(activeQuickActionMode.label)")
        }

        if allowInteractiveClarification {
            volatilePieces.append(
                """
                ---

                INTERACTIVE CLARIFICATION UI:
                You are in the understanding phase of a quick mode.
                While you are still understanding and have not started giving real guidance yet, include this exact hidden marker anywhere in your response:
                <phase>understanding</phase>
                This marker will not be shown to Alex.
                If one missing detail blocks a useful answer, you may ask a short clarification question using this exact format:
                <clarify>
                <question>One short question here</question>
                <option>First option</option>
                <option>Second option</option>
                <option>Third option</option>
                <option>Fourth option</option>
                </clarify>

                Rules:
                - Use this only while you are still understanding Alex's situation in the active quick mode.
                - Keep using the hidden understanding marker while you are still gathering context, even if you ask a normal text question instead of a card.
                - You may ask at most one clarification follow-up after Alex's first reply in the quick mode.
                - If you already asked one follow-up in this quick mode, stop clarifying and give the best real guidance you can with the available context.
                - Ask for one missing distinction at a time.
                - Use 2 to 4 options only.
                - Keep each option short, concrete, and directly clickable.
                - Put any normal explanation outside the clarify block.
                - If discrete options would be misleading, ask a normal question instead.
                - The moment you have enough context to give real guidance, stop using the hidden marker, stop using the clarify block, and answer normally.
                - Do not drag out clarification if you can already give a useful response.
                """
            )
        }

        return TurnSystemSlice(
            stable: stable.joined(separator: "\n\n"),
            volatile: volatilePieces.joined(separator: "\n\n")
        )
    }

    nonisolated static func governanceTrace(
        chatMode: ChatMode = .companion,
        currentUserInput: String? = nil,
        globalMemory: String?,
        essentialStory: String? = nil,
        userModel: UserModel? = nil,
        memoryEvidence: [MemoryEvidenceSnippet] = [],
        projectMemory: String?,
        conversationMemory: String?,
        recentConversations: [(title: String, memory: String)],
        citations: [SearchResult],
        projectGoal: String?,
        attachments: [AttachedFileContext] = [],
        activeQuickActionMode: QuickActionMode? = nil,
        allowInteractiveClarification: Bool = false,
        now: Date = Date()
    ) -> PromptGovernanceTrace {
        var layers = ["anchor", "memory_interpretation_policy", "core_safety_policy", "stoic_grounding_policy", "summary_output_policy", "conversation_title_output_policy", "chat_mode"]
        let highRiskQueryDetected = SafetyGuardrails.isHighRiskQuery(currentUserInput)

        if let globalMemory, !globalMemory.isEmpty { layers.append("global_memory") }
        if let essentialStory, !essentialStory.isEmpty { layers.append("essential_story") }
        if let projectMemory, !projectMemory.isEmpty { layers.append("project_memory") }
        if let conversationMemory, !conversationMemory.isEmpty { layers.append("conversation_memory") }
        if !memoryEvidence.isEmpty { layers.append("memory_evidence") }
        if let userModel, !userModel.isEmpty { layers.append("user_model") }
        if let projectGoal, !projectGoal.isEmpty { layers.append("project_goal") }
        if !recentConversations.isEmpty { layers.append("recent_conversations") }
        if !attachments.isEmpty { layers.append("attachments") }
        if !citations.isEmpty { layers.append("citations") }
        if longGapConnectionGuidance(
            chatMode: chatMode,
            currentUserInput: currentUserInput,
            citations: citations,
            now: now
        ) != nil {
            layers.append("long_gap_bridge_guidance")
        }
        if activeQuickActionMode != nil { layers.append("quick_action_mode") }
        if allowInteractiveClarification { layers.append("interactive_clarification") }
        if chatMode == .strategist { layers.append("strategist_mode") }
        if highRiskQueryDetected { layers.append("high_risk_safety_mode") }

        return PromptGovernanceTrace(
            promptLayers: layers,
            evidenceAttached: !memoryEvidence.isEmpty,
            safetyPolicyInvoked: highRiskQueryDetected,
            highRiskQueryDetected: highRiskQueryDetected
        )
    }

    nonisolated private static func longGapConnectionGuidance(
        chatMode: ChatMode,
        currentUserInput: String?,
        citations: [SearchResult],
        now: Date
    ) -> String? {
        guard !SafetyGuardrails.isHighRiskQuery(currentUserInput) else { return nil }
        guard let candidate = preferredLongGapBridgeCitation(citations: citations, now: now) else { return nil }

        let snippet = String(candidate.surfacedSnippet.prefix(220))
        let modeSpecificRule: String

        switch chatMode {
        case .companion:
            modeSpecificRule = "- Keep it gentle and hypothesis-led. Use language like \"might\", \"seems\", or \"could be\"."
        case .strategist:
            modeSpecificRule = "- Name the line directly and clearly. Prioritize precision over cushioning, but do not sound prosecutorial or therapeutic."
        }

        return """
        ---

        LONG-GAP CONNECTION CUE:
        One retrieved source may matter here as an older cross-time connection:
        "\(candidate.node.title)": \(snippet)

        Use this only if it deepens the answer.
        If you use it:
        - Add at most one short bridge sentence.
        - Explain why that earlier moment matters now.
        - Focus on movement, tension, or progression across time, not on catching Alex being inconsistent.
        - Do not mention retrieval, citations, similarity scores, dates, percentages, or the phrase "long-gap".
        - If the answer already works without this connection, leave it out.
        - Do not stack multiple older threads in one reply.
        \(modeSpecificRule)
        """
    }

    nonisolated private static func preferredLongGapBridgeCitation(
        citations: [SearchResult],
        now: Date
    ) -> SearchResult? {
        citations.first {
            $0.lane == .longGap &&
            $0.similarity >= 0.62 &&
            ageDays(since: $0.node.createdAt, now: now) >= 45
        }
    }

    nonisolated private static func ageDays(since createdAt: Date, now: Date) -> Int {
        let elapsed = max(0, now.timeIntervalSince(createdAt))
        return Int(elapsed / 86_400)
    }

    nonisolated private static func sanitizedConversationTitle(from raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }

        title = title
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        while title.contains("  ") {
            title = title.replacingOccurrences(of: "  ", with: " ")
        }

        while let first = title.first, first == "#" || first == "-" || first == "*" || first.isWhitespace {
            title.removeFirst()
        }

        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’"))
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:。！？、，；："))

        let filteredScalars = title.unicodeScalars.filter { scalar in
            !CharacterSet(charactersIn: "<>|/\\").contains(scalar)
        }
        title = String(String.UnicodeScalarView(filteredScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if title.count > 48 {
            title = String(title.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return title.isEmpty ? nil : title
    }

    nonisolated static func updatedQuickActionMode(
        currentMode: QuickActionMode?,
        assistantContent: String
    ) -> QuickActionMode? {
        guard let currentMode else { return nil }
        let parsed = ClarificationCardParser.parse(assistantContent)
        return parsed.keepsQuickActionMode ? currentMode : nil
    }

    nonisolated static func shouldAllowInteractiveClarification(
        activeQuickActionMode: QuickActionMode?,
        messages: [Message]
    ) -> Bool {
        guard activeQuickActionMode != nil else { return false }
        let userTurnCount = messages.lazy.filter { $0.role == .user }.count
        return userTurnCount <= 1
    }

    /// Static so it can be unit-tested without spinning up the full view model.
    /// Stamped onto verdictJSON by the send flow before the verdict is encoded;
    /// do not call from additional sites or persisted verdictJSON content
    /// becomes non-deterministic.
    nonisolated static func deriveProvocationKind(
        verdict: JudgeVerdict,
        contradictionCandidateIds: Set<String>
    ) -> ProvocationKind {
        guard verdict.shouldProvoke else { return .neutral }
        if let id = verdict.entryId, contradictionCandidateIds.contains(id) {
            return .contradiction
        }
        return .spark
    }

    nonisolated static func quickActionOpeningPrompt(for mode: QuickActionMode) -> String {
        """
        Alex just entered the \(mode.label) mode from the welcome screen.
        Start the conversation yourself instead of waiting for him to type.
        This is only the opening turn, so do not use the clarification card yet.
        Ask one short, natural, open-ended question first so you can understand his situation.
        Start your reply with this hidden marker so the mode stays in understanding phase:
        <phase>understanding</phase>
        Ask one short, warm opening question that helps you understand his situation.
        Do not mention hidden prompts, modes, system instructions, or formatting rules.
        """
    }

    /// Attaches the resolved cache handle to the Gemini service. When the handle is
    /// `nil`, returns the service unchanged so the full system + transcript goes through
    /// the normal request path.
    @MainActor
    private func configuredGeminiService(
        from llm: any LLMService,
        cacheEntry: GeminiConversationCacheEntry?
    ) -> any LLMService {
        guard var gemini = llm as? GeminiLLMService, let entry = cacheEntry else { return llm }
        gemini.cachedContentName = entry.name
        return gemini
    }

    /// Builds the `contents` array for a single turn. With an active cache the server
    /// already has the transcript prefix + stable system, so we send just the current
    /// user message — with the volatile block prepended so per-turn signals (chat mode,
    /// citations, quick-action label, etc.) still reach the model.
    @MainActor
    private func requestMessages(
        forSlice slice: TurnSystemSlice,
        transcriptMessages: [LLMMessage],
        cacheEntry: GeminiConversationCacheEntry?
    ) -> [LLMMessage] {
        guard cacheEntry != nil,
              let latestMessage = transcriptMessages.last,
              latestMessage.role == "user" else {
            return transcriptMessages
        }

        let prefixedContent = ChatViewModel.prefixedUserMessageContent(
            volatile: slice.volatile,
            userContent: latestMessage.content
        )
        return [LLMMessage(role: "user", content: prefixedContent)]
    }

    /// When the cache is active, Gemini rejects a request that also supplies a
    /// `systemInstruction` (it's locked into the cache). Return nil in that case; the
    /// volatile block is carried via the prepended user message content instead.
    @MainActor
    private func requestSystem(
        forSlice slice: TurnSystemSlice,
        cacheEntry: GeminiConversationCacheEntry?
    ) -> String? {
        if cacheEntry != nil { return nil }
        return slice.combined
    }

    /// Looks up a valid cache entry for this conversation by hashing the stable system
    /// and the transcript prefix (everything except the current user turn). Separated
    /// from `configuredGeminiService` + `requestMessages` + `requestSystem` so callers
    /// resolve the entry exactly once per turn and thread it through — the previous
    /// implementation recomputed the SHA256 three times per send.
    @MainActor
    private func activeGeminiHistoryCache(
        nodeId: UUID,
        llm: any LLMService,
        stableSystem: String,
        transcriptMessages: [LLMMessage]
    ) -> GeminiConversationCacheEntry? {
        guard shouldUseGeminiHistoryCache() else {
            turnHousekeepingService.clearGeminiHistoryCacheIfPresent(nodeId: nodeId, llm: llm)
            return nil
        }
        guard let gemini = llm as? GeminiLLMService else { return nil }
        guard transcriptMessages.count >= 2 else { return nil }
        let prefixHash = GeminiPromptCacheService.promptHash(
            system: stableSystem,
            messages: Array(transcriptMessages.dropLast())
        )
        return geminiPromptCache.activeCache(for: nodeId, model: gemini.model, promptHash: prefixHash)
    }

    nonisolated static func prefixedUserMessageContent(volatile: String, userContent: String) -> String {
        guard !volatile.isEmpty else { return userContent }
        return """
        <turn-context>
        \(volatile)
        </turn-context>

        \(userContent)
        """
    }

    @MainActor
    private func configuredStreamingService(
        from llm: any LLMService,
        responseTaskId: UUID,
        captureThinking: Bool
    ) -> any LLMService {
        if var gemini = llm as? GeminiLLMService {
            gemini.onUsageMetadata = { [weak self] usage in
                guard let self, self.isActiveResponseTask(responseTaskId) else { return }
                self.governanceTelemetry.recordGeminiUsage(usage)
            }

            guard captureThinking else { return gemini }

            gemini.thinkingBudgetTokens = 2000
            // @MainActor closures: the producer `await`s these, so writes land in
            // parse order and are visible to the post-stream budget-exhaust check below.
            gemini.onThinkingDelta = { [weak self] delta in
                guard let self, self.isActiveResponseTask(responseTaskId) else { return }
                self.currentThinking.append(delta)
            }
            gemini.onBudgetExhausted = { [weak self] in
                guard let self, self.isActiveResponseTask(responseTaskId) else { return }
                self.didHitBudgetExhaustion = true
            }
            return gemini
        }

        guard captureThinking else { return llm }

        if var claude = llm as? ClaudeLLMService {
            claude.thinkingBudgetTokens = 1024
            claude.onThinkingDelta = { [weak self] delta in
                guard let self, self.isActiveResponseTask(responseTaskId) else { return }
                self.currentThinking.append(delta)
            }
            return claude
        }

        if var openRouter = llm as? OpenRouterLLMService {
            openRouter.reasoningBudgetTokens = 1024
            openRouter.onThinkingDelta = { [weak self] delta in
                guard let self, self.isActiveResponseTask(responseTaskId) else { return }
                self.currentThinking.append(delta)
            }
            return openRouter
        }

        return llm
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
