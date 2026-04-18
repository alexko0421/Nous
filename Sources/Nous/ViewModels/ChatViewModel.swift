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
    private let governanceTelemetry: GovernanceTelemetryStore

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
        self.defaultProjectId = defaultProjectId
    }

    deinit {
        // VM teardown — make sure no judge task outlives us.
        inFlightJudgeTask?.cancel()
        inFlightJudgeTaskId = nil
    }

    // MARK: - Conversation Management

    @MainActor
    func startNewConversation(title: String = "New Conversation", projectId: UUID? = nil) {
        cancelInFlightJudge()  // any in-flight judge belonged to the old conversation
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
        activeQuickActionMode = nil
        activeChatMode = nil  // brand-new chat has no prior judgment
        NotificationCenter.default.post(name: .nousNodesDidChange, object: nil)
    }

    @MainActor
    func loadConversation(_ node: NousNode) {
        cancelInFlightJudge()  // switching conversations invalidates any pending verdict
        currentNode = node
        messages = (try? nodeStore.fetchMessages(nodeId: node.id)) ?? []
        citations = []
        currentResponse = ""
        activeQuickActionMode = nil
        activeChatMode = (try? nodeStore.latestChatMode(forNode: node.id)) ?? nil
    }

    func activateQuickActionMode(_ mode: QuickActionMode) {
        activeQuickActionMode = mode
    }

    @MainActor
    func beginQuickActionConversation(_ mode: QuickActionMode) async {
        guard !isGenerating else { return }

        startNewConversation(title: mode.label, projectId: defaultProjectId)
        activeQuickActionMode = mode
        inputText = ""

        guard let node = currentNode else { return }

        isGenerating = true
        currentResponse = ""
        defer { isGenerating = false }

        var projectGoal: String? = nil
        if let projectId = node.projectId,
           let project = try? nodeStore.fetchProject(id: projectId),
           !project.goal.isEmpty {
            projectGoal = project.goal
        }

        let context = ChatViewModel.assembleContext(
            chatMode: activeChatMode ?? .companion,
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
            chatMode: activeChatMode ?? .companion,
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
            let errorContent = "Please configure an LLM in Settings."
            let errorMessage = Message(nodeId: node.id, role: .assistant, content: errorContent)
            try? nodeStore.insertMessage(errorMessage)
            messages.append(errorMessage)
            persistConversationSnapshot(for: node.id, messages: messages)
            activeQuickActionMode = ChatViewModel.updatedQuickActionMode(
                currentMode: activeQuickActionMode,
                assistantContent: errorContent
            )
            return
        }

        do {
            let stream = try await llm.generate(
                messages: [
                    LLMMessage(
                        role: "user",
                        content: ChatViewModel.quickActionOpeningPrompt(for: mode)
                    )
                ],
                system: context
            )
            for try await chunk in stream {
                currentResponse += chunk
            }
        } catch {
            currentResponse = "Error: \(error.localizedDescription)"
        }

        let assistantContent = currentResponse
        let assistantMessage = Message(nodeId: node.id, role: .assistant, content: assistantContent)
        try? nodeStore.insertMessage(assistantMessage)
        messages.append(assistantMessage)
        persistConversationSnapshot(for: node.id, messages: messages, shouldRefreshEmoji: true)
        activeQuickActionMode = ChatViewModel.updatedQuickActionMode(
            currentMode: activeQuickActionMode,
            assistantContent: assistantContent
        )
        scheduleUserMemoryRefresh(for: node, messages: messages)
    }

    // MARK: - Send (RAG Pipeline)

    @MainActor
    func send(attachments: [AttachedFileContext] = []) async {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!query.isEmpty || !attachments.isEmpty), !isGenerating else { return }

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
        defer { isGenerating = false }

        // Step 1: Create conversation node if nil
        if currentNode == nil {
            let title = String(promptQuery.prefix(40))
            startNewConversation(title: title, projectId: defaultProjectId)
        }

        guard let node = currentNode else { return }

        // Step 2: Save user message
        let userMessage = Message(nodeId: node.id, role: .user, content: userMessageContent)
        try? nodeStore.insertMessage(userMessage)
        messages.append(userMessage)
        persistConversationSnapshot(for: node.id, messages: messages)

        // Step 3: Embed query and search for citations
        if embeddingService.isLoaded {
            if let queryEmbedding = try? embeddingService.embed(retrievalQuery) {
                let results = (try? vectorStore.search(
                    query: queryEmbedding,
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

        // Step A: Gather the citable pool (needed by the judge).
        let nodeHits = citations.map { $0.node.id }
        let citablePool = (try? userMemoryService.citableEntryPool(
            projectId: node.projectId,
            conversationId: node.id,
            nodeHits: nodeHits
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
                       let uuid = UUID(uuidString: entryIdStr),
                       let rawEntry = try? nodeStore.fetchMemoryEntry(id: uuid) {
                        profile = .provocative
                        focusBlock = ChatViewModel.buildFocusBlock(entryId: matched.id, rawText: rawEntry.content)
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

        // Step C: Decide the effective mode for this turn.
        let effectiveMode: ChatMode = inferredMode ?? (activeChatMode ?? .companion)

        // Step D: Assemble context + governance trace using effectiveMode.
        let shouldAllowInteractiveClarification = activeQuickActionMode != nil
        let context = ChatViewModel.assembleContext(
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

        // Step E: Compose final system prompt.
        var finalSystemParts: [String] = [context, profile.contextBlock]
        if let fb = focusBlock { finalSystemParts.append(fb) }
        let finalSystem = finalSystemParts.joined(separator: "\n\n")

        // Step F: Append the judge_events row using effectiveMode.
        // BEFORE the main call so the row survives main-call failure.
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
            let errorContent = "Please configure an LLM in Settings."
            let errorMessage = Message(nodeId: node.id, role: .assistant, content: errorContent)
            try? nodeStore.insertMessage(errorMessage)
            messages.append(errorMessage)
            activeQuickActionMode = ChatViewModel.updatedQuickActionMode(
                currentMode: activeQuickActionMode,
                assistantContent: errorContent
            )
            return
        }

        // Step 8: Stream response
        do {
            let stream = try await llm.generate(messages: llmMessages, system: finalSystem)
            for try await chunk in stream {
                currentResponse += chunk
            }
        } catch {
            currentResponse = "Error: \(error.localizedDescription)"
        }

        // Step 9: Save assistant message
        let assistantContent = currentResponse
        let assistantMessage = Message(nodeId: node.id, role: .assistant, content: assistantContent)
        try? nodeStore.insertMessage(assistantMessage)
        messages.append(assistantMessage)

        // Step 9b: patch the judge event with the message it produced
        try? nodeStore.updateJudgeEventMessageId(eventId: eventId, messageId: assistantMessage.id)
        persistConversationSnapshot(for: node.id, messages: messages, shouldRefreshEmoji: true)
        activeQuickActionMode = ChatViewModel.updatedQuickActionMode(
            currentMode: activeQuickActionMode,
            assistantContent: assistantContent
        )
        scheduleUserMemoryRefresh(for: node, messages: messages)

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

    // MARK: - Context Assembly

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
        allowInteractiveClarification: Bool = false
    ) -> String {
        var parts: [String] = []
        let highRiskSafetyMode = SafetyGuardrails.isHighRiskQuery(currentUserInput)

        // Layer 1: Anchor — who Nous is (immutable)
        parts.append(anchor)

        // Layer 2a: Global identity memory (across all chats)
        if let globalMemory, !globalMemory.isEmpty {
            parts.append("---\n\nLONG-TERM MEMORY ABOUT ALEX:\n\(globalMemory)")
        }

        // Layer 2b: bounded wake-up layer bridging identity and scoped recall.
        if let essentialStory, !essentialStory.isEmpty {
            parts.append("---\n\nBROADER SITUATION RIGHT NOW:\n\(essentialStory)")
        }

        // Layer 2c: Project memory (only when this chat has a projectId)
        if let projectMemory, !projectMemory.isEmpty {
            parts.append("---\n\nTHIS PROJECT'S CONTEXT:\n\(projectMemory)")
        }

        // Layer 2d: This chat's own thread memory
        if let conversationMemory, !conversationMemory.isEmpty {
            parts.append("---\n\nTHIS CHAT'S THREAD SO FAR:\n\(conversationMemory)")
        }

        // Layer 2e: bounded evidence backing the higher-priority memory layers.
        if !memoryEvidence.isEmpty {
            parts.append("---\n\nSHORT SOURCE EVIDENCE FOR THE ABOVE MEMORY:")
            for evidence in memoryEvidence {
                parts.append("- \(evidence.label) · \"\(evidence.sourceTitle)\": \(evidence.snippet)")
            }
        }

        parts.append(
            """
            ---

            MEMORY INTERPRETATION POLICY:
            If you notice a personal pattern, state it as a hypothesis unless Alex clearly confirmed it or it is strongly supported across multiple moments.
            Prefer wording like: "I might be wrong, but...", "One hypothesis is...", "Does this fit, or is something else more true?"
            Do not present diagnoses or identity labels as certainty.
            """
        )

        parts.append(
            """
            ---

            CORE SAFETY POLICY:
            Do not encourage Alex to become emotionally dependent on Nous.
            Do not present medical, psychological, or legal certainty when the situation is ambiguous.
            Respect memory boundaries: if Alex asks not to store something, or asked for consent before sensitive storage, do not silently turn that into durable memory.
            """
        )

        if highRiskSafetyMode {
            parts.append(
                """
                ---

                HIGH-RISK SAFETY MODE:
                Alex may be describing imminent danger, self-harm, abuse, or another acute safety issue.
                Prioritize immediate safety, grounding, and real-world human support over abstract analysis.
                Be calm, direct, and practical.
                If he may be in immediate danger, encourage contacting local emergency services or a trusted nearby person right now.
                Do not romanticize self-destruction, isolation, or dependency.
                """
            )
        }

        if let userModel,
           let promptBlock = userModel.promptBlock(includeIdentity: globalMemory?.isEmpty ?? true) {
            parts.append("---\n\nDERIVED USER MODEL:\n\(promptBlock)")
        }

        parts.append("---\n\nACTIVE CHAT MODE: \(chatMode.label)\n\(chatMode.contextBlock)")

        // Layer 3: Project context (if active)
        if let goal = projectGoal, !goal.isEmpty {
            parts.append("---\n\nCURRENT PROJECT GOAL: \(goal)")
        }

        // Layer 4: Recent conversations for cross-window continuity.
        // Uses active conversation memory entries (Alex-only,
        // evidence-filtered), NOT the raw transcript — raw content includes
        // Nous's own replies and would reintroduce self-confirmation across
        // chats. See Codex #4.
        if !recentConversations.isEmpty {
            parts.append("---\n\nRECENT CONVERSATIONS WITH ALEX:")
            for conversation in recentConversations {
                let snippet = String(conversation.memory.prefix(280))
                parts.append("\"\(conversation.title)\": \(snippet)")
            }
        }

        // Layer 5: Attached files (if any)
        if !attachments.isEmpty {
            parts.append("---\n\nATTACHED FILES:")
            for attachment in attachments {
                if let extractedText = attachment.extractedText, !extractedText.isEmpty {
                    parts.append("FILE: \(attachment.name)\n\(extractedText)")
                } else {
                    parts.append("FILE: \(attachment.name)\nContent preview unavailable. Ask Alex for the relevant excerpt if more detail is needed.")
                }
            }
        }

        // Layer 6: Retrieved knowledge (RAG)
        if !citations.isEmpty {
            parts.append("---\n\nRELEVANT KNOWLEDGE FROM ALEX'S NOTES AND CONVERSATIONS:")
            for (index, result) in citations.enumerated() {
                let percent = Int(result.similarity * 100)
                let snippet = String(result.node.content.prefix(300))
                parts.append("[\(index + 1)] \"\(result.node.title)\" (\(percent)% relevance): \(snippet)")
            }
            parts.append("Reference the above when relevant. Cite by title. If knowledge contradicts something Alex said before, surface the tension.")
        }

        if let activeQuickActionMode {
            parts.append("ACTIVE QUICK MODE: \(activeQuickActionMode.label)")
        }

        if allowInteractiveClarification {
            parts.append(
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
                - You may use more than one clarification turn if it is genuinely needed.
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

        return parts.joined(separator: "\n\n")
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
        allowInteractiveClarification: Bool = false
    ) -> PromptGovernanceTrace {
        var layers = ["anchor", "memory_interpretation_policy", "core_safety_policy", "chat_mode"]
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
                    refreshedNode.content = transcript
                    refreshedNode.updatedAt = Date()
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
        currentNode = node
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
