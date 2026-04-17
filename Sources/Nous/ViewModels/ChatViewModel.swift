import Foundation
import Observation

struct ThinkingTrace {
    let text: String
    let seconds: Double
}

@Observable
final class ChatViewModel {

    // MARK: - State

    var currentNode: NousNode?
    var messages: [Message] = []
    var inputText: String = ""
    var isGenerating: Bool = false
    var currentResponse: String = ""
    var currentThinking: String = ""
    var currentThinkingSeconds: Double? = nil
    var thinkingByMessageId: [UUID: ThinkingTrace] = [:]
    var citations: [SearchResult] = []

    // MARK: - Dependencies

    private let nodeStore: NodeStore
    private let vectorStore: VectorStore
    private let embeddingService: EmbeddingService
    private let graphEngine: GraphEngine
    private let llmServiceProvider: () -> (any LLMService)?

    // MARK: - Init

    init(
        nodeStore: NodeStore,
        vectorStore: VectorStore,
        embeddingService: EmbeddingService,
        graphEngine: GraphEngine,
        llmServiceProvider: @escaping () -> (any LLMService)?
    ) {
        self.nodeStore = nodeStore
        self.vectorStore = vectorStore
        self.embeddingService = embeddingService
        self.graphEngine = graphEngine
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
        currentThinking = ""
        currentThinkingSeconds = nil
        thinkingByMessageId = [:]
    }

    func loadConversation(_ node: NousNode) {
        currentNode = node
        messages = (try? nodeStore.fetchMessages(nodeId: node.id)) ?? []
        citations = []
        currentResponse = ""
        currentThinking = ""
        currentThinkingSeconds = nil
        thinkingByMessageId = [:]
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
        currentThinking = ""
        currentThinkingSeconds = nil
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

        // Step 5: Assemble context
        let context = ChatViewModel.assembleContext(
            citations: citations,
            projectGoal: projectGoal,
            attachments: attachments
        )

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
            return
        }

        // Step 8: Stream response
        var thinkingStartedAt: Date? = nil
        var thinkingEndedAt: Date? = nil
        do {
            let stream = try await llm.generate(messages: llmMessages, system: context)
            for try await chunk in stream {
                switch chunk {
                case .thought(let text):
                    if thinkingStartedAt == nil { thinkingStartedAt = Date() }
                    currentThinking += text
                case .answer(let text):
                    if let start = thinkingStartedAt, thinkingEndedAt == nil {
                        thinkingEndedAt = Date()
                        currentThinkingSeconds = Date().timeIntervalSince(start)
                    }
                    currentResponse += text
                }
            }
            if let start = thinkingStartedAt, thinkingEndedAt == nil {
                currentThinkingSeconds = Date().timeIntervalSince(start)
            }
        } catch {
            currentResponse = "Error: \(error.localizedDescription)"
        }

        // Step 9: Parse tags and save assistant message
        let parsed = ResponseTagParser.parse(currentResponse)
        let capturedThinking = currentThinking
        let capturedSeconds = currentThinkingSeconds ?? 0
        switch parsed {
        case .defer_:
            // Nous chose silence. Do not append a message; keep composer active.
            currentResponse = ""
            currentThinking = ""
            currentThinkingSeconds = nil
            return

        case .card(let payload):
            let assistantMessage = Message(
                nodeId: node.id,
                role: .assistant,
                content: payload.framing,
                cardPayload: payload
            )
            try? nodeStore.insertMessage(assistantMessage)
            messages.append(assistantMessage)
            if !capturedThinking.isEmpty {
                thinkingByMessageId[assistantMessage.id] = ThinkingTrace(text: capturedThinking, seconds: capturedSeconds)
            }

        case .plain(let text):
            let assistantMessage = Message(
                nodeId: node.id,
                role: .assistant,
                content: text
            )
            try? nodeStore.insertMessage(assistantMessage)
            messages.append(assistantMessage)
            if !capturedThinking.isEmpty {
                thinkingByMessageId[assistantMessage.id] = ThinkingTrace(text: capturedThinking, seconds: capturedSeconds)
            }
        }
        currentThinking = ""
        currentThinkingSeconds = nil

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
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            print("[Nous] WARNING: anchor.md not found in bundle, using fallback")
            return "You are Nous, Alex 最信任嘅朋友。用广东话回应，语气好似同好朋友倾偈咁。Be warm, genuine, and direct."
        }
        print("[Nous] Anchor loaded: \(content.prefix(80))...")
        return content
    }()

    // MARK: - Context Assembly

    static func assembleContext(
        citations: [SearchResult],
        projectGoal: String?,
        attachments: [AttachedFileContext] = []
    ) -> String {
        var parts: [String] = []

        // Layer 1: Anchor — who Nous is (immutable)
        parts.append(anchor)

        // Layer 2: Project context (if active)
        if let goal = projectGoal, !goal.isEmpty {
            parts.append("---\n\nCURRENT PROJECT GOAL: \(goal)")
        }

        // Layer 3: Attached files (if any)
        if !attachments.isEmpty {
            parts.append("---\n\nATTACHED FILES:")
            for attachment in attachments {
                if let extractedText = attachment.extractedText, !extractedText.isEmpty {
                    let snippet = String(extractedText.prefix(4_000))
                    parts.append("FILE: \(attachment.name)\n\(snippet)")
                } else {
                    parts.append("FILE: \(attachment.name)\nContent preview unavailable. Ask Alex for the relevant excerpt if more detail is needed.")
                }
            }
        }

        // Layer 4: Retrieved knowledge (RAG)
        if !citations.isEmpty {
            parts.append("---\n\nRELEVANT KNOWLEDGE FROM ALEX'S NOTES AND CONVERSATIONS:")
            for (index, result) in citations.enumerated() {
                let percent = Int(result.similarity * 100)
                let snippet = String(result.node.content.prefix(300))
                parts.append("[\(index + 1)] \"\(result.node.title)\" (\(percent)% relevance): \(snippet)")
            }
            parts.append("Reference the above when relevant. Cite by title. If knowledge contradicts something Alex said before, surface the tension.")
        }

        return parts.joined(separator: "\n\n")
    }

    private static func userMessageContent(query: String, attachmentNames: [String]) -> String {
        guard !attachmentNames.isEmpty else { return query }
        return "\(query)\n\nFiles: \(attachmentNames.joined(separator: ", "))"
    }
}
