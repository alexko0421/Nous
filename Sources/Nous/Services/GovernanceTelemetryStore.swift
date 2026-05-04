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

struct PromptTraceEvaluationMetrics: Equatable {
    let runCount: Int
    let failedRunCount: Int
    let warningRunCount: Int
    let findingCounts: [PromptTraceEvaluationFindingCode: Int]

    var passRate: Double {
        guard runCount > 0 else { return 0 }
        return Double(runCount - failedRunCount) / Double(runCount)
    }

    func findingCount(_ code: PromptTraceEvaluationFindingCode) -> Int {
        findingCounts[code, default: 0]
    }
}

struct TurnCognitionTelemetrySummary: Equatable {
    let totalTurnCount: Int
    let slowCognitionAttachedCount: Int
    let slowCognitionSourcedCount: Int
    let reviewedTurnCount: Int
    let conversationRecoveryTurnCount: Int
    let reviewRiskFlagCounts: [String: Int]
    let lastSnapshot: TurnCognitionSnapshot?

    var slowCognitionAttachmentRate: Double {
        rate(slowCognitionAttachedCount, of: totalTurnCount)
    }

    var slowCognitionSourceCoverageRate: Double {
        rate(slowCognitionSourcedCount, of: slowCognitionAttachedCount)
    }

    var reviewCoverageRate: Double {
        rate(reviewedTurnCount, of: totalTurnCount)
    }

    var overInferenceRate: Double {
        rate(
            reviewRiskFlagCount("over_inference") + reviewRiskFlagCount("unsupported_memory_reference"),
            of: reviewedTurnCount
        )
    }

    func reviewRiskFlagCount(_ flag: String) -> Int {
        reviewRiskFlagCounts[flag, default: 0]
    }

    private func rate(_ numerator: Int, of denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return Double(numerator) / Double(denominator)
    }
}

final class GovernanceTelemetryStore {
    private static let recentTurnCognitionSnapshotLimit = 20

    private let defaults: UserDefaults
    private let nodeStore: NodeStore?

    private enum Keys {
        static let lastPromptTrace = "nous.governance.lastPromptTrace"
        static let lastPromptEvaluationSummary = "nous.governance.lastPromptEvaluationSummary"
        static let lastCognitionArtifact = "nous.governance.lastCognitionArtifact"
        static let lastConversationRecovery = "nous.governance.lastConversationRecovery"
        static let conversationRecoveryCount = "nous.governance.conversationRecoveryCount"
        static let lastTurnCognitionSnapshot = "nous.governance.lastTurnCognitionSnapshot"
        static let turnCognitionSnapshotCount = "nous.governance.turnCognitionSnapshotCount"
        static let turnCognitionSlowAttachedCount = "nous.governance.turnCognitionSlowAttachedCount"
        static let turnCognitionSlowSourcedCount = "nous.governance.turnCognitionSlowSourcedCount"
        static let turnCognitionReviewedTurnCount = "nous.governance.turnCognitionReviewedTurnCount"
        static let turnCognitionRecoveryTurnCount = "nous.governance.turnCognitionRecoveryTurnCount"
        static let turnCognitionRiskFlagCounts = "nous.governance.turnCognitionRiskFlagCounts"
        static let recentTurnCognitionSnapshots = "nous.governance.recentTurnCognitionSnapshots"

        static func counter(_ counter: EvalCounter) -> String {
            "nous.governance.counter.\(counter.rawValue)"
        }

        static let promptEvaluationRunCount = "nous.governance.promptEvaluation.runCount"
        static let promptEvaluationFailedRunCount = "nous.governance.promptEvaluation.failedRunCount"
        static let promptEvaluationWarningRunCount = "nous.governance.promptEvaluation.warningRunCount"
        static func promptEvaluationFindingCount(_ code: PromptTraceEvaluationFindingCode) -> String {
            "nous.governance.promptEvaluation.finding.\(code.rawValue)"
        }

        static let memoryStorageSuppressedCount = "nous.governance.memoryStorageSuppressedCount"
        static func memoryStorageSuppressedReasonCount(_ reason: MemorySuppressionReason) -> String {
            "nous.governance.memoryStorageSuppressedReason.\(reason.rawValue)"
        }

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

    var lastPromptEvaluationSummary: PromptTraceEvaluationSummary? {
        guard let data = defaults.data(forKey: Keys.lastPromptEvaluationSummary) else { return nil }
        return try? JSONDecoder().decode(PromptTraceEvaluationSummary.self, from: data)
    }

    var lastCognitionArtifact: CognitionArtifact? {
        guard let data = defaults.data(forKey: Keys.lastCognitionArtifact) else { return nil }
        return try? JSONDecoder().decode(CognitionArtifact.self, from: data)
    }

