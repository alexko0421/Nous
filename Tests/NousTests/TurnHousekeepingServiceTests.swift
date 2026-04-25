import XCTest
@testable import Nous

@MainActor
final class TurnHousekeepingServiceTests: XCTestCase {
    func testRunClearsGeminiCacheWhenHistoryCacheDisabled() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let promptCache = GeminiPromptCacheService()
        let conversationId = UUID()

        promptCache.store(
            GeminiConversationCacheEntry(
                name: "cachedContents/test",
                model: "gemini-2.5-flash",
                promptHash: "abc",
                expireTime: Date().addingTimeInterval(300)
            ),
            for: conversationId
        )

        let service = TurnHousekeepingService(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: EmbeddingService(),
            graphEngine: graphEngine,
            geminiPromptCache: promptCache,
            llmServiceProvider: { nil },
            shouldUseGeminiHistoryCache: { false }
        )

        service.run(
            TurnHousekeepingPlan(
                turnId: UUID(),
                conversationId: conversationId,
                geminiCacheRefresh: GeminiCacheRefreshRequest(
                    nodeId: conversationId,
                    stableSystem: "stable",
                    persistedMessages: [Message(nodeId: conversationId, role: .user, content: "hello")]
                ),
                embeddingRefresh: nil,
                emojiRefresh: nil
            )
        )

        XCTAssertNil(promptCache.entry(for: conversationId))
    }
}
