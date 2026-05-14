import Foundation
import Observation

@Observable
@MainActor
final class ChatViewModel {

    // MARK: - State

    var currentNode: NousNode?
    var messages: [Message] = []
    var inputText: String = ""
    @ObservationIgnored private(set) var currentStreamingSession: ConversationStreamingSession?
    var isGenerating: Bool {
        get { currentStreamingSession?.isGenerating ?? false }
        set { currentStreamingSession?.isGenerating = newValue }
    }
    var currentResponse: String {
        get { currentStreamingSession?.currentResponse ?? "" }
        set { currentStreamingSession?.currentResponse = newValue }
    }
    var currentThinking: String {
        get { currentStreamingSession?.currentThinking ?? "" }
        set { currentStreamingSession?.currentThinking = newValue }
    }
    var currentThinkingStartedAt: Date? {
        get { currentStreamingSession?.currentThinkingStartedAt }
        set { currentStreamingSession?.currentThinkingStartedAt = newValue }
    }
    var currentAgentTrace: [AgentTraceRecord] {
        get { currentStreamingSession?.currentAgentTrace ?? [] }
        set { currentStreamingSession?.currentAgentTrace = newValue }
    }
    var didHitBudgetExhaustion: Bool {
        get { currentStreamingSession?.didHitBudgetExhaustion ?? false }
        set { currentStreamingSession?.didHitBudgetExhaustion = newValue }
    }
    var citations: [SearchResult] = []
    /// Block 4b Phase 1A — atom + reflection cards paired with their resolved
    /// source nodes. Populated alongside `citations` from `TurnPrepared`.
    /// Phase 1B reads this through `primaryAttribution` to drive the chip
    /// cascade behind `FeatureFlags.atomCardsEnabled`.
    var resolvedCorpusEntries: [ResolvedCitableEntry] = []

    /// Attribution chips are hidden by product decision — retrieval still
    /// runs in background and feeds the model, but the chip area never
    /// surfaces in the UI. Cascade logic is preserved in `AttributionDisplay`
    /// for future reintroduction (e.g. once the trust contract from Phase 2
    /// guarantees chip = "model used" rather than "retrieved").
    var primaryAttribution: AttributionDisplay { .none }

    var activeQuickActionMode: QuickActionMode?
    var activeChatMode: ChatMode? = nil
    var activeSourceDiscussionContext: SourceDiscussionContext?
    var defaultProjectId: UUID?
    var lastPromptGovernanceTrace: PromptGovernanceTrace?
    private var judgeFeedbackVersion: Int = 0
    @ObservationIgnored private var pendingSourceMaterialsByTurnId: [UUID: [SourceMaterialContext]] = [:]
    @ObservationIgnored private var pendingSourceDiscussionContextByTurnId: [UUID: SourceDiscussionContext] = [:]
    @ObservationIgnored private var sourceMaterialsByUserMessageId: [UUID: [SourceMaterialContext]] = [:]
    @ObservationIgnored private var sourceBriefingsByUserMessageId: [UUID: SourceBriefing] = [:]

    // MARK: - Dependencies

    private let nodeStore: NodeStore
    private let vectorStore: VectorStore
    private let embeddingService: EmbeddingService
    private let graphEngine: GraphEngine
    private let relationRefinementQueue: GalaxyRelationRefinementQueue?
    private let userMemoryService: UserMemoryService
    private let userMemoryScheduler: UserMemoryScheduler
    private let sourceLearningMemoryScheduler: SourceLearningMemoryScheduler?
    private let conversationSessionStore: ConversationSessionStore
    @ObservationIgnored private let explicitTurnRunner: ChatTurnRunner?
    @ObservationIgnored private let explicitTurnPlanner: TurnPlanner?
    @ObservationIgnored private let explicitTurnExecutor: TurnExecutor?
    @ObservationIgnored private let explicitContextContinuationService: ContextContinuationService?
    @ObservationIgnored private let explicitTurnHousekeepingService: TurnHousekeepingService?
    @ObservationIgnored private let explicitSourceIngestionService: SourceIngestionService?
    @ObservationIgnored private let sourceBriefingService: SourceBriefingService?
    private let llmServiceProvider: () -> (any LLMService)?
    private let currentProviderProvider: () -> LLMProvider
    private let judgeLLMServiceFactory: () -> (any LLMService)?
    private let provocationJudgeFactory: (any LLMService) -> any Judging
    private let skillStore: SkillStore?
    private let skillMatcher: SkillMatcher?
    private let skillTracker: SkillTracker?
    private let skillDogfoodLogger: (any SkillDogfoodLogging)?
    private let failureSkillCandidateStore: FailureSkillCandidateStore?
    /// Stored as a typed `Task<JudgeVerdict, Error>` — not `Task<Void, …>` — so tests can
    /// `await task.value` and inspect the verdict directly. The slot is guarded on clear:
    /// a later `send()` may have already overwritten it with a new task ID, so only the task
    /// that still owns the slot clears it (see `inFlightJudgeTaskId` guard in `send()`).
    @ObservationIgnored nonisolated(unsafe) private var inFlightJudgeTask: Task<JudgeVerdict, Error>?
    @ObservationIgnored nonisolated(unsafe) private var inFlightJudgeTaskId: UUID?
    private var inFlightResponseTask: Task<Void, Never>? {
        get { currentStreamingSession?.inFlightTask }
        set { currentStreamingSession?.inFlightTask = newValue }
    }

    private var inFlightResponseTaskId: UUID? {
        get { currentStreamingSession?.inFlightTurnId }
        set { currentStreamingSession?.inFlightTurnId = newValue }
    }

    private var inFlightResponseAbortReason: TurnAbortReason? {
        get { currentStreamingSession?.inFlightAbortReason }
        set { currentStreamingSession?.inFlightAbortReason = newValue }
    }
    private let governanceTelemetry: GovernanceTelemetryStore
    private let geminiPromptCache: GeminiPromptCacheService
    private let scratchPadStore: ScratchPadStore
    private let shadowLearningSignalRecorder: ShadowLearningSignalRecorder?
    private let shadowPatternPromptProvider: (any ShadowPatternPromptProviding)?
    private let slowCognitionArtifactProvider: (any SlowCognitionArtifactProviding)?
    private let heartbeatCoordinator: HeartbeatCoordinator?
    private let shouldUseGeminiHistoryCache: () -> Bool
    private let shouldPersistAssistantThinking: () -> Bool
    /// Factory for the manual `/reflect` command. Returns `nil` when the
    /// Gemini API key is unset; the command then surfaces a configuration
    /// hint instead of attempting an LLM call.
    private let perConversationReflectionServiceFactory: () -> PerConversationReflectionService?
    @ObservationIgnored private var cachedTurnPlanner: TurnPlanner?
    @ObservationIgnored private var cachedTurnExecutor: TurnExecutor?
    @ObservationIgnored private var cachedQuickActionOpeningRunner: QuickActionOpeningRunner?
    @ObservationIgnored private var cachedContextContinuationService: ContextContinuationService?
    @ObservationIgnored private var cachedTurnHousekeepingService: TurnHousekeepingService?
    @ObservationIgnored private var cachedSourceIngestionService: SourceIngestionService?

