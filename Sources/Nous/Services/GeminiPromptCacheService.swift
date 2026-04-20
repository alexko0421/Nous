import CryptoKit
import Foundation

struct GeminiConversationCacheEntry: Equatable {
    let name: String
    let model: String
    let promptHash: String
    let expireTime: Date?
}

final class GeminiPromptCacheService {
    private var entries: [UUID: GeminiConversationCacheEntry] = [:]

    func activeCache(
        for conversationId: UUID,
        model: String,
        promptHash: String,
        now: Date = Date()
    ) -> GeminiConversationCacheEntry? {
        guard let entry = entries[conversationId] else { return nil }
        if let expireTime = entry.expireTime, expireTime <= now {
            entries.removeValue(forKey: conversationId)
            return nil
        }
        guard entry.model == model, entry.promptHash == promptHash else { return nil }
        return entry
    }

    func entry(for conversationId: UUID) -> GeminiConversationCacheEntry? {
        entries[conversationId]
    }

    func store(_ entry: GeminiConversationCacheEntry, for conversationId: UUID) {
        entries[conversationId] = entry
    }

    @discardableResult
    func removeEntry(for conversationId: UUID) -> GeminiConversationCacheEntry? {
        entries.removeValue(forKey: conversationId)
    }

    /// Canonical hash for a cache entry. Inputs:
    /// - `system`: the stable system prefix that was frozen into `cachedContents`.
    ///   Volatile per-turn blocks (citations, chat mode, focus) MUST be excluded —
    ///   the cache wouldn't survive a single turn otherwise.
    /// - `messages`: the transcript prefix that was cached. For lookups the caller
    ///   drops the current user turn; for refresh the caller passes the full new
    ///   persisted transcript.
    static func promptHash(system: String, messages: [LLMMessage]) -> String {
        digest(system + "\u{1D}" + messages
            .map { "\($0.role)\u{1F}\($0.content)" }
            .joined(separator: "\u{1E}"))
    }

    private static func digest(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
