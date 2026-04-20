import XCTest
@testable import Nous

final class GeminiPromptCacheServiceTests: XCTestCase {

    private let stableSystem = "You are Nous. Stable memory + identity."
    private let messages = [
        LLMMessage(role: "user", content: "Hello"),
        LLMMessage(role: "assistant", content: "Hi")
    ]

    func testActiveCacheHitsWhenStableSystemAndTranscriptMatch() {
        let service = GeminiPromptCacheService()
        let conversationId = UUID()
        let hash = GeminiPromptCacheService.promptHash(system: stableSystem, messages: messages)

        service.store(
            GeminiConversationCacheEntry(
                name: "cachedContents/abc",
                model: "gemini-2.5-flash",
                promptHash: hash,
                expireTime: Date().addingTimeInterval(60)
            ),
            for: conversationId
        )

        let active = service.activeCache(
            for: conversationId,
            model: "gemini-2.5-flash",
            promptHash: hash
        )

        XCTAssertEqual(active?.name, "cachedContents/abc")
    }

    func testActiveCacheEvictsExpiredEntries() {
        let service = GeminiPromptCacheService()
        let conversationId = UUID()

        service.store(
            GeminiConversationCacheEntry(
                name: "cachedContents/expired",
                model: "gemini-2.5-flash",
                promptHash: "hash",
                expireTime: Date(timeIntervalSince1970: 10)
            ),
            for: conversationId
        )

        let active = service.activeCache(
            for: conversationId,
            model: "gemini-2.5-flash",
            promptHash: "hash",
            now: Date(timeIntervalSince1970: 11)
        )

        XCTAssertNil(active)
        XCTAssertNil(service.entry(for: conversationId))
    }

    func testActiveCacheMissesWhenModelMismatches() {
        let service = GeminiPromptCacheService()
        let conversationId = UUID()
        let hash = GeminiPromptCacheService.promptHash(system: stableSystem, messages: messages)

        service.store(
            GeminiConversationCacheEntry(
                name: "cachedContents/abc",
                model: "gemini-2.5-flash",
                promptHash: hash,
                expireTime: Date().addingTimeInterval(60)
            ),
            for: conversationId
        )

        let active = service.activeCache(
            for: conversationId,
            model: "gemini-2.5-pro",
            promptHash: hash
        )

        XCTAssertNil(active)
    }

    func testPromptHashChangesWhenStableSystemChanges() {
        // Regression guard: hash must cover the system prompt, otherwise a changed
        // memory layer would silently reuse a stale cache and leak outdated context.
        let hashA = GeminiPromptCacheService.promptHash(
            system: stableSystem,
            messages: messages
        )
        let hashB = GeminiPromptCacheService.promptHash(
            system: stableSystem + "\n\nNEW MEMORY LAYER",
            messages: messages
        )

        XCTAssertNotEqual(hashA, hashB)
    }

    func testPromptHashChangesWhenTranscriptChanges() {
        let base = messages
        let changed = [
            LLMMessage(role: "user", content: "Hello"),
            LLMMessage(role: "assistant", content: "Hi again")
        ]

        XCTAssertNotEqual(
            GeminiPromptCacheService.promptHash(system: stableSystem, messages: base),
            GeminiPromptCacheService.promptHash(system: stableSystem, messages: changed)
        )
    }
}