    /// Phase A chat citation trace + feedback stores. Built lazily off
    /// the shared NodeStore. The emitter writes one telemetry row per
    /// candidate atom on each `.completed` turn event; the feedback
    /// store is exposed so `CorpusAtomCardListView` can mount per-row
    /// thumb feedback.
    @ObservationIgnored private lazy var citationTraceEmitter = CitationTraceEmitter(
        traceStore: CitationJudgeTraceStore(nodeStore: nodeStore)
    )
    @ObservationIgnored lazy var citationFeedbackStore = CitationFeedbackStore(nodeStore: nodeStore)
    private var memoryProjectionService: MemoryProjectionService {
        userMemoryService.projectionReader
    }
    private var turnOutcomeFactory: TurnOutcomeFactory {
        let projectionService = memoryProjectionService
        return TurnOutcomeFactory(
            memoryPersistenceDecision: { messages, projectId in
                projectionService.memoryPersistenceDecision(messages: messages, projectId: projectId)
            }
        )
    }
    private var turnRunner: ChatTurnRunner {
        if let explicitTurnRunner {
            return explicitTurnRunner
        }

        return ChatTurnRunner(
            conversationSessionStore: conversationSessionStore,
            turnSteward: TurnSteward(
                skillStore: skillStore,
                currentProviderProvider: currentProviderProvider,
                llmServiceProvider: llmServiceProvider
            ),
            turnPlanner: turnPlanner,
            turnExecutor: turnExecutor,
            agentLoopExecutorFactory: { [weak self] mode, _, _ in
                guard let self,
                      ModelHarnessProfileCatalog.profile(for: self.currentProviderProvider()).supportsAgentToolUse,
                      let llm = self.llmServiceProvider() else {
                    return nil
                }

                let toolLLM: any ToolCallingLLMService
                if var openRouter = llm as? OpenRouterLLMService {
                    openRouter.reasoningBudgetTokens = ModelHarnessProfileCatalog.thinkingBudgetTokens(for: .openrouter)
                    toolLLM = openRouter
                } else if let candidate = llm as? any ToolCallingLLMService {
                    toolLLM = candidate
                } else {
                    return nil
                }

                guard toolLLM.supportsAgentToolUse else { return nil }

                let registry = AgentToolRegistry
                    .standard(
                        nodeStore: self.nodeStore,
                        vectorStore: self.vectorStore,
                        embeddingService: self.embeddingService,
                        contradictionProvider: self.userMemoryService.contradictionReader,
                        skillStore: self.skillStore
                    )
                    .subset(mode.agent().toolNames)
                return AgentLoopExecutor(
                    llmService: toolLLM,
                    registry: registry,
                    shouldPersistAssistantThinking: self.shouldPersistAssistantThinking
                )
            },
            outcomeFactory: turnOutcomeFactory,
            shadowLearningSignalRecorder: shadowLearningSignalRecorder,
            cognitionReviewer: CognitionReviewer(),
            failureSkillCandidateStore: failureSkillCandidateStore,
            shouldSurfaceThinkingTraces: shouldPersistAssistantThinking,
            onPlanReady: { [governanceTelemetry] plan in
                governanceTelemetry.recordPromptTrace(plan.promptTrace)
                if let event = plan.judgeEventDraft {
                    governanceTelemetry.appendJudgeEvent(event)
                }
            },
            onReviewArtifact: { [governanceTelemetry] artifact in
                governanceTelemetry.recordCognitionArtifact(artifact)
            },
            onTurnCognitionSnapshot: { [governanceTelemetry] snapshot in
                governanceTelemetry.recordTurnCognitionSnapshot(snapshot)
            },
            onContextManifest: { [governanceTelemetry] record in
                governanceTelemetry.recordContextManifest(record)
            },
            onCorpusFidelity: { [governanceTelemetry] record in
                governanceTelemetry.recordCorpusFidelity(record)
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
            sourceBriefingService: sourceBriefingService,
            provocationJudgeFactory: provocationJudgeFactory,
            governanceTelemetry: governanceTelemetry,
            skillStore: skillStore,
            skillMatcher: skillMatcher ?? SkillMatcher(),
            skillTracker: skillTracker,
            skillDogfoodLogger: skillDogfoodLogger,
            shadowPatternPromptProvider: shadowPatternPromptProvider,
            slowCognitionArtifactProvider: slowCognitionArtifactProvider,
            agentLoopProviderSupportsToolUse: { [weak self] provider in
                guard ModelHarnessProfileCatalog.profile(for: provider).supportsAgentToolUse,
                      let llm = self?.llmServiceProvider()
                else { return false }

                if let openRouter = llm as? OpenRouterLLMService {
                    return openRouter.supportsAgentToolUse
                }

                return (llm as? any ToolCallingLLMService)?.supportsAgentToolUse ?? false
            },
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
            },
            recordTurnInferenceTelemetry: { [governanceTelemetry] record in
                governanceTelemetry.recordTurnInferenceTelemetry(record)
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
            skillDogfoodLogger: skillDogfoodLogger,
            cognitionReviewer: CognitionReviewer(),
            shouldSurfaceThinkingTraces: shouldPersistAssistantThinking,
            onPlanReady: { [governanceTelemetry] plan in
                governanceTelemetry.recordPromptTrace(plan.promptTrace)
            },
            onReviewArtifact: { [governanceTelemetry] artifact in
                governanceTelemetry.recordCognitionArtifact(artifact)
            },
            onTurnCognitionSnapshot: { [governanceTelemetry] snapshot in
                governanceTelemetry.recordTurnCognitionSnapshot(snapshot)
            },
            onContextManifest: { [governanceTelemetry] record in
                governanceTelemetry.recordContextManifest(record)
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

        let autoTrigger = PerConversationReflectionAutoTrigger(
            nodeStore: nodeStore,
            serviceFactory: perConversationReflectionServiceFactory
        )
        let service = ContextContinuationService(
            scratchPadStore: scratchPadStore,
            userMemoryScheduler: userMemoryScheduler,
            governanceTelemetry: governanceTelemetry,
            perConversationReflectionAutoTrigger: autoTrigger,
            sourceLearningScheduler: sourceLearningMemoryScheduler
        )
        cachedContextContinuationService = service
        return service
    }
    private var sourceIngestionService: SourceIngestionService {
        if let explicitSourceIngestionService {
            return explicitSourceIngestionService
        }
        if let cachedSourceIngestionService {
            return cachedSourceIngestionService
        }

        let service = SourceIngestionService(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingProvider: embeddingService,
            onSourceNodeIngested: { [weak self] node in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? self.graphEngine.regenerateEdges(for: node)
                    self.relationRefinementQueue?.enqueue(nodeId: node.id)
                }
            }
        )
        cachedSourceIngestionService = service
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
                self.bindStreamingSession(for: refreshedNode)
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
        sourceLearningMemoryScheduler: SourceLearningMemoryScheduler? = nil,
        conversationSessionStore: ConversationSessionStore? = nil,
        turnRunner: ChatTurnRunner? = nil,
        turnPlanner: TurnPlanner? = nil,
        turnExecutor: TurnExecutor? = nil,
        contextContinuationService: ContextContinuationService? = nil,
        turnHousekeepingService: TurnHousekeepingService? = nil,
        sourceIngestionService: SourceIngestionService? = nil,
        sourceBriefingService: SourceBriefingService? = nil,
        llmServiceProvider: @escaping () -> (any LLMService)?,
        currentProviderProvider: @escaping () -> LLMProvider,
        judgeLLMServiceFactory: @escaping () -> (any LLMService)?,
        provocationJudgeFactory: @escaping (any LLMService) -> any Judging = { ProvocationJudge(llmService: $0) },
        skillStore: SkillStore? = nil,
        skillMatcher: SkillMatcher? = nil,
        skillTracker: SkillTracker? = nil,
        skillDogfoodLogger: (any SkillDogfoodLogging)? = nil,
        failureSkillCandidateStore: FailureSkillCandidateStore? = nil,
        governanceTelemetry: GovernanceTelemetryStore = GovernanceTelemetryStore(),
        geminiPromptCache: GeminiPromptCacheService = GeminiPromptCacheService(),
        scratchPadStore: ScratchPadStore,
        shadowLearningSignalRecorder: ShadowLearningSignalRecorder? = nil,
        shadowPatternPromptProvider: (any ShadowPatternPromptProviding)? = nil,
        slowCognitionArtifactProvider: (any SlowCognitionArtifactProviding)? = nil,
        heartbeatCoordinator: HeartbeatCoordinator? = nil,
        shouldUseGeminiHistoryCache: @escaping () -> Bool = { true },
        shouldPersistAssistantThinking: @escaping () -> Bool = { true },
        perConversationReflectionServiceFactory: @escaping () -> PerConversationReflectionService? = { nil },
        defaultProjectId: UUID? = nil
    ) {
        self.nodeStore = nodeStore
        self.vectorStore = vectorStore
        self.embeddingService = embeddingService
        self.graphEngine = graphEngine
        self.relationRefinementQueue = relationRefinementQueue
        self.userMemoryService = userMemoryService
        self.userMemoryScheduler = userMemoryScheduler
        self.sourceLearningMemoryScheduler = sourceLearningMemoryScheduler
        self.conversationSessionStore = conversationSessionStore ?? ConversationSessionStore(
            nodeStore: nodeStore,
            telemetry: governanceTelemetry
        )
        self.llmServiceProvider = llmServiceProvider
        self.currentProviderProvider = currentProviderProvider
        self.judgeLLMServiceFactory = judgeLLMServiceFactory
        self.provocationJudgeFactory = provocationJudgeFactory
        self.skillStore = skillStore
        self.skillMatcher = skillMatcher
        self.skillTracker = skillTracker
        self.skillDogfoodLogger = skillDogfoodLogger
        self.failureSkillCandidateStore = failureSkillCandidateStore
        self.governanceTelemetry = governanceTelemetry
        self.geminiPromptCache = geminiPromptCache
        self.scratchPadStore = scratchPadStore
        self.shadowLearningSignalRecorder = shadowLearningSignalRecorder
        self.shadowPatternPromptProvider = shadowPatternPromptProvider
        self.slowCognitionArtifactProvider = slowCognitionArtifactProvider
        self.heartbeatCoordinator = heartbeatCoordinator
        self.shouldUseGeminiHistoryCache = shouldUseGeminiHistoryCache
        self.shouldPersistAssistantThinking = shouldPersistAssistantThinking
        self.perConversationReflectionServiceFactory = perConversationReflectionServiceFactory
        self.defaultProjectId = defaultProjectId
        self.explicitTurnRunner = turnRunner
        self.explicitTurnPlanner = turnPlanner
        self.explicitTurnExecutor = turnExecutor
        self.explicitContextContinuationService = contextContinuationService
        self.explicitTurnHousekeepingService = turnHousekeepingService
        self.explicitSourceIngestionService = sourceIngestionService
        self.sourceBriefingService = sourceBriefingService
    }

    // MARK: - Conversation Management

    @MainActor
    func startBlankConversation(cancelInFlightWork: Bool = true) {
        if cancelInFlightWork {
            cancelInFlightResponse(clearDraft: true, reason: .supersededByNewTurn)
            cancelInFlightJudge()
        }
        currentNode = nil
        activeSourceDiscussionContext = nil
        scratchPadStore.activate(conversationId: nil)
        messages = []
        citations = []
        resolvedCorpusEntries = []
        currentResponse = ""
        currentThinking = ""
        currentThinkingStartedAt = nil
        currentAgentTrace = []
        didHitBudgetExhaustion = false
        inputText = ""
        activeQuickActionMode = nil
        activeChatMode = nil
        lastPromptGovernanceTrace = nil
        pendingSourceMaterialsByTurnId.removeAll()
        pendingSourceDiscussionContextByTurnId.removeAll()
        sourceMaterialsByUserMessageId.removeAll()
        sourceBriefingsByUserMessageId.removeAll()
    }

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
        bindStreamingSession(for: node)
        scratchPadStore.activate(conversationId: node.id)
        messages = []
        citations = []
        resolvedCorpusEntries = []
        currentResponse = ""
        currentThinking = ""
        currentThinkingStartedAt = nil
        currentAgentTrace = []
        didHitBudgetExhaustion = false
        activeQuickActionMode = nil
        activeChatMode = nil  // brand-new chat has no prior judgment
        lastPromptGovernanceTrace = nil
        activeSourceDiscussionContext = nil
        pendingSourceMaterialsByTurnId.removeAll()
        pendingSourceDiscussionContextByTurnId.removeAll()
        sourceMaterialsByUserMessageId.removeAll()
        sourceBriefingsByUserMessageId.removeAll()
    }

    @MainActor
    func loadConversation(_ node: NousNode, cancelInFlightWork: Bool = false) {
        if cancelInFlightWork {
            cancelInFlightResponse(clearDraft: true, reason: .conversationSwitched)
        }
        cancelInFlightJudge()  // judges are conversation-scoped; always invalidate on switch
        currentNode = node
        bindStreamingSession(for: node)
        if let surfacedError = currentStreamingSession?.markViewed() {
            NSLog("[NousTurn] background turn error surfaced on conversation enter: %@",
                  String(describing: surfacedError))
        }
        scratchPadStore.activate(conversationId: node.id)
        messages = (try? nodeStore.fetchMessages(nodeId: node.id)) ?? []
        citations = []
        resolvedCorpusEntries = []
        activeQuickActionMode = nil
        activeChatMode = (try? nodeStore.latestChatMode(forNode: node.id)) ?? nil
        activeSourceDiscussionContext = nil
        pendingSourceMaterialsByTurnId.removeAll()
        pendingSourceDiscussionContextByTurnId.removeAll()
        sourceMaterialsByUserMessageId.removeAll()
        sourceBriefingsByUserMessageId.removeAll()
        cacheSourceMaterialsForLoadedMessages()
        cacheSourceBriefingsForLoadedMessages()
    }

    func activateSourceDiscussion(_ context: SourceDiscussionContext) {
        activeSourceDiscussionContext = context
    }

    func clearSourceDiscussion() {
        activeSourceDiscussionContext = nil
    }

    func sourceMaterials(for message: Message) -> [SourceMaterialContext] {
        guard message.role == .user else { return [] }
        if let materials = sourceMaterialsByUserMessageId[message.id] {
            return materials
        }
        let materials = (try? nodeStore.fetchMessageSourceMaterials(messageId: message.id)) ?? []
        sourceMaterialsByUserMessageId[message.id] = materials
        return materials
    }

    func sourceBriefing(for message: Message) -> SourceBriefing? {
        guard message.role == .user else { return nil }
        if let briefing = sourceBriefingsByUserMessageId[message.id] {
            return briefing.items.isEmpty ? nil : briefing
        }
        let briefing = (try? nodeStore.fetchSourceBriefing(messageId: message.id)) ?? .empty
        sourceBriefingsByUserMessageId[message.id] = briefing
        return briefing.items.isEmpty ? nil : briefing
    }

    /// Bind the streaming session that backs the forwarded streaming
    /// properties (`isGenerating`, `currentResponse`, `currentThinking`,
    /// ...). Must be called immediately after every assignment to
    /// `currentNode`; without it, the forwarded setters silently no-op
    /// against a nil session. See Task 4 (cross-window streaming).
    ///
    /// When this rebinds the session mid-turn (e.g. the recovery path
    /// in `runSend` swaps the missing/restored node for a freshly-created
    /// one inside `.userMessageAppended`), the in-flight task slots are
    /// migrated to the new session so `isActiveResponseTask` continues
    /// to recognize the running turn after the rebind.
    @MainActor
    private func bindStreamingSession(for node: NousNode) {
        let newSession = conversationSessionStore.streamingSession(for: node.id)
        if let previous = currentStreamingSession,
           previous !== newSession,
           let turnId = previous.inFlightTurnId {
            newSession.inFlightTurnId = turnId
            newSession.inFlightTask = previous.inFlightTask
            newSession.inFlightAbortReason = previous.inFlightAbortReason
            previous.inFlightTurnId = nil
            previous.inFlightTask = nil
            previous.inFlightAbortReason = nil
        }
        currentStreamingSession = newSession
    }

    func activateQuickActionMode(_ mode: QuickActionMode) {
        activeQuickActionMode = mode
    }

    @MainActor
    func beginQuickActionConversation(_ mode: QuickActionMode) async {
        guard !isGenerating else { return }

        // Pre-create the conversation at the spawn site so the in-flight
        // task slot writes below land on a bound streaming session. Quick
        // actions always start a fresh conversation, so this is
        // unconditional. The duplicate bootstrap inside
        // `runQuickActionConversation` is intentionally removed.
        startNewConversation(projectId: defaultProjectId, cancelInFlightWork: false)
        activeQuickActionMode = mode
        inputText = ""

        let responseTaskId = UUID()
        inFlightResponseAbortReason = nil
        // Capture the originating session at spawn time so a background
        // completion (user navigated away mid-turn) still flips
        // `hasUnseenCompletion` on the conversation where the turn started.
        let originatingConversationId = currentNode?.id
        let originatingSession = originatingConversationId.map {
            conversationSessionStore.streamingSession(for: $0)
        }
        let responseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runQuickActionConversation(mode, responseTaskId: responseTaskId)
        }
        inFlightResponseTask = responseTask
        inFlightResponseTaskId = responseTaskId
        await responseTask.value
        let viewingNow = (currentNode?.id == originatingConversationId)
        let surfacedError = originatingSession?.captureFinish(
            turnId: responseTaskId,
            viewingNow: viewingNow,
            error: nil
        )
        if let surfacedError {
            NSLog("[NousTurn] background turn surfaced error: %@", String(describing: surfacedError))
        }
        clearInFlightResponseTaskIfOwned(responseTaskId)
        if inFlightResponseTaskId == nil {
            inFlightResponseAbortReason = nil
        }
    }

