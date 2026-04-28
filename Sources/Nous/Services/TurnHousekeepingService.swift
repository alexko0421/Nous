import Foundation

@MainActor
final class TurnHousekeepingService {
    private let nodeStore: NodeStore
    private let vectorStore: VectorStore
    private let embeddingService: EmbeddingService
    private let graphEngine: GraphEngine
    private let relationRefinementQueue: GalaxyRelationRefinementQueue?
    private let geminiPromptCache: GeminiPromptCacheService
    private let llmServiceProvider: () -> (any LLMService)?
    private let shouldUseGeminiHistoryCache: () -> Bool
    private let onConversationNodeUpdated: @MainActor (NousNode) -> Void
    private var geminiCacheRefreshTasks: [UUID: Task<Void, Never>] = [:]
    private var geminiCacheRefreshTokens: [UUID: UUID] = [:]

    init(
        nodeStore: NodeStore,
        vectorStore: VectorStore,
        embeddingService: EmbeddingService,
        graphEngine: GraphEngine,
        relationRefinementQueue: GalaxyRelationRefinementQueue? = nil,
        geminiPromptCache: GeminiPromptCacheService,
        llmServiceProvider: @escaping () -> (any LLMService)?,
        shouldUseGeminiHistoryCache: @escaping () -> Bool,
        onConversationNodeUpdated: @escaping @MainActor (NousNode) -> Void = { _ in }
    ) {
        self.nodeStore = nodeStore
        self.vectorStore = vectorStore
        self.embeddingService = embeddingService
        self.graphEngine = graphEngine
        self.relationRefinementQueue = relationRefinementQueue
        self.geminiPromptCache = geminiPromptCache
        self.llmServiceProvider = llmServiceProvider
        self.shouldUseGeminiHistoryCache = shouldUseGeminiHistoryCache
        self.onConversationNodeUpdated = onConversationNodeUpdated
    }

    func run(_ plan: TurnHousekeepingPlan) {
        if let emojiRefresh = plan.emojiRefresh {
            refreshConversationEmojiIfNeeded(
                for: emojiRefresh.node,
                messages: emojiRefresh.messages
            )
        }

        if let geminiCacheRefresh = plan.geminiCacheRefresh {
            refreshGeminiConversationCacheIfNeeded(
                nodeId: geminiCacheRefresh.nodeId,
                llm: llmServiceProvider(),
                stableSystem: geminiCacheRefresh.stableSystem,
                persistedMessages: geminiCacheRefresh.persistedMessages
            )
        }

        if let embeddingRefresh = plan.embeddingRefresh {
            refreshEmbeddingAndEdges(embeddingRefresh)
        }
    }

    func purgeGeminiHistoryCaches() async {
        for nodeId in Array(geminiCacheRefreshTasks.keys) {
            cancelInFlightCacheRefresh(for: nodeId)
        }

        let entries = geminiPromptCache.removeAllEntries()
        guard let gemini = llmServiceProvider() as? GeminiLLMService else { return }
        for entry in entries {
            try? await gemini.deleteCachedContent(name: entry.name)
        }
    }

    func clearGeminiHistoryCacheIfPresent(nodeId: UUID, llm: any LLMService) {
        let existingEntry = geminiPromptCache.removeEntry(for: nodeId)
        cancelInFlightCacheRefresh(for: nodeId)
        guard let gemini = llm as? GeminiLLMService, let existingEntry else { return }
        Task {
            try? await gemini.deleteCachedContent(name: existingEntry.name)
        }
    }

    private func refreshConversationEmojiIfNeeded(for node: NousNode, messages: [Message]) {
        let currentEmoji = TopicEmojiResolver.storedEmoji(from: node.emoji)
        let shouldAskLLM = currentEmoji == nil ||
            currentEmoji == TopicEmojiResolver.fallbackEmoji(for: .conversation)
        guard shouldAskLLM else { return }

        let nodeId = node.id
        Task { [weak self] in
            guard let self else { return }
            let emoji = await self.resolveConversationEmoji(for: node, messages: messages)
            guard var refreshedNode = try? self.nodeStore.fetchNode(id: nodeId) else { return }
            refreshedNode.emoji = emoji
            try? self.nodeStore.updateNode(refreshedNode)
            await self.onConversationNodeUpdated(refreshedNode)
        }
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
        } catch {}

        return fallback
    }

    private func refreshGeminiConversationCacheIfNeeded(
        nodeId: UUID,
        llm: (any LLMService)?,
        stableSystem: String,
        persistedMessages: [Message]
    ) {
        guard shouldUseGeminiHistoryCache() else {
            if let llm {
                clearGeminiHistoryCacheIfPresent(nodeId: nodeId, llm: llm)
            } else {
                _ = geminiPromptCache.removeEntry(for: nodeId)
                cancelInFlightCacheRefresh(for: nodeId)
            }
            return
        }

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
        cancelInFlightCacheRefresh(for: nodeId)

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

    private func cancelInFlightCacheRefresh(for nodeId: UUID) {
        geminiCacheRefreshTasks[nodeId]?.cancel()
        geminiCacheRefreshTasks.removeValue(forKey: nodeId)
        geminiCacheRefreshTokens.removeValue(forKey: nodeId)
    }

    private static func shouldCreateGeminiHistoryCache(for messages: [LLMMessage]) -> Bool {
        guard messages.count >= 4 else { return false }
        let characterCount = messages.reduce(into: 0) { $0 += $1.content.count }
        return characterCount >= 4096
    }

    private func refreshEmbeddingAndEdges(_ request: EmbeddingRefreshRequest) {
        let nodeId = request.nodeId
        let fullContent = request.fullContent
        let embeddingService = self.embeddingService
        let vectorStore = self.vectorStore
        let nodeStore = self.nodeStore
        let graphEngine = self.graphEngine
        let relationRefinementQueue = self.relationRefinementQueue

        Task.detached(priority: .background) {
            if let embedding = try? embeddingService.embed(fullContent) {
                try? vectorStore.storeEmbedding(embedding, for: nodeId)
                if var updatedNode = try? nodeStore.fetchNode(id: nodeId) {
                    updatedNode.embedding = embedding
                    try? graphEngine.regenerateEdges(for: updatedNode)
                    relationRefinementQueue?.enqueue(nodeId: nodeId)
                }
            }
        }
    }
}
