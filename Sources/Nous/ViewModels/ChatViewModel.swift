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
    }

    func loadConversation(_ node: NousNode) {
        currentNode = node
        messages = (try? nodeStore.fetchMessages(nodeId: node.id)) ?? []
        citations = []
        currentResponse = ""
    }

    // MARK: - Send (RAG Pipeline)

    func send() async {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isGenerating else { return }

        inputText = ""
        isGenerating = true
        currentResponse = ""
        defer { isGenerating = false }

        // Step 1: Create conversation node if nil
        if currentNode == nil {
            let title = String(query.prefix(40))
            startNewConversation(title: title)
        }

        guard let node = currentNode else { return }

        // Step 2: Save user message
        let userMessage = Message(nodeId: node.id, role: .user, content: query)
        try? nodeStore.insertMessage(userMessage)
        messages.append(userMessage)

        // Step 3: Embed query and search for citations
        if embeddingService.isLoaded {
            if let queryEmbedding = try? embeddingService.embed(query) {
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
        let context = ChatViewModel.assembleContext(citations: citations, projectGoal: projectGoal)

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

        // Step 9: Parse tags and save assistant message
        let parsed = ResponseTagParser.parse(currentResponse)
        switch parsed {
        case .defer_:
            // Nous chose silence. Do not append a message; keep composer active.
            currentResponse = ""
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

        case .plain(let text):
            let assistantMessage = Message(
                nodeId: node.id,
                role: .assistant,
                content: text
            )
            try? nodeStore.insertMessage(assistantMessage)
            messages.append(assistantMessage)
        }

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

    static func assembleContext(citations: [SearchResult], projectGoal: String?) -> String {
        var parts: [String] = []

        // Layer 1: Anchor — who Nous is (immutable)
        parts.append(anchor)

        // Layer 2: Project context (if active)
        if let goal = projectGoal, !goal.isEmpty {
            parts.append("---\n\nCURRENT PROJECT GOAL: \(goal)")
        }

        // Layer 3: Retrieved knowledge (RAG)
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
}
