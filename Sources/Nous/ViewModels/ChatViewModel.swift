import Foundation
import Observation

@Observable
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

    // MARK: - Dependencies

    private let nodeStore: NodeStore
    private let vectorStore: VectorStore
    private let embeddingService: EmbeddingService
    private let graphEngine: GraphEngine
    private let userMemoryService: UserMemoryService
    private let userMemoryScheduler: UserMemoryScheduler
    private let llmServiceProvider: () -> (any LLMService)?
    private let currentProviderProvider: () -> LLMProvider
    private let judgeLLMServiceFactory: () -> (any LLMService)?
    private let provocationJudgeFactory: (any LLMService) -> any Judging
    /// Stored as a typed `Task<JudgeVerdict, Error>` — not `Task<Void, …>` — so tests can
    /// `await task.value` and inspect the verdict directly. The slot is guarded on clear:
    /// a later `send()` may have already overwritten it with a new task ID, so only the task
    /// that still owns the slot clears it (see `inFlightJudgeTaskId` guard in `send()`).
    private var inFlightJudgeTask: Task<JudgeVerdict, Error>?
    private var inFlightJudgeTaskId: UUID?
    private var inFlightResponseTask: Task<Void, Never>?
    private var inFlightResponseTaskId: UUID?
    private let governanceTelemetry: GovernanceTelemetryStore
    private let geminiPromptCache: GeminiPromptCacheService
    private let scratchPadStore: ScratchPadStore
    /// In-flight cache-refresh bookkeeping, keyed by conversation id. The token map
    /// lets a late-arriving worker detect that it has been superseded and clean up its
    /// orphaned server-side handle instead of overwriting a newer entry.
    private var geminiCacheRefreshTasks: [UUID: Task<Void, Never>] = [:]
    private var geminiCacheRefreshTokens: [UUID: UUID] = [:]

    // MARK: - Init

    init(
        nodeStore: NodeStore,
        vectorStore: VectorStore,
        embeddingService: EmbeddingService,
        graphEngine: GraphEngine,
        userMemoryService: UserMemoryService,
        userMemoryScheduler: UserMemoryScheduler,
        llmServiceProvider: @escaping () -> (any LLMService)?,
        currentProviderProvider: @escaping () -> LLMProvider,
        judgeLLMServiceFactory: @escaping () -> (any LLMService)?,
        provocationJudgeFactory: @escaping (any LLMService) -> any Judging = { ProvocationJudge(llmService: $0) },
        governanceTelemetry: GovernanceTelemetryStore = GovernanceTelemetryStore(),
        geminiPromptCache: GeminiPromptCacheService = GeminiPromptCacheService(),
        scratchPadStore: ScratchPadStore,
        defaultProjectId: UUID? = nil
    ) {
        self.nodeStore = nodeStore
        self.vectorStore = vectorStore
        self.embeddingService = embeddingService
        self.graphEngine = graphEngine
        self.userMemoryService = userMemoryService
        self.userMemoryScheduler = userMemoryScheduler
        self.llmServiceProvider = llmServiceProvider
        self.currentProviderProvider = currentProviderProvider
        self.judgeLLMServiceFactory = judgeLLMServiceFactory
        self.provocationJudgeFactory = provocationJudgeFactory
        self.governanceTelemetry = governanceTelemetry
        self.geminiPromptCache = geminiPromptCache
        self.scratchPadStore = scratchPadStore
        self.defaultProjectId = defaultProjectId
    }

    deinit {
        // VM teardown — make sure no judge task outlives us.
        inFlightJudgeTask?.cancel()
        inFlightResponseTask?.cancel()
        inFlightJudgeTaskId = nil
        inFlightResponseTaskId = nil
        for task in geminiCacheRefreshTasks.values { task.cancel() }
        geminiCacheRefreshTasks.removeAll()
        geminiCacheRefreshTokens.removeAll()
    }

    // MARK: - Conversation Management

    @MainActor
    func startNewConversation(
        title: String = "New Conversation",
        projectId: UUID? = nil,
        cancelInFlightWork: Bool = true
    ) {
        if cancelInFlightWork {
            cancelInFlightResponse(clearDraft: true)
            cancelInFlightJudge()  // any in-flight judge belonged to the old conversation
        }
        let node = NousNode(
            type: .conversation,
            title: title,
            projectId: projectId
        )
        try? nodeStore.insertNode(node)
        currentNode = node
        messages = []
        citations = []
        currentResponse = ""
        currentThinking = ""
        didHitBudgetExhaustion = false
        activeQuickActionMode = nil
        activeChatMode = nil  // brand-new chat has no prior judgment
        NotificationCenter.default.post(name: .nousNodesDidChange, object: nil)
    }

    @MainActor
    func loadConversation(_ node: NousNode, cancelInFlightWork: Bool = true) {
        if cancelInFlightWork {
            cancelInFlightResponse(clearDraft: true)
            cancelInFlightJudge()  // switching conversations invalidates any pending verdict
        }
        currentNode = node
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
        let responseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runQuickActionConversation(mode, responseTaskId: responseTaskId)
        }
        inFlightResponseTask = responseTask
        inFlightResponseTaskId = responseTaskId
        await responseTask.value
        clearInFlightResponseTaskIfOwned(responseTaskId)
    }

    @MainActor
    private func runQuickActionConversation(_ mode: QuickActionMode, responseTaskId: UUID) async {
        guard isActiveResponseTask(responseTaskId) else { return }

        startNewConversation(title: mode.label, projectId: defaultProjectId, cancelInFlightWork: false)
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

        let contextSlice = ChatViewModel.assembleContext(
            chatMode: .companion,
            currentUserInput: ChatViewModel.quickActionOpeningPrompt(for: mode),
            globalMemory: userMemoryService.currentGlobal(),
            essentialStory: userMemoryService.currentEssentialStory(
                projectId: node.projectId,
                excludingConversationId: node.id
            ),
            userModel: userMemoryService.currentUserModel(
                projectId: node.projectId,
                conversationId: node.id
            ),
            memoryEvidence: userMemoryService.currentBoundedEvidence(
                projectId: node.projectId,
                excludingConversationId: node.id
            ),
            projectMemory: node.projectId.flatMap { userMemoryService.currentProject(projectId: $0) },
            conversationMemory: userMemoryService.currentConversation(nodeId: node.id),
            recentConversations: [],
            citations: [],
            projectGoal: projectGoal,
            activeQuickActionMode: mode,
            allowInteractiveClarification: false
        )
        let promptTrace = ChatViewModel.governanceTrace(
            chatMode: .companion,
            currentUserInput: ChatViewModel.quickActionOpeningPrompt(for: mode),
            globalMemory: userMemoryService.currentGlobal(),
            essentialStory: userMemoryService.currentEssentialStory(
                projectId: node.projectId,
                excludingConversationId: node.id
            ),
            userModel: userMemoryService.currentUserModel(
                projectId: node.projectId,
                conversationId: node.id
            ),
            memoryEvidence: userMemoryService.currentBoundedEvidence(
                projectId: node.projectId,
                excludingConversationId: node.id
            ),
            projectMemory: node.projectId.flatMap { userMemoryService.currentProject(projectId: $0) },
            conversationMemory: userMemoryService.currentConversation(nodeId: node.id),
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
            let errorMessage = Message(nodeId: node.id, role: .assistant, content: errorContent)
            try? nodeStore.insertMessage(errorMessage)
            messages.append(errorMessage)
            persistConversationSnapshot(for: node.id, messages: messages)
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
        let assistantContent = currentResponse
        let assistantMessage = Message(nodeId: node.id, role: .assistant, content: assistantContent)
        try? nodeStore.insertMessage(assistantMessage)
        messages.append(assistantMessage)
        persistConversationSnapshot(for: node.id, messages: messages, shouldRefreshEmoji: true)
        activeQuickActionMode = ChatViewModel.updatedQuickActionMode(
            currentMode: activeQuickActionMode,
            assistantContent: assistantContent
        )
        scratchPadStore.ingestAssistantMessage(
            content: assistantContent,
            sourceMessageId: assistantMessage.id
        )
        scheduleUserMemoryRefresh(for: node, messages: messages)
        refreshGeminiConversationCacheIfNeeded(
            nodeId: node.id,
            llm: llm,
            stableSystem: contextSlice.stable,
            persistedMessages: messages
        )
        currentResponse = ""
    }

    // MARK: - Send (RAG Pipeline)

    @MainActor
    func send(attachments: [AttachedFileContext] = []) async {
        guard (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty), !isGenerating else { return }

        let responseTaskId = UUID()
        let responseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSend(attachments: attachments, responseTaskId: responseTaskId)
        }
        inFlightResponseTask = responseTask
        inFlightResponseTaskId = responseTaskId
        await responseTask.value
        clearInFlightResponseTaskIfOwned(responseTaskId)
    }

    @MainActor
    private func runSend(attachments: [AttachedFileContext], responseTaskId: UUID) async {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!query.isEmpty || !attachments.isEmpty), isActiveResponseTask(responseTaskId) else { return }

        let attachmentNames = attachments.map(\.name)
        let promptQuery = query.isEmpty ? "Please review the attached files." : query
        let userMessageContent = ChatViewModel.userMessageContent(
            query: promptQuery,
            attachmentNames: attachmentNames
        )
        let retrievalQuery = ([promptQuery] + attachmentNames).joined(separator: "\n")

        inputText = ""
        isGenerating = true
        currentResponse = ""
        defer {
            if isActiveResponseTask(responseTaskId) {
                isGenerating = false
            }
        }

        // Step 1: Create conversation node if nil
        if currentNode == nil {
            let title = String(promptQuery.prefix(40))
            startNewConversation(title: title, projectId: defaultProjectId, cancelInFlightWork: false)
        }

        guard let node = currentNode else { return }

        // Step 2: Save user message
        let userMessage = Message(nodeId: node.id, role: .user, content: userMessageContent)
        try? nodeStore.insertMessage(userMessage)
        messages.append(userMessage)
        persistConversationSnapshot(for: node.id, messages: messages)

        // Step 3: Embed query and search for citations
        citations = []
        if embeddingService.isLoaded {
            if let queryEmbedding = try? embeddingService.embed(retrievalQuery) {
                let results = (try? vectorStore.searchForChatCitations(
                    query: queryEmbedding,
                    queryText: retrievalQuery,
                    topK: 5,
                    excludeIds: [node.id]
                )) ?? []
                citations = results
            }
        }

        // Step 4: Fetch project goal if node has projectId
        var projectGoal: String? = nil
        if let projectId = node.projectId,
           let project = try? nodeStore.fetchProject(id: projectId),
           !project.goal.isEmpty {
            projectGoal = project.goal
        }

        let recentConversations = (try? nodeStore.fetchRecentConversationMemories(
            limit: 2,
            excludingId: node.id
        )) ?? []

        // --- BEGIN reordered send flow (per spec D3) ---

        // Step A: Gather contradiction-oriented hard recall and the citable pool (needed by the judge).
        let nodeHits = citations.map { $0.node.id }
        let hardRecallFacts = (try? userMemoryService.contradictionRecallFacts(
            projectId: node.projectId,
            conversationId: node.id
        )) ?? []
        let contradictionCandidateIds = Set(
            userMemoryService
                .annotateContradictionCandidates(
                    currentMessage: promptQuery,
                    facts: hardRecallFacts
                )
                .filter(\.isContradictionCandidate)
                .map { $0.fact.id.uuidString }
        )
        let citablePool = (try? userMemoryService.citableEntryPool(
            projectId: node.projectId,
            conversationId: node.id,
            nodeHits: nodeHits,
            hardRecallFacts: hardRecallFacts,
            contradictionCandidateIds: contradictionCandidateIds
        )) ?? []

        // Step B: Run the judge (or skip on .local).
        let currentProvider = currentProviderProvider()
        let eventId = UUID()
        var verdictForLog: JudgeVerdict?
        var fallbackReason: JudgeFallbackReason = .ok
        var profile: BehaviorProfile = .supportive
        var focusBlock: String?
        var inferredMode: ChatMode?

        if currentProvider == .local {
            fallbackReason = .providerLocal
        } else if let judgeLLM = judgeLLMServiceFactory() {
            inFlightJudgeTask?.cancel()

            let judge = provocationJudgeFactory(judgeLLM)
            let taskId = UUID()
            let task = Task { () async throws -> JudgeVerdict in
                try await judge.judge(
                    userMessage: promptQuery,
                    citablePool: citablePool,
                    previousMode: activeChatMode,
                    provider: currentProvider
                )
            }
            inFlightJudgeTask = task
            inFlightJudgeTaskId = taskId
            defer {
                if inFlightJudgeTaskId == taskId {
                    inFlightJudgeTask = nil
                    inFlightJudgeTaskId = nil
                }
            }

            do {
                let verdict = try await task.value
                verdictForLog = verdict
                inferredMode = verdict.inferredMode

                if verdict.shouldProvoke, let entryIdStr = verdict.entryId {
                    if let matched = citablePool.first(where: { $0.id == entryIdStr }),
                       !matched.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        profile = .provocative
                        focusBlock = ChatViewModel.buildFocusBlock(entryId: matched.id, rawText: matched.text)
                        fallbackReason = .ok
                    } else {
                        fallbackReason = .unknownEntryId
                        profile = .supportive
                    }
                } else {
                    fallbackReason = .ok
                    profile = .supportive
                }
            } catch JudgeError.timeout {
                fallbackReason = .timeout
            } catch JudgeError.badJSON {
                fallbackReason = .badJSON
            } catch is CancellationError {
                return
            } catch {
                fallbackReason = .apiError
            }
        } else {
            fallbackReason = .judgeUnavailable
        }

        // Guard after judge await: if the turn was canceled (chat switch, stop, new send)
        // while we were waiting on the judge, bail before mutating any downstream state.
        guard isActiveResponseTask(responseTaskId) else { return }

        // Step C: Decide the effective mode for this turn.
        let effectiveMode: ChatMode = inferredMode ?? (activeChatMode ?? .companion)

        // Step D: Assemble context + governance trace using effectiveMode.
        let shouldAllowInteractiveClarification = ChatViewModel.shouldAllowInteractiveClarification(
            activeQuickActionMode: activeQuickActionMode,
            messages: messages
        )
        let contextSlice = ChatViewModel.assembleContext(
            chatMode: effectiveMode,
            currentUserInput: promptQuery,
            globalMemory: userMemoryService.currentGlobal(),
            essentialStory: userMemoryService.currentEssentialStory(
                projectId: node.projectId,
                excludingConversationId: node.id
            ),
            userModel: userMemoryService.currentUserModel(
                projectId: node.projectId,
                conversationId: node.id
            ),
            memoryEvidence: userMemoryService.currentBoundedEvidence(
                projectId: node.projectId,
                excludingConversationId: node.id
            ),
            projectMemory: node.projectId.flatMap { userMemoryService.currentProject(projectId: $0) },
            conversationMemory: userMemoryService.currentConversation(nodeId: node.id),
            recentConversations: recentConversations,
            citations: citations,
            projectGoal: projectGoal,
            attachments: attachments,
            activeQuickActionMode: activeQuickActionMode,
            allowInteractiveClarification: shouldAllowInteractiveClarification
        )
        let promptTrace = ChatViewModel.governanceTrace(
            chatMode: effectiveMode,
            currentUserInput: promptQuery,
            globalMemory: userMemoryService.currentGlobal(),
            essentialStory: userMemoryService.currentEssentialStory(
                projectId: node.projectId,
                excludingConversationId: node.id
            ),
            userModel: userMemoryService.currentUserModel(
                projectId: node.projectId,
                conversationId: node.id
            ),
            memoryEvidence: userMemoryService.currentBoundedEvidence(
                projectId: node.projectId,
                excludingConversationId: node.id
            ),
            projectMemory: node.projectId.flatMap { userMemoryService.currentProject(projectId: $0) },
            conversationMemory: userMemoryService.currentConversation(nodeId: node.id),
            recentConversations: recentConversations,
            citations: citations,
            projectGoal: projectGoal,
            attachments: attachments,
            activeQuickActionMode: activeQuickActionMode,
            allowInteractiveClarification: shouldAllowInteractiveClarification
        )
        lastPromptGovernanceTrace = promptTrace
        governanceTelemetry.recordPromptTrace(promptTrace)

        // Step E: Compose the per-turn slice. `stableSystem` rides the Gemini cache;
        // `volatileSystem` also absorbs the judge's per-turn profile block and any
        // focus directive so the cache hash survives judge-driven churn.
        let stableSystem = contextSlice.stable
        var volatilePartsForTurn: [String] = [contextSlice.volatile, profile.contextBlock]
        if let fb = focusBlock { volatilePartsForTurn.append(fb) }
        let volatileSystem = volatilePartsForTurn.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let turnSlice = TurnSystemSlice(stable: stableSystem, volatile: volatileSystem)

        // Step F: Append the judge_events row using effectiveMode.
        // BEFORE the main call so the row survives main-call failure.
        // SINGLE stamp site for provocationKind — do not add another call to deriveProvocationKind.
        if var v = verdictForLog {
            v.provocationKind = ChatViewModel.deriveProvocationKind(
                verdict: v,
                contradictionCandidateIds: contradictionCandidateIds
            )
            verdictForLog = v
        }
        let verdictJSONStr: String = {
            if let v = verdictForLog, let data = try? JSONEncoder().encode(v) {
                return String(data: data, encoding: .utf8) ?? "{}"
            }
            return "{}"
        }()
        let event = JudgeEvent(
            id: eventId, ts: Date(), nodeId: node.id, messageId: nil,
            chatMode: effectiveMode, provider: currentProvider,
            verdictJSON: verdictJSONStr, fallbackReason: fallbackReason,
            userFeedback: nil, feedbackTs: nil
        )
        governanceTelemetry.appendJudgeEvent(event)

        // Step G: Persist runtime activeChatMode NOW, before the main call.
        // Retry-without-reload must see the freshly-judged mode as previousMode on the next send.
        activeChatMode = effectiveMode

        // --- END reordered send flow ---

        // Step 6: Build LLMMessage array from conversation history
        let llmMessages: [LLMMessage] = messages.map { msg in
            LLMMessage(
                role: msg.role == .user ? "user" : "assistant",
                content: msg.content
            )
        }
        // The user message was already appended to messages, so llmMessages already includes it

        // Step 7: Get LLM from provider
        guard let llm = llmServiceProvider() else {
            guard isActiveResponseTask(responseTaskId) else { return }
            let errorContent = "Please configure an LLM in Settings."
            let errorMessage = Message(nodeId: node.id, role: .assistant, content: errorContent)
            try? nodeStore.insertMessage(errorMessage)
            messages.append(errorMessage)
            try? nodeStore.updateJudgeEventMessageId(eventId: eventId, messageId: errorMessage.id)
            persistConversationSnapshot(for: node.id, messages: messages, shouldRefreshEmoji: true)
            activeQuickActionMode = ChatViewModel.updatedQuickActionMode(
                currentMode: activeQuickActionMode,
                assistantContent: errorContent
            )
            currentResponse = ""
            return
        }

        // Resolve the cache entry exactly once per turn. Previously this was recomputed
        // three times (once per helper) — each recompute ran a full SHA256 over system
        // + transcript. Thread the resolved entry through the helpers instead.
        let resolvedCacheEntry = activeGeminiHistoryCache(
            nodeId: node.id,
            llm: llm,
            stableSystem: stableSystem,
            transcriptMessages: llmMessages
        )
        let requestMessages = requestMessages(
            forSlice: turnSlice,
            transcriptMessages: llmMessages,
            cacheEntry: resolvedCacheEntry
        )
        let requestSystem = requestSystem(
            forSlice: turnSlice,
            cacheEntry: resolvedCacheEntry
        )

        // Step 8: Stream response
        currentThinking = ""
        didHitBudgetExhaustion = false
        let streamingService = configuredStreamingService(
            from: configuredGeminiService(from: llm, cacheEntry: resolvedCacheEntry),
            responseTaskId: responseTaskId,
            captureThinking: true
        )
        do {
            let stream = try await streamingService.generate(messages: requestMessages, system: requestSystem)
            // Guard after the generate() await: same window as the judge guard above.
            guard isActiveResponseTask(responseTaskId) else { return }
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
            // Cached handle may have been evicted server-side before our local TTL ran
            // out. Drop the stale entry so the next turn rebuilds against a live cache
            // instead of repeatedly hitting 400/404 on the same dead handle.
            if resolvedCacheEntry != nil {
                geminiPromptCache.removeEntry(for: node.id)
            }
            currentResponse = "Error: \(error.localizedDescription)"
        }

        // Step 9: Save assistant message
        guard isActiveResponseTask(responseTaskId) else { return }
        // Budget-exhausted path: Gemini burned the whole thinking budget on thoughts
        // and emitted no user-facing text. Surface it as a real assistant message so
        // Alex sees the turn failed and has an obvious retry path (type again). We
        // persist it as a normal message so it roundtrips through reload.
        if didHitBudgetExhaustion && currentResponse.isEmpty {
            currentResponse = "(I ran out of thinking budget on that one. Try asking again, maybe a touch simpler.)"
        }
        let assistantContent = currentResponse
        let persistedThinking = currentThinking.isEmpty ? nil : currentThinking
        let assistantMessage = Message(
            nodeId: node.id,
            role: .assistant,
            content: assistantContent,
            thinkingContent: persistedThinking
        )
        try? nodeStore.insertMessage(assistantMessage)
        messages.append(assistantMessage)
        scratchPadStore.ingestAssistantMessage(
            content: assistantContent,
            sourceMessageId: assistantMessage.id
        )

        // Step 9b: patch the judge event with the message it produced
        try? nodeStore.updateJudgeEventMessageId(eventId: eventId, messageId: assistantMessage.id)
        persistConversationSnapshot(for: node.id, messages: messages, shouldRefreshEmoji: true)
        activeQuickActionMode = ChatViewModel.updatedQuickActionMode(
            currentMode: activeQuickActionMode,
            assistantContent: assistantContent
        )
        scheduleUserMemoryRefresh(for: node, messages: messages)
        refreshGeminiConversationCacheIfNeeded(
            nodeId: node.id,
            llm: llm,
            stableSystem: stableSystem,
            persistedMessages: messages
        )
        currentResponse = ""
        currentThinking = ""

        // Step 10: Async task — update node embedding + regenerate edges
        let nodeId = node.id
        let fullContent = messages.map(\.content).joined(separator: "\n")
        let embeddingService = self.embeddingService
        let vectorStore = self.vectorStore
        let nodeStore = self.nodeStore
        let graphEngine = self.graphEngine

        Task.detached(priority: .background) {
            if let embedding = try? embeddingService.embed(fullContent) {
                try? vectorStore.storeEmbedding(embedding, for: nodeId)
                if var updatedNode = try? nodeStore.fetchNode(id: nodeId) {
                    updatedNode.embedding = embedding
                    try? graphEngine.regenerateEdges(for: updatedNode)
                }
            }
        }
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
        cancelInFlightResponse(clearDraft: false)
    }

    @MainActor
    private func cancelInFlightResponse(clearDraft: Bool) {
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
    }

    // MARK: - Focus Block

    private static func buildFocusBlock(entryId: String, rawText: String) -> String {
        """
        RELEVANT PRIOR MEMORY (id=\(entryId)):
        \(rawText)

        Surface this memory in your reply. Name the tension with Alex's current claim in plain language.
        Quote one specific line from the memory faithfully if there is one to quote; otherwise paraphrase tightly.
        Do not reword the memory into a summary and pretend you remembered it differently.
        """
    }

    // MARK: - Anchor (Core Identity)

    /// Loads the anchor document — Nous's immutable core identity and thinking methods.
    /// This is who Nous is. It does not change with context.
    private static let anchor: String = {
        guard let url = Bundle.main.url(forResource: "anchor", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            print("[Nous] WARNING: anchor.md not found in bundle, using fallback")
            return "You are Nous, Alex 最信任嘅朋友。用广东话回应，语气好似同好朋友倾偈咁。Be warm, genuine, and direct."
        }
        print("[Nous] Anchor loaded: \(content.prefix(80))...")
        return content
    }()

    private static let memoryInterpretationPolicy = """
    ---

    MEMORY INTERPRETATION POLICY:
    If you notice a personal pattern, state it as a hypothesis unless Alex clearly confirmed it or it is strongly supported across multiple moments.
    Prefer wording like: "I might be wrong, but...", "One hypothesis is...", "Does this fit, or is something else more true?"
    Do not present diagnoses or identity labels as certainty.
    """

    private static let coreSafetyPolicy = """
    ---

    CORE SAFETY POLICY:
    Do not encourage Alex to become emotionally dependent on Nous.
    Do not present medical, psychological, or legal certainty when the situation is ambiguous.
    Respect memory boundaries: if Alex asks not to store something, or asked for consent before sensitive storage, do not silently turn that into durable memory.
    """

    private static let summaryOutputPolicy = """
    ---

    SUMMARY OUTPUT POLICY:
    When Alex asks you to summarize the current conversation (keywords and intents include "总结", "summarize", "repo", "做笔记", "summary", "整份笔记", or equivalents), wrap the summary body in <summary>…</summary>. Inside the tag, use this exact markdown structure:

      # <concise title — used as the download filename>

      ## 问题
      <one narrative paragraph: what triggered the discussion>

      ## 思考
      <one narrative paragraph: the path the conversation took, including pivots>

      ## 结论
      <one narrative paragraph: consensus or decisions reached>

      ## 下一步
      - <short actionable bullet>
      - <another>

    Paragraphs must be narrative prose, not bullet dumps. The # title must contain no filename-unsafe characters (avoid /\\:*?"<>|).

    Text outside the tag is allowed for a brief conversational wrapper (e.g. "整好了，睇下右边嘅白纸"). The summary content itself must strictly live inside the tag. Never emit the tag when Alex is not asking for a summary.
    """

    private static let highRiskSafetyModeBlock = """
    ---

    HIGH-RISK SAFETY MODE:
    Alex may be describing imminent danger, self-harm, abuse, or another acute safety issue.
    Prioritize immediate safety, grounding, and real-world human support over abstract analysis.
    Be calm, direct, and practical.
    If he may be in immediate danger, encourage contacting local emergency services or a trusted nearby person right now.
    Do not romanticize self-destruction, isolation, or dependency.
    """

    private static func activeChatModeBlock(_ chatMode: ChatMode) -> String {
        "---\n\nACTIVE CHAT MODE: \(chatMode.label)\n\(chatMode.contextBlock)"
    }

    // MARK: - Context Assembly

    /// Output of prompt assembly, split into the slow-changing prefix that can ride the
    /// Gemini prompt cache and the per-turn block that must refresh every request.
    /// `combined` reconstructs the original single-string layout for non-cache callers.
    struct TurnSystemSlice: Equatable {
        let stable: String
        let volatile: String

        var combined: String {
            [stable, volatile].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
    }

    static func assembleContext(
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
        stable.append(summaryOutputPolicy)

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

    static func governanceTrace(
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
        var layers = ["anchor", "memory_interpretation_policy", "core_safety_policy", "summary_output_policy", "chat_mode"]
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

    private static func longGapConnectionGuidance(
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

    private static func preferredLongGapBridgeCitation(
        citations: [SearchResult],
        now: Date
    ) -> SearchResult? {
        citations.first {
            $0.lane == .longGap &&
            $0.similarity >= 0.62 &&
            ageDays(since: $0.node.createdAt, now: now) >= 45
        }
    }

    private static func ageDays(since createdAt: Date, now: Date) -> Int {
        let elapsed = max(0, now.timeIntervalSince(createdAt))
        return Int(elapsed / 86_400)
    }

    private static func userMessageContent(query: String, attachmentNames: [String]) -> String {
        guard !attachmentNames.isEmpty else { return query }
        return "\(query)\n\nFiles: \(attachmentNames.joined(separator: ", "))"
    }

    static func updatedQuickActionMode(
        currentMode: QuickActionMode?,
        assistantContent: String
    ) -> QuickActionMode? {
        guard let currentMode else { return nil }
        let parsed = ClarificationCardParser.parse(assistantContent)
        return parsed.keepsQuickActionMode ? currentMode : nil
    }

    static func shouldAllowInteractiveClarification(
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
    static func deriveProvocationKind(
        verdict: JudgeVerdict,
        contradictionCandidateIds: Set<String>
    ) -> ProvocationKind {
        guard verdict.shouldProvoke else { return .neutral }
        if let id = verdict.entryId, contradictionCandidateIds.contains(id) {
            return .contradiction
        }
        return .spark
    }

    static func quickActionOpeningPrompt(for mode: QuickActionMode) -> String {
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

    private func persistConversationSnapshot(
        for nodeId: UUID,
        messages: [Message],
        shouldRefreshEmoji: Bool = false
    ) {
        guard var node = try? nodeStore.fetchNode(id: nodeId) else { return }

        let transcript = messages
            .map { message in
                let role = message.role == .user ? "Alex" : "Nous"
                return "\(role): \(message.content)"
            }
            .joined(separator: "\n\n")

        node.content = transcript
        node.updatedAt = Date()

        if shouldRefreshEmoji {
            let currentEmoji = TopicEmojiResolver.storedEmoji(from: node.emoji)
            let shouldAskLLM = currentEmoji == nil || currentEmoji == TopicEmojiResolver.fallbackEmoji(for: .conversation)
            if shouldAskLLM {
                Task { [weak self] in
                    guard let self else { return }
                    let emoji = await resolveConversationEmoji(for: node, messages: messages)
                    guard var refreshedNode = try? nodeStore.fetchNode(id: nodeId) else { return }
                    refreshedNode.emoji = emoji
                    try? nodeStore.updateNode(refreshedNode)
                    let finalNode = refreshedNode
                    await MainActor.run {
                        if self.currentNode?.id == finalNode.id {
                            self.currentNode = finalNode
                        }
                        NotificationCenter.default.post(name: .nousNodesDidChange, object: nil)
                    }
                }
            } else {
                node.emoji = currentEmoji
            }
        }

        try? nodeStore.updateNode(node)
        if currentNode?.id == node.id {
            currentNode = node
        }
        NotificationCenter.default.post(name: .nousNodesDidChange, object: nil)
    }

    private func resolveConversationEmoji(for node: NousNode, messages: [Message]) async -> String {
        let fallback = TopicEmojiResolver.emoji(for: node)
        guard let llm = llmServiceProvider() else { return fallback }

        let latestMessages = messages.suffix(4).map { message in
            let role = message.role == .user ? "Alex" : "Nous"
            return "\(role): \(message.content)"
        }.joined(separator: "\n\n")

        let prompt = """
        Pick exactly one emoji for the main topic of this conversation.
        Return one emoji only.
        Allowed emojis: \(TopicEmojiResolver.allowedEmojis.sorted().joined(separator: " "))

        Title: \(node.title)

        Conversation:
        \(latestMessages)
        """

        do {
            let stream = try await llm.generate(
                messages: [LLMMessage(role: "user", content: prompt)],
                system: "You classify conversation topics. Return exactly one emoji from the allowed list."
            )

            var output = ""
            for try await chunk in stream {
                output += chunk
                if let emoji = TopicEmojiResolver.storedEmoji(from: output) {
                    return emoji
                }
            }
        } catch {
            return fallback
        }

        return fallback
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
        guard let gemini = llm as? GeminiLLMService else { return nil }
        guard transcriptMessages.count >= 2 else { return nil }
        let prefixHash = GeminiPromptCacheService.promptHash(
            system: stableSystem,
            messages: Array(transcriptMessages.dropLast())
        )
        return geminiPromptCache.activeCache(for: nodeId, model: gemini.model, promptHash: prefixHash)
    }

    static func prefixedUserMessageContent(volatile: String, userContent: String) -> String {
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
        guard var gemini = llm as? GeminiLLMService else { return llm }

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

    @MainActor
    private func refreshGeminiConversationCacheIfNeeded(
        nodeId: UUID,
        llm: any LLMService,
        stableSystem: String,
        persistedMessages: [Message]
    ) {
        guard let gemini = llm as? GeminiLLMService else {
            geminiPromptCache.removeEntry(for: nodeId)
            cancelInFlightCacheRefresh(for: nodeId)
            return
        }

        let transcriptMessages = persistedMessages.map {
            LLMMessage(role: $0.role == .user ? "user" : "assistant", content: $0.content)
        }
        let existingEntry = geminiPromptCache.entry(for: nodeId)

        guard Self.shouldCreateGeminiHistoryCache(for: transcriptMessages) else {
            geminiPromptCache.removeEntry(for: nodeId)
            cancelInFlightCacheRefresh(for: nodeId)
            guard let existingEntry else { return }
            Task {
                try? await gemini.deleteCachedContent(name: existingEntry.name)
            }
            return
        }

        let promptHash = GeminiPromptCacheService.promptHash(
            system: stableSystem,
            messages: transcriptMessages
        )
        if let existingEntry,
           existingEntry.model == gemini.model,
           existingEntry.promptHash == promptHash,
           existingEntry.expireTime.map({ $0 > Date() }) ?? true {
            return
        }

        let oldCacheName = existingEntry?.name
        let displayName = "nous-\(nodeId.uuidString.prefix(8))"

        // Cancel any prior in-flight refresh for this conversation. Without this, a
        // slow earlier refresh completing after a newer one would overwrite the newer
        // entry and leak the newer server-side cache (oldCacheName captures from
        // `existingEntry` at spawn time, so the stale delete is correct either way).
        cancelInFlightCacheRefresh(for: nodeId)

        // Generation token: the worker only commits its result if this conversation's
        // token still matches at store time. If a newer refresh started and bumped the
        // token, this worker's cache handle is orphaned server-side and must be cleaned
        // up to avoid storage billing for a cache nobody will ever reference.
        let token = UUID()
        geminiCacheRefreshTokens[nodeId] = token

        let task = Task { [weak self] in
            do {
                let created = try await gemini.createCachedContent(
                    messages: transcriptMessages,
                    system: stableSystem,
                    ttlSeconds: 300,
                    displayName: displayName
                )
                try Task.checkCancellation()
                let committed = await MainActor.run { () -> Bool in
                    guard let self else { return false }
                    guard self.geminiCacheRefreshTokens[nodeId] == token else { return false }
                    self.geminiPromptCache.store(
                        GeminiConversationCacheEntry(
                            name: created.name,
                            model: created.model,
                            promptHash: promptHash,
                            expireTime: created.expireTime
                        ),
                        for: nodeId
                    )
                    return true
                }
                if committed {
                    if let oldCacheName, oldCacheName != created.name {
                        try? await gemini.deleteCachedContent(name: oldCacheName)
                    }
                } else {
                    // Superseded by a newer refresh. Drop our orphaned handle server-side
                    // so it isn't billed for the full TTL with nobody to reference it.
                    try? await gemini.deleteCachedContent(name: created.name)
                }
            } catch is CancellationError {
                return
            } catch {
                print("[gemini-cache] failed to refresh cached content: \(error)")
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.geminiCacheRefreshTokens[nodeId] == token {
                    self.geminiCacheRefreshTokens.removeValue(forKey: nodeId)
                    self.geminiCacheRefreshTasks.removeValue(forKey: nodeId)
                }
            }
        }
        geminiCacheRefreshTasks[nodeId] = task
    }

    @MainActor
    private func cancelInFlightCacheRefresh(for nodeId: UUID) {
        geminiCacheRefreshTasks[nodeId]?.cancel()
        geminiCacheRefreshTasks.removeValue(forKey: nodeId)
        geminiCacheRefreshTokens.removeValue(forKey: nodeId)
    }

    private static func shouldCreateGeminiHistoryCache(for messages: [LLMMessage]) -> Bool {
        guard messages.count >= 4 else { return false }
        let characterCount = messages.reduce(into: 0) { $0 += $1.content.count }
        // Gemini 2.5 Flash implicit caching starts at 1024 prompt tokens; use a
        // conservative char-count gate before paying an explicit cache-create call.
        return characterCount >= 4096
    }

    /// Routes refresh work through the scheduler actor so it serialises after
    /// the reply stream + persist step, avoiding MLX container contention on
    /// local models (v2.1 §5, Q9=B).
    private func scheduleUserMemoryRefresh(for node: NousNode, messages: [Message]) {
        let nodeId = node.id
        let projectId = node.projectId
        let snapshot = messages
        let shouldPersist = userMemoryService.shouldPersistMemory(messages: snapshot, projectId: projectId)
        if !shouldPersist {
            governanceTelemetry.recordMemoryStorageSuppressed()
            return
        }

        Task { [userMemoryScheduler] in
            await userMemoryScheduler.enqueueConversationRefresh(
                nodeId: nodeId,
                projectId: projectId,
                messages: snapshot
            )
        }
    }
}

extension ChatViewModel {

    /// Returns the judge event id for a given assistant message, if one was recorded
    /// for the turn that produced it AND the judge actually provoked.
    /// Returns nil for messages from non-provoked or pre-feature turns.
    @MainActor
    func judgeEventId(forMessageId messageId: UUID) -> UUID? {
        let events = governanceTelemetry.recentJudgeEvents(limit: 500, filter: .none)
        guard let match = events.first(where: { $0.messageId == messageId }),
              match.fallbackReason == .ok else { return nil }
        guard let verdictData = match.verdictJSON.data(using: .utf8),
              let verdict = try? JSONDecoder().decode(JudgeVerdict.self, from: verdictData),
              verdict.shouldProvoke else { return nil }
        return match.id
    }

    @MainActor
    func recordFeedback(forMessageId messageId: UUID, feedback: JudgeFeedback) {
        guard let eventId = judgeEventId(forMessageId: messageId) else { return }
        governanceTelemetry.recordFeedback(eventId: eventId, feedback: feedback)
    }
}