    var lastConversationRecovery: ConversationRecoveryTelemetryEvent? {
        guard let data = defaults.data(forKey: Keys.lastConversationRecovery) else { return nil }
        return try? JSONDecoder().decode(ConversationRecoveryTelemetryEvent.self, from: data)
    }

    var lastTurnCognitionSnapshot: TurnCognitionSnapshot? {
        guard let data = defaults.data(forKey: Keys.lastTurnCognitionSnapshot) else { return nil }
        return try? JSONDecoder().decode(TurnCognitionSnapshot.self, from: data)
    }

    func recordPromptTrace(_ trace: PromptGovernanceTrace) {
        if let data = try? JSONEncoder().encode(trace) {
            defaults.set(data, forKey: Keys.lastPromptTrace)
        }

        let evaluationSummary = PromptTraceEvaluationHarness().run([
            PromptTraceEvaluationCase(
                name: "last prompt trace",
                trace: trace,
                expectations: promptTraceEvaluationExpectations(for: trace)
            )
        ])
        if let data = try? JSONEncoder().encode(evaluationSummary) {
            defaults.set(data, forKey: Keys.lastPromptEvaluationSummary)
        }
        recordPromptEvaluation(evaluationSummary)

        if trace.hasMemorySignal {
            increment(.memoryUsefulness)
        }

        if trace.highRiskQueryDetected && !trace.safetyPolicyInvoked {
            increment(.safetyMissRate)
        }
    }

    func recordCognitionArtifact(_ artifact: CognitionArtifact) {
        guard (try? artifact.validated()) != nil,
              let data = try? JSONEncoder().encode(artifact) else {
            return
        }

        defaults.set(data, forKey: Keys.lastCognitionArtifact)
        if artifact.riskFlags.contains("unsupported_memory_reference") ||
            artifact.riskFlags.contains("over_inference") {
            increment(.overInferenceRate)
        }
    }

    func conversationRecoveryCount() -> Int {
        defaults.integer(forKey: Keys.conversationRecoveryCount)
    }