    @MainActor
    private func runQuickActionConversation(_ mode: QuickActionMode, responseTaskId: UUID) async {
        guard isActiveResponseTask(responseTaskId) else { return }

        // Conversation bootstrap moved to `beginQuickActionConversation`
        // so the in-flight task slots have a bound streaming session
        // before they're written.

        guard let node = currentNode else { return }

        isGenerating = true
        currentResponse = ""
        currentThinking = ""
        currentThinkingStartedAt = nil
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
        scheduleShadowLearningHeartbeat()
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
        bindStreamingSession(for: node)
        self.messages = []
        return node.id
    }

    /// Build a TurnHousekeepingPlan for a voice turn. Reuses the
    /// embedding / Galaxy / emoji refresh paths the typed flow uses; skips
    /// Gemini cache refresh because voice does not run through the
    /// typed-flow LLM service.
    private func voiceHousekeepingPlan(
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
        if let shadowLearningSignalRecorder {
            do {
                try shadowLearningSignalRecorder.recordSignals(from: result.userMessage)
            } catch {
                print("[ShadowLearning] failed to record voice signal: \(error)")
            }
        }
        let plan = voiceHousekeepingPlan(
            node: result.node,
            messagesAfterAppend: result.messagesAfterAppend
        )
        turnHousekeepingService.run(plan)
        scheduleShadowLearningHeartbeat()
    }

