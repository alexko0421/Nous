import Foundation

struct GeminiCacheSnapshot: Codable, Equatable {
    let usage: GeminiUsageMetadata
    let recordedAt: Date

    var cacheHitRate: Double? {
        usage.cacheHitRate
    }
}

struct GeminiCacheSummary: Equatable {
    let requestCount: Int
    let totalPromptTokens: Int
    let totalCachedTokens: Int
    let lastSnapshot: GeminiCacheSnapshot?

    var cacheHitRate: Double? {
        guard totalPromptTokens > 0 else { return nil }
        return Double(totalCachedTokens) / Double(totalPromptTokens)
    }
}

final class GovernanceTelemetryStore {
    private let defaults: UserDefaults
    private let nodeStore: NodeStore?

    private enum Keys {
        static let lastPromptTrace = "nous.governance.lastPromptTrace"

        static func counter(_ counter: EvalCounter) -> String {
            "nous.governance.counter.\(counter.rawValue)"
        }

        static let memoryStorageSuppressedCount = "nous.governance.memoryStorageSuppressedCount"
        static let lastGeminiCacheSnapshot = "nous.governance.lastGeminiCacheSnapshot"
        static let geminiCacheRequestCount = "nous.governance.geminiCacheRequestCount"
        static let geminiCachePromptTokens = "nous.governance.geminiCachePromptTokens"
        static let geminiCacheHitTokens = "nous.governance.geminiCacheHitTokens"
    }

    init(defaults: UserDefaults = .standard, nodeStore: NodeStore? = nil) {
        self.defaults = defaults
        self.nodeStore = nodeStore
    }

    var lastPromptTrace: PromptGovernanceTrace? {
        guard let data = defaults.data(forKey: Keys.lastPromptTrace) else { return nil }
        return try? JSONDecoder().decode(PromptGovernanceTrace.self, from: data)
    }

    func recordPromptTrace(_ trace: PromptGovernanceTrace) {
        if let data = try? JSONEncoder().encode(trace) {
            defaults.set(data, forKey: Keys.lastPromptTrace)
        }

        if trace.promptLayers.contains(where: { $0 != "anchor" && $0 != "core_safety_policy" }) {
            increment(.memoryUsefulness)
        }

        if trace.highRiskQueryDetected && !trace.safetyPolicyInvoked {
            increment(.safetyMissRate)
        }
    }

    func increment(_ counter: EvalCounter, by amount: Int = 1) {
        let key = Keys.counter(counter)
        defaults.set(defaults.integer(forKey: key) + amount, forKey: key)
    }

    func value(for counter: EvalCounter) -> Int {
        defaults.integer(forKey: Keys.counter(counter))
    }

    func recordMemoryStorageSuppressed() {
        defaults.set(defaults.integer(forKey: Keys.memoryStorageSuppressedCount) + 1, forKey: Keys.memoryStorageSuppressedCount)
    }

    func memoryStorageSuppressedCount() -> Int {
        defaults.integer(forKey: Keys.memoryStorageSuppressedCount)
    }

    func recordGeminiUsage(_ usage: GeminiUsageMetadata, at date: Date = Date()) {
        let snapshot = GeminiCacheSnapshot(usage: usage, recordedAt: date)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Keys.lastGeminiCacheSnapshot)
        }

        defaults.set(defaults.integer(forKey: Keys.geminiCacheRequestCount) + 1, forKey: Keys.geminiCacheRequestCount)
        defaults.set(defaults.integer(forKey: Keys.geminiCachePromptTokens) + usage.promptTokenCount, forKey: Keys.geminiCachePromptTokens)
        defaults.set(defaults.integer(forKey: Keys.geminiCacheHitTokens) + usage.cachedContentTokenCount, forKey: Keys.geminiCacheHitTokens)
    }

    var lastGeminiCacheSnapshot: GeminiCacheSnapshot? {
        guard let data = defaults.data(forKey: Keys.lastGeminiCacheSnapshot) else { return nil }
        return try? JSONDecoder().decode(GeminiCacheSnapshot.self, from: data)
    }

    var geminiCacheSummary: GeminiCacheSummary? {
        let requestCount = defaults.integer(forKey: Keys.geminiCacheRequestCount)
        let totalPromptTokens = defaults.integer(forKey: Keys.geminiCachePromptTokens)
        let totalCachedTokens = defaults.integer(forKey: Keys.geminiCacheHitTokens)
        let lastSnapshot = lastGeminiCacheSnapshot

        guard requestCount > 0 || lastSnapshot != nil else { return nil }
        return GeminiCacheSummary(
            requestCount: requestCount,
            totalPromptTokens: totalPromptTokens,
            totalCachedTokens: totalCachedTokens,
            lastSnapshot: lastSnapshot
        )
    }

    // MARK: - Judge event API (SQLite-backed)

    /// Append a judge verdict event. Silently no-op if nodeStore wasn't injected
    /// (e.g. pre-wiring unit tests); orchestrator and production always pass one.
    func appendJudgeEvent(_ event: JudgeEvent) {
        guard let nodeStore else { return }
        do { try nodeStore.appendJudgeEvent(event) }
        catch { print("[governance] failed to append judge event: \(error)") }
    }

    /// Patch a previously-appended event with the user's 👍/👎 feedback.
    func recordFeedback(eventId: UUID, feedback: JudgeFeedback) {
        guard let nodeStore else { return }
        do { try nodeStore.updateJudgeEventFeedback(id: eventId, feedback: feedback, at: Date()) }
        catch { print("[governance] failed to update feedback: \(error)") }
    }

    func recordFeedback(
        eventId: UUID,
        feedback: JudgeFeedback,
        reason: JudgeFeedbackReason?,
        note: String?
    ) {
        guard let nodeStore else { return }
        do {
            try nodeStore.updateJudgeEventFeedback(
                id: eventId,
                feedback: feedback,
                reason: reason,
                note: note,
                at: Date()
            )
        }
        catch { print("[governance] failed to update detailed feedback: \(error)") }
    }

    func clearFeedback(eventId: UUID) {
        guard let nodeStore else { return }
        do { try nodeStore.clearJudgeEventFeedback(id: eventId) }
        catch { print("[governance] failed to update feedback: \(error)") }
    }

    /// For the inspector review panel and ad-hoc debugging.
    func recentJudgeEvents(limit: Int, filter: JudgeEventFilter) -> [JudgeEvent] {
        guard let nodeStore else { return [] }
        return (try? nodeStore.recentJudgeEvents(limit: limit, filter: filter)) ?? []
    }
}
