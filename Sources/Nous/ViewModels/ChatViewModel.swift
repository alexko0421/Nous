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

    // MARK: - Dependencies

    private let nodeStore: NodeStore
    private let vectorStore: VectorStore
    private let embeddingService: EmbeddingService
    private let graphEngine: GraphEngine
    private let userMemoryService: UserMemoryService
    private let userMemoryScheduler: UserMemoryScheduler
    private let llmServiceProvider: () -> (any LLMService)?

    // MARK: - Init

    init(
        nodeStore: NodeStore,
        vectorStore: VectorStore,
        embeddingService: EmbeddingService,
        graphEngine: GraphEngine,
        userMemoryService: UserMemoryService,
        userMemoryScheduler: UserMemoryScheduler,
        llmServiceProvider: @escaping () -> (any LLMService)?
    ) {
        self.nodeStore = nodeStore
        self.vectorStore = vectorStore
        self.embeddingService = embeddingService
        self.graphEngine = graphEngine
        self.userMemoryService = userMemoryService
        self.userMemoryScheduler = userMemoryScheduler
        self.llmServiceProvider = llmServiceProvider
    }

    // MARK: - Conversation Management

    func startNewConversation(title: String = "New Conversation", projectId: UUID? = nil) {
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
        NotificationCenter.default.post(name: .nousNodesDidChange, object: nil)
    }

    func loadConversation(_ node: NousNode) {
        currentNode = node
        messages = (try? nodeStore.fetchMessages(nodeId: node.id)) ?? []
        citations = []
        currentResponse = ""
        activeQuickActionMode = nil
    }

    func activateQuickActionMode(_ mode: QuickActionMode) {
        activeQuickActionMode = mode
    }

    func beginQuickActionConversation(_ mode: QuickActionMode) async {
        guard !isGenerating else { return }

        startNewConversation(title: mode.label)
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
            globalMemory: userMemoryService.currentGlobal(),
            projectMemory: node.projectId.flatMap { userMemoryService.currentProject(projectId: $0) },
            conversationMemory: userMemoryService.currentConversation(nodeId: node.id),
            recentConversations: [],
            citations: [],
            projectGoal: projectGoal,
            activeQuickActionMode: mode,
            allowInteractiveClarification: false
        )

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
            startNewConversation(title: title)
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

        let recentConversations = (try? nodeStore.fetchRecentConversations(
            limit: 2,
            excludingId: node.id
        )) ?? []

        // Step 5: Assemble context
        let shouldAllowInteractiveClarification = activeQuickActionMode != nil

        let context = ChatViewModel.assembleContext(
            globalMemory: userMemoryService.currentGlobal(),
            projectMemory: node.projectId.flatMap { userMemoryService.currentProject(projectId: $0) },
            conversationMemory: userMemoryService.currentConversation(nodeId: node.id),
            recentConversations: recentConversations,
            citations: citations,
            projectGoal: projectGoal,
            attachments: attachments,
            activeQuickActionMode: activeQuickActionMode,
            allowInteractiveClarification: shouldAllowInteractiveClarification
        )

        // Step 6: Build LLMMessage array from conversation history
        var llmMessages: [LLMMessage] = messages.map { msg in
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
            let stream = try await llm.generate(messages: llmMessages, system: context)
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
        persistConversationSnapshot(for: node.id, messages: messages, shouldRefreshEmoji: true)
        activeQuickActionMode = ChatViewModel.updatedQuickActionMode(
            currentMode: activeQuickActionMode,
            assistantContent: assistantContent
        )
        scheduleUserMemoryRefresh(for: node, messages: messages)

        // Step 10: Async task — update node embedding + regenerate edges
        let nodeId = node.id
        let fullContent = messages.map(\.content).joined(separator: "\n")
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            if let embedding = try? embeddingService.embed(fullContent) {
                try? vectorStore.storeEmbedding(embedding, for: nodeId)
                if var updatedNode = try? nodeStore.fetchNode(id: nodeId) {
                    updatedNode.embedding = embedding
                    try? graphEngine.regenerateEdges(for: updatedNode)
                }
            }
        }
    }

    // MARK: - Anchor (Core Identity)

    /// Loads the anchor document — Nous's immutable core identity and thinking methods.
    /// This is who Nous is. It does not change with context.
    private static let anchor: String = {
        guard let url = Bundle.main.url(forResource: "anchor", withExtension: "md"),
              let content = try? String(contentsOf: url) else {
            print("[Nous] WARNING: anchor.md not found in bundle, using fallback")
            return "You are Nous, Alex 最信任嘅朋友。用广东话回应，语气好似同好朋友倾偈咁。Be warm, genuine, and direct."
        }
        print("[Nous] Anchor loaded: \(content.prefix(80))...")
        return content
    }()

    // MARK: - Context Assembly

    static func assembleContext(
        globalMemory: String?,
        projectMemory: String?,
        conversationMemory: String?,
        recentConversations: [NousNode],
        citations: [SearchResult],
        projectGoal: String?,
        attachments: [AttachedFileContext] = [],
        activeQuickActionMode: QuickActionMode? = nil,
        allowInteractiveClarification: Bool = false
    ) -> String {
        var parts: [String] = []

        // Layer 1: Anchor — who Nous is (immutable)
        parts.append(anchor)

        // Layer 2a: Global identity memory (across all chats)
        if let globalMemory, !globalMemory.isEmpty {
            parts.append("---\n\nLONG-TERM MEMORY ABOUT ALEX:\n\(globalMemory)")
        }

        // Layer 2b: Project memory (only when this chat has a projectId)
        if let projectMemory, !projectMemory.isEmpty {
            parts.append("---\n\nTHIS PROJECT'S CONTEXT:\n\(projectMemory)")
        }

        // Layer 2c: This chat's own thread memory
        if let conversationMemory, !conversationMemory.isEmpty {
            parts.append("---\n\nTHIS CHAT'S THREAD SO FAR:\n\(conversationMemory)")
        }

        // Layer 3: Project context (if active)
        if let goal = projectGoal, !goal.isEmpty {
            parts.append("---\n\nCURRENT PROJECT GOAL: \(goal)")
        }

        // Layer 4: Recent conversations for cross-window continuity
        if !recentConversations.isEmpty {
            parts.append("---\n\nRECENT CONVERSATIONS WITH ALEX:")
            for conversation in recentConversations {
                let snippet = String(conversation.content.prefix(280))
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
                    if currentNode?.id == refreshedNode.id {
                        currentNode = refreshedNode
                    }
                    NotificationCenter.default.post(name: .nousNodesDidChange, object: nil)
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
        Task { [userMemoryScheduler] in
            await userMemoryScheduler.enqueueConversationRefresh(
                nodeId: nodeId,
                projectId: projectId,
                messages: snapshot
            )
        }
    }
}