    /// Append a voice assistant message to the conversation identified by
    /// nodeId. Mirrors `appendVoiceMessage` but does not record
    /// Alex-specific shadow learning signals.
    func appendVoiceAssistantMessage(
        nodeId: UUID,
        text: String,
        timestamp: Date
    ) throws {
        let result = try conversationSessionStore.appendVoiceAssistantMessage(
            nodeId: nodeId,
            text: text,
            timestamp: timestamp
        )
        if currentNode?.id == nodeId {
            self.messages = result.messagesAfterAssistantAppend
        }
        let plan = voiceHousekeepingPlan(
            node: result.node,
            messagesAfterAppend: result.messagesAfterAssistantAppend
        )
        turnHousekeepingService.run(plan)
        scheduleShadowLearningHeartbeat()
    }

    // MARK: - Send (RAG Pipeline)

    @MainActor
    func send(attachments: [AttachedFileContext] = []) async {
        let limitedAttachments = AttachmentLimitPolicy.limitingImageAttachments(attachments)
        guard (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !limitedAttachments.isEmpty), !isGenerating else { return }

        // Manual `/reflect` slash command (Block 8 lite, dogfood-only). Runs
        // PerConversationReflectionPrompt against the current conversation
        // on Gemini and surfaces the claim as a transient assistant message.
        // Result is NOT persisted to the reflection_claim table — see
        // PerConversationReflectionService for rationale.
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput == "/reflect" && limitedAttachments.isEmpty {
            inputText = ""
            await runReflectCommand()
            return
        }

        // Pre-bind a streaming session at the spawn site so the in-flight
        // task slot writes below land on a real session. Without this, the
        // forwarded setters silently no-op against a nil session and the
        // active-task guard in `runSend` rejects the turn. The duplicate
        // bootstrap inside `runSend` is intentionally removed so we don't
        // create the conversation twice.
        let sourceDiscussionContextBeforeBootstrap = activeSourceDiscussionContext
        if currentNode == nil {
            startNewConversation(projectId: defaultProjectId, cancelInFlightWork: false)
            if let sourceDiscussionContextBeforeBootstrap {
                activeSourceDiscussionContext = sourceDiscussionContextBeforeBootstrap
            }
        } else if currentStreamingSession == nil, let node = currentNode {
            // currentNode was set without going through
            // startNewConversation/loadConversation (e.g. test scaffolding
            // or a restored-conversation scenario). Bind here so the
            // forwarded slots have somewhere to live.
            bindStreamingSession(for: node)
        }

        let responseTaskId = UUID()
        inFlightResponseAbortReason = nil
        // Capture the originating session at spawn time so a background
        // completion (user navigated away mid-turn) still flips
        // `hasUnseenCompletion` on the conversation where the turn started.
        let originatingConversationId = currentNode?.id
        let originatingSession = originatingConversationId.map {
            conversationSessionStore.streamingSession(for: $0)
        }
        let responseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSend(attachments: limitedAttachments, responseTaskId: responseTaskId)
        }
        inFlightResponseTask = responseTask
        inFlightResponseTaskId = responseTaskId
        await responseTask.value
        let viewingNow = (currentNode?.id == originatingConversationId)
        let surfacedError = originatingSession?.captureFinish(
            turnId: responseTaskId,
            viewingNow: viewingNow,
            error: nil
        )
        if let surfacedError {
            NSLog("[NousTurn] background turn surfaced error: %@", String(describing: surfacedError))
        }
        clearInFlightResponseTaskIfOwned(responseTaskId)
        if inFlightResponseTaskId == nil {
            inFlightResponseAbortReason = nil
        }
    }

    /// Runs `PerConversationReflectionService` over the current conversation
    /// and appends the result as an in-memory assistant message. The service
    /// persists the run + claim with `ReflectionRun.nodeId = currentNode.id`
    /// so retrieval (`fetchActiveReflectionClaims(currentNodeId:)`) surfaces
    /// the claim only inside this conversation, not in other chats.
    @MainActor
    private func runReflectCommand() async {
        guard let node = currentNode else {
            appendReflectionNotice("Reflection · 需要先选定一个对话先得。")
            return
        }
        guard let service = perConversationReflectionServiceFactory() else {
            appendReflectionNotice("Reflection · 未设定 Gemini API key，去 Settings 加咗先再试。")
            return
        }
        let snapshot = messages
        guard snapshot.count >= PerConversationReflectionService.manualTriggerMinimumTurns else {
            appendReflectionNotice("Reflection · 呢段对话仲短（\(snapshot.count) turns），最少要 \(PerConversationReflectionService.manualTriggerMinimumTurns) 才好捞 pattern。")
            return
        }

        isGenerating = true
        defer { isGenerating = false }

        do {
            let output = try await service.run(
                conversationId: node.id,
                conversationTitle: node.title,
                projectId: node.projectId,
                messages: snapshot
            )
            if let claim = output.claim {
                let body = "Reflection · 「\(claim.claim)」\n\n— \(claim.whyNonObvious)"
                appendReflectionNotice(body)
            } else {
                let reasonHint: String
                switch output.rejectionReason {
                case .lowConfidence: reasonHint = "（信心唔够）"
                case .unsupported: reasonHint = "（引用唔够实）"
                case .apiError: reasonHint = "（API 出错）"
                case .generic, .none: reasonHint = ""
                }
                appendReflectionNotice("Reflection · 暂时未见到非显然嘅 pattern\(reasonHint)。")
            }
        } catch let err as PerConversationReflectionService.ServiceError {
            appendReflectionNotice("Reflection · \(err.localizedDescription)")
        } catch {
            appendReflectionNotice("Reflection · 失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private func appendReflectionNotice(_ body: String) {
        let nodeId = currentNode?.id ?? UUID()
        let message = Message(
            nodeId: nodeId,
            role: .assistant,
            content: body,
            timestamp: Date(),
            source: .typed
        )
        messages.append(message)
    }

    @MainActor
    func sendTemporaryBranch(_ branch: TemporaryBranchViewModel) async {
        await branch.send(using: llmServiceProvider)
    }

    @MainActor
    func regenerateTemporaryBranch(_ branch: TemporaryBranchViewModel) async {
        await branch.regenerateLatestAssistant(using: llmServiceProvider)
    }

    @MainActor
    func loadTemporaryBranchRecords() -> [TemporaryBranchRecord] {
        guard let nodeId = currentNode?.id else { return [] }
        return (try? nodeStore.fetchTemporaryBranchRecords(nodeId: nodeId)) ?? []
    }

    @MainActor
    func persistTemporaryBranchRecord(_ record: TemporaryBranchRecord) {
        try? nodeStore.upsertTemporaryBranchRecord(record)
    }

    @MainActor
    func evaluateTemporaryBranchRecord(_ record: TemporaryBranchRecord) async -> TemporaryBranchRecord {
        let evaluator = TemporaryBranchMemoryEvaluator(llmServiceProvider: llmServiceProvider)
        let evaluated = await evaluator.evaluatedRecord(record)
        try? nodeStore.upsertTemporaryBranchRecord(evaluated)
        await userMemoryService.absorbTemporaryBranchSummary(record: evaluated)
        return evaluated
    }

    @MainActor
    func applyTemporaryBranchCandidate(
        _ candidateId: UUID,
        in record: TemporaryBranchRecord,
        action: TemporaryBranchMemoryCandidateAction
    ) async -> TemporaryBranchRecord? {
        guard let index = record.memoryCandidates.firstIndex(where: { $0.id == candidateId }) else {
            return nil
        }
        var updatedCandidates = record.memoryCandidates
        switch action {
        case .ignore:
            updatedCandidates[index].status = .rejected
        case .save:
            let didApply = await userMemoryService.applyTemporaryBranchCandidate(
                updatedCandidates[index],
                record: record
            )
            guard didApply else { return nil }
            updatedCandidates[index].status = .applied
        }

        let updated = TemporaryBranchRecord(
            sourceMessage: record.sourceMessage,
            localContext: record.localContext,
            messages: record.messages,
            summary: record.summary,
            memoryCandidates: updatedCandidates,
            updatedAt: Date(),
            lastEvaluatedAt: record.lastEvaluatedAt
        )
        try? nodeStore.upsertTemporaryBranchRecord(updated)
        return updated
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
        // Capture the originating session at spawn time so a background
        // completion (user navigated away mid-turn) still flips
        // `hasUnseenCompletion` on the conversation where the turn started.
        let originatingConversationId = currentNode?.id
        let originatingSession = originatingConversationId.map {
            conversationSessionStore.streamingSession(for: $0)
        }
        let responseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runRegenerateLatestAssistant(responseTaskId: responseTaskId)
        }
        inFlightResponseTask = responseTask
        inFlightResponseTaskId = responseTaskId
        await responseTask.value
        let viewingNow = (currentNode?.id == originatingConversationId)
        let surfacedError = originatingSession?.captureFinish(
            turnId: responseTaskId,
            viewingNow: viewingNow,
            error: nil
        )
        if let surfacedError {
            NSLog("[NousTurn] background turn surfaced error: %@", String(describing: surfacedError))
        }
        clearInFlightResponseTaskIfOwned(responseTaskId)
        if inFlightResponseTaskId == nil {
            inFlightResponseAbortReason = nil
        }
    }

    @MainActor
    private func runSend(attachments: [AttachedFileContext], responseTaskId: UUID) async {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!query.isEmpty || !attachments.isEmpty), isActiveResponseTask(responseTaskId) else { return }

        // Conversation bootstrap moved to `send()` so the in-flight task
        // slots have a bound streaming session before they're written.

        inputText = ""
        isGenerating = true
        currentResponse = ""
        currentThinking = ""
        currentThinkingStartedAt = Date()
        currentAgentTrace = []
        didHitBudgetExhaustion = false
        defer {
            if isActiveResponseTask(responseTaskId) {
                isGenerating = false
            }
        }

        let sourceDiscussionContext = activeSourceDiscussionContext
        let sourcePreparation = await prepareSourceMaterials(
            inputText: query,
            attachments: attachments,
            sourceDiscussionContext: sourceDiscussionContext
        )
        guard isActiveResponseTask(responseTaskId) else { return }
        if let sourceDiscussionContext {
            pendingSourceDiscussionContextByTurnId[responseTaskId] = sourceDiscussionContext
        }
        rememberPendingSourceMaterials(sourcePreparation.materials, for: responseTaskId)
        defer {
            pendingSourceMaterialsByTurnId.removeValue(forKey: responseTaskId)
            pendingSourceDiscussionContextByTurnId.removeValue(forKey: responseTaskId)
        }

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
            attachments: sourcePreparation.remainingAttachments,
            displayAttachments: attachments,
            sourceMaterials: sourcePreparation.materials,
            now: Date()
        )
        let eventSink = makeTurnEventSink(turnId: responseTaskId)

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
        scheduleShadowLearningHeartbeat()
    }

    private func prepareSourceMaterials(
        inputText: String,
        attachments: [AttachedFileContext],
        sourceDiscussionContext: SourceDiscussionContext? = nil
    ) async -> (materials: [SourceMaterialContext], remainingAttachments: [AttachedFileContext]) {
        var materials: [SourceMaterialContext] = []
        var ingestedDocumentAttachmentIds = Set<UUID>()
        if let sourceDiscussionContext {
            materials.append(sourceDiscussionContext.sourceMaterialContext())
        }
        let urls = SourceURLDetector.urls(in: inputText)
        if !urls.isEmpty {
            let urlMaterials = (try? await sourceIngestionService.ingestURLs(
                urls,
                projectId: currentNode?.projectId ?? defaultProjectId
            )) ?? []
            materials.append(contentsOf: urlMaterials)
        }

        let documentAttachments = attachments.filter(SourceIngestionService.isSupportedDocumentAttachment)
        if !documentAttachments.isEmpty {
            for attachment in documentAttachments {
                let documentMaterials = (try? sourceIngestionService.ingestDocumentAttachments(
                    [attachment],
                    projectId: currentNode?.projectId ?? defaultProjectId
                )) ?? []
                if !documentMaterials.isEmpty {
                    ingestedDocumentAttachmentIds.insert(attachment.id)
                    materials.append(contentsOf: documentMaterials)
                }
            }
        }

        materials = sourceIngestionService.enrichedMaterials(materials, matching: inputText)

        let remainingAttachments = attachments.filter { attachment in
            guard SourceIngestionService.isSupportedDocumentAttachment(attachment) else {
                return true
            }
            return !ingestedDocumentAttachmentIds.contains(attachment.id)
        }
        return (materials, remainingAttachments)
    }

    private func rememberPendingSourceMaterials(
        _ materials: [SourceMaterialContext],
        for turnId: UUID
    ) {
        if materials.isEmpty {
            pendingSourceMaterialsByTurnId.removeValue(forKey: turnId)
        } else {
            pendingSourceMaterialsByTurnId[turnId] = materials
        }
    }

    @discardableResult
    private func rememberSourceMaterials(
        _ materials: [SourceMaterialContext],
        for userMessageId: UUID
    ) -> Bool {
        guard !materials.isEmpty else { return true }
        do {
            try nodeStore.replaceMessageSourceMaterials(materials, for: userMessageId)
            sourceMaterialsByUserMessageId[userMessageId] = materials
            return true
        } catch {
            NSLog("[SourceIngestion] failed to persist source material links for message %@: %@", userMessageId.uuidString, error.localizedDescription)
            return false
        }
    }

    private func cacheSourceMaterialsForLoadedMessages() {
        sourceMaterialsByUserMessageId.removeAll()
        for message in messages where message.role == .user {
            let materials = (try? nodeStore.fetchMessageSourceMaterials(messageId: message.id)) ?? []
            sourceMaterialsByUserMessageId[message.id] = materials
        }
    }

    @discardableResult
    private func rememberSourceBriefing(
        _ briefing: SourceBriefing,
        for userMessageId: UUID
    ) -> Bool {
        do {
            try nodeStore.replaceSourceBriefing(briefing, for: userMessageId)
            if briefing.items.isEmpty {
                sourceBriefingsByUserMessageId[userMessageId] = .empty
            } else {
                sourceBriefingsByUserMessageId[userMessageId] = briefing
            }
            return true
        } catch {
            NSLog("[SourceBriefing] failed to persist briefing for message %@: %@", userMessageId.uuidString, error.localizedDescription)
            return false
        }
    }

    private func cacheSourceBriefingsForLoadedMessages() {
        sourceBriefingsByUserMessageId.removeAll()
        for message in messages where message.role == .user {
            let briefing = (try? nodeStore.fetchSourceBriefing(messageId: message.id)) ?? .empty
            sourceBriefingsByUserMessageId[message.id] = briefing
        }
    }

    private func sourceMaterialsForRetry(userMessage: Message) async -> [SourceMaterialContext] {
        if let materials = sourceMaterialsByUserMessageId[userMessage.id],
           !materials.isEmpty {
            return materials
        }

        if let storedMaterials = try? nodeStore.fetchMessageSourceMaterials(messageId: userMessage.id),
           !storedMaterials.isEmpty {
            let enrichedMaterials = sourceIngestionService.enrichedMaterials(
                storedMaterials,
                matching: userMessage.content
            )
            sourceMaterialsByUserMessageId[userMessage.id] = enrichedMaterials
            return enrichedMaterials
        }

        let prepared = await prepareSourceMaterials(
            inputText: userMessage.content,
            attachments: []
        )
        if !prepared.materials.isEmpty {
            rememberSourceMaterials(prepared.materials, for: userMessage.id)
        }
        return prepared.materials
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
                retainedMessages: retainedMessages,
                behaviorOutcome: .retry
            )
        } catch {
            presentAssistantFailure("Error: \(error.localizedDescription)")
            return
        }

        currentNode = updatedNode
        bindStreamingSession(for: updatedNode)
        messages = retainedMessages
        citations = []
        resolvedCorpusEntries = []
        currentResponse = ""
        currentThinking = ""
        currentThinkingStartedAt = nil
        currentAgentTrace = []
        didHitBudgetExhaustion = false
        let retrySourceMaterials = await sourceMaterialsForRetry(userMessage: userMessage)

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
            sourceMaterials: retrySourceMaterials,
            now: Date()
        )
        let prepared = PreparedConversationTurn(
            node: updatedNode,
            userMessage: userMessage,
            messagesAfterUserAppend: retainedMessages
        )
        let eventSink = makeTurnEventSink(turnId: responseTaskId)

        isGenerating = true
        currentThinkingStartedAt = Date()
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
        scheduleShadowLearningHeartbeat()
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

        #if DEBUG
        NSLog("[NousTurn] event turn=%@ seq=%d kind=%@", envelope.turnId.uuidString, envelope.sequence, Self.debugEventName(envelope.event))
        #endif

        switch envelope.event {
        case .userMessageAppended(let appended):
            currentNode = appended.node
            bindStreamingSession(for: appended.node)
            if scratchPadStore.activeConversationId != appended.node.id {
                scratchPadStore.activate(conversationId: appended.node.id)
            }
            messages = appended.messagesAfterUserAppend
            if let materials = pendingSourceMaterialsByTurnId.removeValue(forKey: envelope.turnId),
               !materials.isEmpty {
                rememberSourceMaterials(materials, for: appended.userMessage.id)
                pendingSourceDiscussionContextByTurnId.removeValue(forKey: envelope.turnId)
            }
        case .prepared(let prepared):
            currentNode = prepared.node
            bindStreamingSession(for: prepared.node)
            messages = prepared.messagesAfterUserAppend
            citations = prepared.citations
            resolvedCorpusEntries = prepared.resolvedCorpusEntries
            rememberSourceBriefing(prepared.sourceBriefing, for: prepared.userMessage.id)
            lastPromptGovernanceTrace = prepared.promptTrace
            if !prepared.messagesAfterUserAppend.isEmpty {
                activeChatMode = prepared.effectiveMode
            }
            currentResponse = ""
            if currentThinkingStartedAt == nil {
                currentThinkingStartedAt = Date()
            }
            currentAgentTrace = []
            didHitBudgetExhaustion = false
        case .thinkingDelta(let delta):
            if currentThinkingStartedAt == nil {
                currentThinkingStartedAt = Date()
            }
            if Self.shouldSeparateThinkingSection(delta, after: currentThinking) {
                currentThinking.append("\n\n")
            }
            currentThinking.append(delta)
        case .agentTraceDelta(let record):
            currentAgentTrace.append(record)
        case .textDelta(let delta):
            currentResponse.append(delta)
        case .completed(let completion):
            currentNode = completion.node
            bindStreamingSession(for: completion.node)
            messages = completion.messagesAfterAssistantAppend
            activeQuickActionMode = completion.nextQuickActionMode
            emitCitationTrace(for: completion)
            currentResponse = ""
            currentThinking = ""
            currentThinkingStartedAt = nil
            currentAgentTrace = []
            didHitBudgetExhaustion = false
        case .aborted(let reason):
            currentThinking = ""
            currentThinkingStartedAt = nil
            currentAgentTrace = []
            didHitBudgetExhaustion = false
            if reason == .unexpectedCancellation {
                presentAssistantFailure(
                    "Error: The reply was interrupted before it finished. Please try again."
                )
            }
        case .failed(let failure):
            currentThinking = ""
            currentThinkingStartedAt = nil
            currentAgentTrace = []
            didHitBudgetExhaustion = false
            presentAssistantFailure("Error: \(failure.message)")
        }
    }

    /// Phase A chat citation telemetry. Snapshots the cascade decision
    /// for this assistant turn and writes one trace row per candidate
    /// atom — including atoms filtered out by the UI confidence floor.
    /// Non-UUID-shaped citable entry ids (sidecar facts) are skipped
    /// since the trace table keys on UUIDs.
    @MainActor
    private func emitCitationTrace(for completion: TurnCompletion) {
        guard !resolvedCorpusEntries.isEmpty else { return }

        let displayedAtomIds: Set<UUID> = {
            switch primaryAttribution {
            case .atomCards(let entries):
                return Set(entries.compactMap { UUID(uuidString: $0.entry.id) })
            case .legacyCitations, .none:
                return []
            }
        }()

        let candidates: [(atomId: UUID, confidence: Double)] = resolvedCorpusEntries.compactMap { resolved in
            guard let atomId = UUID(uuidString: resolved.entry.id) else { return nil }
            return (atomId: atomId, confidence: resolved.entry.confidence ?? 0.0)
        }

        try? citationTraceEmitter.emit(
            conversationId: completion.node.id,
            turnId: completion.assistantMessage.id,
            candidates: candidates,
            displayedIds: displayedAtomIds
        )
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
            bindStreamingSession(for: committed.node)
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
        #if DEBUG
        NSLog("[NousTurn] cancel response task=%@ reason=%@", inFlightResponseTaskId?.uuidString ?? "nil", String(describing: reason))
        #endif
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
            currentThinkingStartedAt = nil
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

    @MainActor
    private func scheduleShadowLearningHeartbeat() {
        heartbeatCoordinator?.scheduleShadowLearningAfterIdle()
    }

    private static func shouldSeparateThinkingSection(_ delta: String, after currentThinking: String) -> Bool {
        guard !currentThinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return [
            ThinkingTraceTitles.judge,
            ThinkingTraceTitles.assistant,
            ThinkingTraceTitles.agentLoop
        ].contains { delta.hasPrefix($0) }
    }

    private static func debugEventName(_ event: TurnEvent) -> String {
        switch event {
        case .userMessageAppended: return "userMessageAppended"
        case .prepared: return "prepared"
        case .thinkingDelta: return "thinkingDelta"
        case .agentTraceDelta: return "agentTraceDelta"
        case .textDelta: return "textDelta"
        case .completed: return "completed"
        case .aborted(let reason): return "aborted(\(reason))"
        case .failed(let failure): return "failed(\(failure.stage))"
        }
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
        guard let event = judgeEvent(forMessageId: messageId) else { return }
        clearChangedShadowFeedbackSignal(
            previousEvent: event,
            newFeedback: feedback,
            newReason: nil
        )
        dismissFailureSkillCandidateIfNeeded(
            previousEvent: event,
            newFeedback: feedback,
            newReason: nil,
            newNote: nil
        )
        let eventId = event.id
        governanceTelemetry.recordFeedback(eventId: eventId, feedback: feedback)
        if feedback == .up {
            recordShadowFeedbackSignal(
                forMessageId: messageId,
                feedback: feedback,
                reason: nil,
                note: nil
            )
        }
        bumpJudgeFeedbackVersion()
    }

    @MainActor
    func recordFeedbackDetail(
        forMessageId messageId: UUID,
        feedback: JudgeFeedback,
        reason: JudgeFeedbackReason?,
        note: String?
    ) {
        guard let event = judgeEvent(forMessageId: messageId) else { return }
        clearChangedShadowFeedbackSignal(
            previousEvent: event,
            newFeedback: feedback,
            newReason: reason
        )
        dismissFailureSkillCandidateIfNeeded(
            previousEvent: event,
            newFeedback: feedback,
            newReason: reason,
            newNote: note
        )
        let eventId = event.id
        governanceTelemetry.recordFeedback(eventId: eventId, feedback: feedback, reason: reason, note: note)
        if feedback == .down {
            var feedbackEvent = event
            feedbackEvent.userFeedback = feedback
            feedbackEvent.feedbackTs = Date()
            feedbackEvent.feedbackReason = reason
            feedbackEvent.feedbackNote = note
            recordFailureSkillCandidate(from: feedbackEvent)
        }
        recordShadowFeedbackSignal(
            forMessageId: messageId,
            feedback: feedback,
            reason: reason,
            note: note
        )
        bumpJudgeFeedbackVersion()
    }

    private func recordFailureSkillCandidate(from event: JudgeEvent) {
        guard let failureSkillCandidateStore else { return }
        guard let candidate = FailureToSkillDetector().candidate(from: event) else { return }
        do {
            try failureSkillCandidateStore.upsertCandidate(candidate)
        } catch {
            print("[FailureToSkill] failed to record feedback candidate: \(error)")
        }
    }

    private func dismissFailureSkillCandidateIfNeeded(
        previousEvent: JudgeEvent,
        newFeedback: JudgeFeedback,
        newReason: JudgeFeedbackReason?,
        newNote: String?
    ) {
        guard previousEvent.userFeedback == .down else { return }
        guard let previousCandidate = FailureToSkillDetector().candidate(from: previousEvent) else { return }

        if newFeedback != .down {
            dismissFailureSkillCandidates(for: previousEvent)
            return
        }

        var updatedEvent = previousEvent
        updatedEvent.userFeedback = newFeedback
        updatedEvent.feedbackReason = newReason
        updatedEvent.feedbackNote = newNote
        guard let updatedCandidate = FailureToSkillDetector().candidate(from: updatedEvent),
              updatedCandidate.signature == previousCandidate.signature else {
            dismissFailureSkillCandidates(for: previousEvent)
            return
        }
    }

    private func dismissFailureSkillCandidates(for event: JudgeEvent) {
        guard let failureSkillCandidateStore else { return }
        do {
            try failureSkillCandidateStore.dismissCandidates(
                sourceKind: .judgeFeedback,
                sourceId: event.id.uuidString
            )
        } catch {
            print("[FailureToSkill] failed to dismiss feedback candidate: \(error)")
        }
    }

    @MainActor
    func clearFeedback(forMessageId messageId: UUID) {
        guard let event = judgeEvent(forMessageId: messageId) else { return }
        if let feedback = event.userFeedback {
            clearShadowFeedbackSignal(
                forMessageId: messageId,
                feedback: feedback,
                reason: event.feedbackReason
            )
        }
        dismissFailureSkillCandidateIfNeeded(
            previousEvent: event,
            newFeedback: .up,
            newReason: nil,
            newNote: nil
        )
        let eventId = event.id
        governanceTelemetry.clearFeedback(eventId: eventId)
        bumpJudgeFeedbackVersion()
    }

    private func clearChangedShadowFeedbackSignal(
        previousEvent: JudgeEvent,
        newFeedback: JudgeFeedback,
        newReason: JudgeFeedbackReason?
    ) {
        guard let shadowLearningSignalRecorder,
              let previousFeedback = previousEvent.userFeedback,
              let messageId = previousEvent.messageId else {
            return
        }

        let previousLabel = shadowLearningSignalRecorder.feedbackSignalLabel(
            feedback: previousFeedback,
            reason: previousEvent.feedbackReason
        )
        let newLabel = shadowLearningSignalRecorder.feedbackSignalLabel(
            feedback: newFeedback,
            reason: newReason
        )
        guard previousLabel != newLabel else {
            return
        }

        do {
            try shadowLearningSignalRecorder.clearFeedbackSignal(
                feedback: previousFeedback,
                reason: previousEvent.feedbackReason,
                sourceMessageId: messageId
            )
        } catch {
            print("[ShadowLearning] failed to clear changed feedback signal: \(error)")
        }
    }

    private func recordShadowFeedbackSignal(
        forMessageId messageId: UUID,
        feedback: JudgeFeedback,
        reason: JudgeFeedbackReason?,
        note: String?
    ) {
        guard let shadowLearningSignalRecorder else { return }
        do {
            try shadowLearningSignalRecorder.recordFeedbackSignal(
                feedback: feedback,
                reason: reason,
                note: note,
                sourceMessageId: messageId
            )
        } catch {
            print("[ShadowLearning] failed to record feedback signal: \(error)")
        }
    }

    private func clearShadowFeedbackSignal(
        forMessageId messageId: UUID,
        feedback: JudgeFeedback,
        reason: JudgeFeedbackReason?
    ) {
        guard let shadowLearningSignalRecorder else { return }
        do {
            try shadowLearningSignalRecorder.clearFeedbackSignal(
                feedback: feedback,
                reason: reason,
                sourceMessageId: messageId
            )
        } catch {
            print("[ShadowLearning] failed to clear feedback signal: \(error)")
        }
    }
}