    func recordTurnCognitionSnapshot(_ snapshot: TurnCognitionSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Keys.lastTurnCognitionSnapshot)
        }
        recordRecentTurnCognitionSnapshot(snapshot)
        incrementIntegerKey(Keys.turnCognitionSnapshotCount)
        if snapshot.slowCognitionAttached {
            incrementIntegerKey(Keys.turnCognitionSlowAttachedCount)
        }
        if snapshot.slowCognitionAttached &&
            snapshot.slowCognitionArtifactId != nil &&
            snapshot.slowCognitionEvidenceRefCount > 0 {
            incrementIntegerKey(Keys.turnCognitionSlowSourcedCount)
        }
        if snapshot.reviewArtifactId != nil {
            incrementIntegerKey(Keys.turnCognitionReviewedTurnCount)
        }
        if snapshot.conversationRecoveryReason != nil || snapshot.conversationRecoveryRebasedMessageCount > 0 {
            incrementIntegerKey(Keys.turnCognitionRecoveryTurnCount)
        }
        recordReviewRiskFlags(snapshot.reviewRiskFlags)
    }

    func turnCognitionSnapshotCount() -> Int {
        defaults.integer(forKey: Keys.turnCognitionSnapshotCount)
    }

    var turnCognitionSummary: TurnCognitionTelemetrySummary {
        TurnCognitionTelemetrySummary(
            totalTurnCount: defaults.integer(forKey: Keys.turnCognitionSnapshotCount),
            slowCognitionAttachedCount: defaults.integer(forKey: Keys.turnCognitionSlowAttachedCount),
            slowCognitionSourcedCount: defaults.integer(forKey: Keys.turnCognitionSlowSourcedCount),
            reviewedTurnCount: defaults.integer(forKey: Keys.turnCognitionReviewedTurnCount),
            conversationRecoveryTurnCount: defaults.integer(forKey: Keys.turnCognitionRecoveryTurnCount),
            reviewRiskFlagCounts: storedReviewRiskFlagCounts(),
            lastSnapshot: lastTurnCognitionSnapshot
        )
    }

    func recentTurnCognitionSnapshots(limit: Int) -> [TurnCognitionSnapshot] {
        guard limit > 0 else { return [] }
        return Array(storedRecentTurnCognitionSnapshots().prefix(limit))
    }

    func increment(_ counter: EvalCounter, by amount: Int = 1) {
        let key = Keys.counter(counter)
        defaults.set(defaults.integer(forKey: key) + amount, forKey: key)
    }

    func value(for counter: EvalCounter) -> Int {
        defaults.integer(forKey: Keys.counter(counter))
    }

    var promptEvaluationMetrics: PromptTraceEvaluationMetrics {
        var findingCounts: [PromptTraceEvaluationFindingCode: Int] = [:]
        for code in PromptTraceEvaluationFindingCode.allCases {
            findingCounts[code] = defaults.integer(forKey: Keys.promptEvaluationFindingCount(code))
        }

        return PromptTraceEvaluationMetrics(
            runCount: defaults.integer(forKey: Keys.promptEvaluationRunCount),
            failedRunCount: defaults.integer(forKey: Keys.promptEvaluationFailedRunCount),
            warningRunCount: defaults.integer(forKey: Keys.promptEvaluationWarningRunCount),
            findingCounts: findingCounts
        )
    }

    private func promptTraceEvaluationExpectations(for trace: PromptGovernanceTrace) -> PromptTraceEvaluationExpectations {
        let citationQuality = trace.promptLayers.contains("citations")
            ? PromptTraceCitationExpectation(minimumSimilarity: 0.62, maximumLongGapShare: 0.5)
            : nil
        return PromptTraceEvaluationExpectations(citationQuality: citationQuality)
    }

    private func recordPromptEvaluation(_ summary: PromptTraceEvaluationSummary) {
        defaults.set(defaults.integer(forKey: Keys.promptEvaluationRunCount) + summary.results.count, forKey: Keys.promptEvaluationRunCount)
        defaults.set(defaults.integer(forKey: Keys.promptEvaluationFailedRunCount) + summary.results.filter { !$0.passed }.count, forKey: Keys.promptEvaluationFailedRunCount)
        defaults.set(defaults.integer(forKey: Keys.promptEvaluationWarningRunCount) + summary.results.filter { $0.findings.contains { $0.severity == .warning } }.count, forKey: Keys.promptEvaluationWarningRunCount)

        for finding in summary.results.flatMap(\.findings) {
            let key = Keys.promptEvaluationFindingCount(finding.code)
            defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
        }
    }

    private func incrementIntegerKey(_ key: String, by amount: Int = 1) {
        defaults.set(defaults.integer(forKey: key) + amount, forKey: key)
    }

    private func recordReviewRiskFlags(_ flags: [String]) {
        guard !flags.isEmpty else { return }
        var counts = storedReviewRiskFlagCounts()
        for flag in flags {
            counts[flag, default: 0] += 1
        }
        if let data = try? JSONEncoder().encode(counts) {
            defaults.set(data, forKey: Keys.turnCognitionRiskFlagCounts)
        }
    }

    private func storedReviewRiskFlagCounts() -> [String: Int] {
        guard let data = defaults.data(forKey: Keys.turnCognitionRiskFlagCounts),
              let counts = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return counts
    }

    private func recordRecentTurnCognitionSnapshot(_ snapshot: TurnCognitionSnapshot) {
        var snapshots = storedRecentTurnCognitionSnapshots()
        snapshots.insert(snapshot, at: 0)
        if snapshots.count > Self.recentTurnCognitionSnapshotLimit {
            snapshots = Array(snapshots.prefix(Self.recentTurnCognitionSnapshotLimit))
        }
        if let data = try? JSONEncoder().encode(snapshots) {
            defaults.set(data, forKey: Keys.recentTurnCognitionSnapshots)
        }
    }

    private func storedRecentTurnCognitionSnapshots() -> [TurnCognitionSnapshot] {
        guard let data = defaults.data(forKey: Keys.recentTurnCognitionSnapshots),
              let snapshots = try? JSONDecoder().decode([TurnCognitionSnapshot].self, from: data) else {
            return []
        }
        return snapshots
    }

    func recordMemoryStorageSuppressed(reason: MemorySuppressionReason = .unspecified) {
        defaults.set(defaults.integer(forKey: Keys.memoryStorageSuppressedCount) + 1, forKey: Keys.memoryStorageSuppressedCount)
        let reasonKey = Keys.memoryStorageSuppressedReasonCount(reason)
        defaults.set(defaults.integer(forKey: reasonKey) + 1, forKey: reasonKey)
    }

    func memoryStorageSuppressedCount() -> Int {
        defaults.integer(forKey: Keys.memoryStorageSuppressedCount)
    }

    func memoryStorageSuppressedCount(reason: MemorySuppressionReason) -> Int {
        defaults.integer(forKey: Keys.memoryStorageSuppressedReasonCount(reason))
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

extension GovernanceTelemetryStore: ConversationRecoveryTelemetryRecording {
    func recordConversationRecovery(_ event: ConversationRecoveryTelemetryEvent) {
        if let data = try? JSONEncoder().encode(event) {
            defaults.set(data, forKey: Keys.lastConversationRecovery)
        }
        defaults.set(defaults.integer(forKey: Keys.conversationRecoveryCount) + 1, forKey: Keys.conversationRecoveryCount)
    }
}
