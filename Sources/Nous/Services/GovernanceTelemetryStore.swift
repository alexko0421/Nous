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

enum BehaviorEvalOutcome: String, Codable, Equatable {
    case continued
    case correction
    case retry
    case delete
}

struct BehaviorEvalEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let conversationId: UUID
    let assistantMessageId: UUID
    let userMessageId: UUID?
    let outcome: BehaviorEvalOutcome
    let latencySeconds: TimeInterval?
    let recordedAt: Date

    init(
        id: UUID = UUID(),
        conversationId: UUID,
        assistantMessageId: UUID,
        userMessageId: UUID?,
        outcome: BehaviorEvalOutcome,
        latencySeconds: TimeInterval? = nil,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.conversationId = conversationId
        self.assistantMessageId = assistantMessageId
        self.userMessageId = userMessageId
        self.outcome = outcome
        self.latencySeconds = latencySeconds
        self.recordedAt = recordedAt
    }
}

struct BehaviorEvalTelemetrySummary: Equatable {
    let totalOutcomeCount: Int
    let continuedCount: Int
    let correctionCount: Int
    let retryCount: Int
    let deleteCount: Int

    init(
        totalOutcomeCount: Int = 0,
        continuedCount: Int = 0,
        correctionCount: Int = 0,
        retryCount: Int = 0,
        deleteCount: Int = 0
    ) {
        self.totalOutcomeCount = totalOutcomeCount
        self.continuedCount = continuedCount
        self.correctionCount = correctionCount
        self.retryCount = retryCount
        self.deleteCount = deleteCount
    }

    static let empty = BehaviorEvalTelemetrySummary()

    var interventionCount: Int {
        correctionCount + retryCount + deleteCount
    }

    var keepRate: Double {
        guard totalOutcomeCount > 0 else { return 0 }
        return Double(continuedCount) / Double(totalOutcomeCount)
    }

    var interventionRate: Double {
        guard totalOutcomeCount > 0 else { return 0 }
        return Double(interventionCount) / Double(totalOutcomeCount)
    }

    var summaryText: String {
        guard totalOutcomeCount > 0 else {
            return "No behavior eval signals recorded."
        }

        let keepPercent = Int((keepRate * 100).rounded())
        return [
            "Behavior keep-rate \(keepPercent)%",
            "correction \(correctionCount)",
            "retry \(retryCount)",
            "delete \(deleteCount)"
        ].joined(separator: " · ")
    }

    static func summarize(events: [BehaviorEvalEvent]) -> BehaviorEvalTelemetrySummary {
        BehaviorEvalTelemetrySummary(
            totalOutcomeCount: events.count,
            continuedCount: events.filter { $0.outcome == .continued }.count,
            correctionCount: events.filter { $0.outcome == .correction }.count,
            retryCount: events.filter { $0.outcome == .retry }.count,
            deleteCount: events.filter { $0.outcome == .delete }.count
        )
    }
}

struct DelegationMetricEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let conversationId: UUID
    let assistantMessageId: UUID
    let executionMode: AgentExecutionMode
    let quickActionMode: QuickActionMode?
    let provider: LLMProvider
    let reason: AgentCoordinationReason
    let indexedSkillCount: Int
    let verifierUsed: Bool
    let verifierRiskFlagCount: Int
    let outcome: BehaviorEvalOutcome?
    let outcomeLatencySeconds: TimeInterval?
    let recordedAt: Date
    let outcomeRecordedAt: Date?

    init(
        id: UUID = UUID(),
        conversationId: UUID,
        assistantMessageId: UUID,
        executionMode: AgentExecutionMode,
        quickActionMode: QuickActionMode?,
        provider: LLMProvider,
        reason: AgentCoordinationReason,
        indexedSkillCount: Int,
        verifierUsed: Bool,
        verifierRiskFlagCount: Int,
        outcome: BehaviorEvalOutcome? = nil,
        outcomeLatencySeconds: TimeInterval? = nil,
        recordedAt: Date = Date(),
        outcomeRecordedAt: Date? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.assistantMessageId = assistantMessageId
        self.executionMode = executionMode
        self.quickActionMode = quickActionMode
        self.provider = provider
        self.reason = reason
        self.indexedSkillCount = indexedSkillCount
        self.verifierUsed = verifierUsed
        self.verifierRiskFlagCount = verifierRiskFlagCount
        self.outcome = outcome
        self.outcomeLatencySeconds = outcomeLatencySeconds
        self.recordedAt = recordedAt
        self.outcomeRecordedAt = outcomeRecordedAt
    }

    init?(snapshot: TurnCognitionSnapshot) {
        guard let coordination = snapshot.agentCoordination else { return nil }
        self.init(
            conversationId: snapshot.conversationId,
            assistantMessageId: snapshot.assistantMessageId,
            executionMode: coordination.executionMode,
            quickActionMode: coordination.quickActionMode,
            provider: coordination.provider,
            reason: coordination.reason,
            indexedSkillCount: coordination.indexedSkillCount,
            verifierUsed: snapshot.reviewArtifactId != nil,
            verifierRiskFlagCount: snapshot.reviewRiskFlags.count,
            recordedAt: snapshot.recordedAt
        )
    }

    var isDelegated: Bool {
        executionMode == .toolLoop
    }

    var isSingleShot: Bool {
        executionMode == .singleShot
    }

    var isEvaluated: Bool {
        outcome != nil
    }

    var isRework: Bool {
        outcome == .correction || outcome == .retry || outcome == .delete
    }

    func recordingOutcome(_ behaviorEvent: BehaviorEvalEvent) -> DelegationMetricEvent {
        guard shouldReplaceOutcome(with: behaviorEvent.outcome) else { return self }

        return DelegationMetricEvent(
            id: id,
            conversationId: conversationId,
            assistantMessageId: assistantMessageId,
            executionMode: executionMode,
            quickActionMode: quickActionMode,
            provider: provider,
            reason: reason,
            indexedSkillCount: indexedSkillCount,
            verifierUsed: verifierUsed,
            verifierRiskFlagCount: verifierRiskFlagCount,
            outcome: behaviorEvent.outcome,
            outcomeLatencySeconds: behaviorEvent.latencySeconds,
            recordedAt: recordedAt,
            outcomeRecordedAt: behaviorEvent.recordedAt
        )
    }

    private func shouldReplaceOutcome(with candidate: BehaviorEvalOutcome) -> Bool {
        guard let outcome else { return true }
        return candidate.delegationSeverity > outcome.delegationSeverity
    }
}

private extension BehaviorEvalOutcome {
    var delegationSeverity: Int {
        switch self {
        case .continued:
            return 0
        case .correction:
            return 1
        case .retry:
            return 2
        case .delete:
            return 3
        }
    }
}

struct DelegationMetricSummary: Equatable {
    let totalEventCount: Int
    let delegatedTurnCount: Int
    let verifierTurnCount: Int
    let evaluatedDelegatedTurnCount: Int
    let delegatedReworkCount: Int
    let evaluatedSingleShotTurnCount: Int
    let singleShotReworkCount: Int
    let evaluatedVerifierTurnCount: Int
    let verifierReworkCount: Int

    init(
        totalEventCount: Int = 0,
        delegatedTurnCount: Int = 0,
        verifierTurnCount: Int = 0,
        evaluatedDelegatedTurnCount: Int = 0,
        delegatedReworkCount: Int = 0,
        evaluatedSingleShotTurnCount: Int = 0,
        singleShotReworkCount: Int = 0,
        evaluatedVerifierTurnCount: Int = 0,
        verifierReworkCount: Int = 0
    ) {
        self.totalEventCount = totalEventCount
        self.delegatedTurnCount = delegatedTurnCount
        self.verifierTurnCount = verifierTurnCount
        self.evaluatedDelegatedTurnCount = evaluatedDelegatedTurnCount
        self.delegatedReworkCount = delegatedReworkCount
        self.evaluatedSingleShotTurnCount = evaluatedSingleShotTurnCount
        self.singleShotReworkCount = singleShotReworkCount
        self.evaluatedVerifierTurnCount = evaluatedVerifierTurnCount
        self.verifierReworkCount = verifierReworkCount
    }

    static let empty = DelegationMetricSummary()

    var delegationReworkRate: Double {
        rate(delegatedReworkCount, of: evaluatedDelegatedTurnCount)
    }

    var singleShotReworkRate: Double {
        rate(singleShotReworkCount, of: evaluatedSingleShotTurnCount)
    }

    var verifierReworkRate: Double {
        rate(verifierReworkCount, of: evaluatedVerifierTurnCount)
    }

    var summaryText: String {
        guard totalEventCount > 0 else {
            return "No delegation metric signals recorded."
        }

        return [
            "Delegation \(delegatedTurnCount) turns",
            "rework \(delegatedReworkCount)/\(evaluatedDelegatedTurnCount)",
            "single-shot \(singleShotReworkCount)/\(evaluatedSingleShotTurnCount)",
            "verifier \(verifierTurnCount) turns"
        ].joined(separator: " · ")
    }

    static func summarize(events: [DelegationMetricEvent]) -> DelegationMetricSummary {
        let delegated = events.filter(\.isDelegated)
        let evaluatedDelegated = delegated.filter(\.isEvaluated)
        let singleShot = events.filter(\.isSingleShot)
        let evaluatedSingleShot = singleShot.filter(\.isEvaluated)
        let verifier = events.filter(\.verifierUsed)
        let evaluatedVerifier = verifier.filter(\.isEvaluated)

        return DelegationMetricSummary(
            totalEventCount: events.count,
            delegatedTurnCount: delegated.count,
            verifierTurnCount: verifier.count,
            evaluatedDelegatedTurnCount: evaluatedDelegated.count,
            delegatedReworkCount: evaluatedDelegated.filter(\.isRework).count,
            evaluatedSingleShotTurnCount: evaluatedSingleShot.count,
            singleShotReworkCount: evaluatedSingleShot.filter(\.isRework).count,
            evaluatedVerifierTurnCount: evaluatedVerifier.count,
            verifierReworkCount: evaluatedVerifier.filter(\.isRework).count
        )
    }

    private func rate(_ numerator: Int, of denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return Double(numerator) / Double(denominator)
    }
}

enum BehaviorEvalClassifier {
    static func classifyUserFollowUp(_ text: String) -> BehaviorEvalOutcome {
        let normalized = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if containsAny(normalized, retryMarkers) {
            return .retry
        }

        let correctionCandidate = scrubbedAffirmativeChineseWrongMarkers(from: normalized)
        if containsAny(correctionCandidate, correctionPhraseMarkers) ||
            containsEnglishCorrectionRephrase(correctionCandidate) ||
            containsChineseWrongMarker(correctionCandidate) {
            return .correction
        }

        return .continued
    }

    private static let retryMarkers = [
        "try again",
        "do it again",
        "again from",
        "one more time",
        "start over",
        "redo",
        "retry",
        "re-answer",
        "重新",
        "重来",
        "再试",
        "再試",
        "再嚟",
        "再来"
    ]

    private static let correctionPhraseMarkers = [
        "that's wrong",
        "that is wrong",
        "that was wrong",
        "incorrect",
        "not what i asked",
        "you missed",
        "you misunderstood",
        "you got it wrong",
        "唔系",
        "唔係",
        "不是",
        "不对",
        "不對",
        "修正"
    ]

    private static let affirmativeChineseWrongMarkers = [
        "冇错",
        "冇錯",
        "没错",
        "沒錯",
        "无错",
        "無錯",
        "不错",
        "不錯",
        "唔错",
        "唔錯",
        "唔系错",
        "唔系錯",
        "唔係错",
        "唔係錯",
        "没有错",
        "沒有錯",
        "不是错",
        "不是錯"
    ]

    private static let chineseWrongMarkers = ["错", "錯"]

    private static let englishCorrectionRephraseMarkers = [
        "no, i meant",
        "no i meant",
        "no, i mean",
        "no i mean",
        "actually no",
        "actually, no",
        "what i meant was",
        "what i mean is",
        "i was asking for",
        "i asked for"
    ]

    private static let englishRephraseLeadMarkers = [
        " i mean ",
        " i mean,",
        " i meant ",
        " i meant,"
    ]

    private static let englishContrastMarkers = [
        ", not ",
        " not the ",
        " instead",
        " rather than "
    ]

    private static func containsChineseWrongMarker(_ text: String) -> Bool {
        containsAny(text, chineseWrongMarkers)
    }

    private static func containsEnglishCorrectionRephrase(_ text: String) -> Bool {
        if containsAny(text, englishCorrectionRephraseMarkers) {
            return true
        }

        let padded = " \(text) "
        return containsAny(padded, englishRephraseLeadMarkers) &&
            containsAny(padded, englishContrastMarkers)
    }

    private static func scrubbedAffirmativeChineseWrongMarkers(from text: String) -> String {
        affirmativeChineseWrongMarkers.reduce(text) { partial, marker in
            partial.replacingOccurrences(of: marker, with: "")
        }
    }

    private static func containsAny(_ text: String, _ markers: [String]) -> Bool {
        markers.contains { text.contains($0) }
    }
}

protocol BehaviorEvalTelemetryRecording: AnyObject {
    func recordBehaviorEvalEvent(_ event: BehaviorEvalEvent)
}

enum ContextManifestResourceSource: String, Codable, Equatable {
    case memory
    case skill
    case citation
    case sourceMaterial = "source_material"
}

enum ContextManifestResourceState: String, Codable, Equatable {
    case loaded
    case indexed
}

struct ContextManifestMemoryProvenance: Codable, Equatable {
    let scope: MemoryScope?
    let statuses: [MemoryStatus]
    let confidence: Double?
    let sourceNodeIds: [UUID]
    let sourceMessageIds: [UUID]

    init(
        scope: MemoryScope?,
        statuses: [MemoryStatus],
        confidence: Double?,
        sourceNodeIds: [UUID],
        sourceMessageIds: [UUID]
    ) {
        self.scope = scope
        self.statuses = statuses
        self.confidence = confidence
        self.sourceNodeIds = sourceNodeIds
        self.sourceMessageIds = sourceMessageIds
    }
}

struct ContextManifestResource: Codable, Equatable {
    let source: ContextManifestResourceSource
    let label: String
    let referenceId: String
    let state: ContextManifestResourceState
    let used: Bool
    let provenance: ContextManifestMemoryProvenance?

    init(
        source: ContextManifestResourceSource,
        label: String,
        referenceId: String,
        state: ContextManifestResourceState,
        used: Bool,
        provenance: ContextManifestMemoryProvenance? = nil
    ) {
        self.source = source
        self.label = label
        self.referenceId = referenceId
        self.state = state
        self.used = used
        self.provenance = provenance
    }
}

struct ContextManifestRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let turnId: UUID
    let conversationId: UUID
    let assistantMessageId: UUID
    let resources: [ContextManifestResource]
    let recordedAt: Date

    init(
        id: UUID = UUID(),
        turnId: UUID,
        conversationId: UUID,
        assistantMessageId: UUID,
        resources: [ContextManifestResource],
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.turnId = turnId
        self.conversationId = conversationId
        self.assistantMessageId = assistantMessageId
        self.resources = resources
        self.recordedAt = recordedAt
    }
}

struct ContextManifestTelemetrySummary: Equatable {
    let totalManifestCount: Int
    let totalResourceCount: Int
    let loadedMemoryCount: Int
    let loadedSkillCount: Int
    let indexedSkillCount: Int
    let loadedCitationCount: Int
    let loadedSourceMaterialCount: Int
    let usedMemoryCount: Int
    let usedSkillCount: Int
    let usedCitationCount: Int
    let usedSourceMaterialCount: Int

    init(
        totalManifestCount: Int = 0,
        totalResourceCount: Int = 0,
        loadedMemoryCount: Int = 0,
        loadedSkillCount: Int = 0,
        indexedSkillCount: Int = 0,
        loadedCitationCount: Int = 0,
        loadedSourceMaterialCount: Int = 0,
        usedMemoryCount: Int = 0,
        usedSkillCount: Int = 0,
        usedCitationCount: Int = 0,
        usedSourceMaterialCount: Int = 0
    ) {
        self.totalManifestCount = totalManifestCount
        self.totalResourceCount = totalResourceCount
        self.loadedMemoryCount = loadedMemoryCount
        self.loadedSkillCount = loadedSkillCount
        self.indexedSkillCount = indexedSkillCount
        self.loadedCitationCount = loadedCitationCount
        self.loadedSourceMaterialCount = loadedSourceMaterialCount
        self.usedMemoryCount = usedMemoryCount
        self.usedSkillCount = usedSkillCount
        self.usedCitationCount = usedCitationCount
        self.usedSourceMaterialCount = usedSourceMaterialCount
    }

    static let empty = ContextManifestTelemetrySummary()

    var usedResourceCount: Int {
        usedMemoryCount + usedSkillCount + usedCitationCount + usedSourceMaterialCount
    }

    var usageRate: Double {
        guard totalResourceCount > 0 else { return 0 }
        return Double(usedResourceCount) / Double(totalResourceCount)
    }

    var summaryText: String {
        guard totalManifestCount > 0, totalResourceCount > 0 else {
            return "No context manifest signals recorded."
        }

        var parts = [
            "Context manifest \(totalResourceCount) resources",
            "\(usedResourceCount) used",
            "memory \(loadedMemoryCount)"
        ]
        if loadedSourceMaterialCount > 0 || usedSourceMaterialCount > 0 {
            parts.append("source material \(loadedSourceMaterialCount)")
        }
        parts.append(contentsOf: [
            "citation \(loadedCitationCount)",
            "skill indexed \(indexedSkillCount)"
        ])
        return parts.joined(separator: " · ")
    }

    static func summarize(records: [ContextManifestRecord]) -> ContextManifestTelemetrySummary {
        let resources = records.flatMap(\.resources)
        return ContextManifestTelemetrySummary(
            totalManifestCount: records.count,
            totalResourceCount: resources.count,
            loadedMemoryCount: resources.filter { $0.source == .memory && $0.state == .loaded }.count,
            loadedSkillCount: resources.filter { $0.source == .skill && $0.state == .loaded }.count,
            indexedSkillCount: resources.filter { $0.source == .skill && $0.state == .indexed }.count,
            loadedCitationCount: resources.filter { $0.source == .citation && $0.state == .loaded }.count,
            loadedSourceMaterialCount: resources.filter { $0.source == .sourceMaterial && $0.state == .loaded }.count,
            usedMemoryCount: resources.filter { $0.source == .memory && $0.used }.count,
            usedSkillCount: resources.filter { $0.source == .skill && $0.used }.count,
            usedCitationCount: resources.filter { $0.source == .citation && $0.used }.count,
            usedSourceMaterialCount: resources.filter { $0.source == .sourceMaterial && $0.used }.count
        )
    }
}

enum ContextManifestFactory {
    private static let memoryPromptLayers: Set<String> = [
        "operating_context",
        "global_memory",
        "essential_story",
        "project_memory",
        "conversation_memory",
        "memory_evidence",
        "memory_graph_recall",
        "user_model",
        "project_goal",
        "recent_conversations",
        "slow_cognition"
    ]

    static func make(
        plan: TurnPlan,
        assistantMessageId: UUID,
        assistantContent: String,
        agentTraceJson: String?
    ) -> ContextManifestRecord {
        let usedSkillIds = toolLoadedSkillIds(from: agentTraceJson)
        let loadedPromptLayers = Set(plan.promptTrace.promptLayers)
        let memoryUsageHints = Dictionary(grouping: plan.memoryUsageHints, by: \.referenceId)
        let memoryProvenance = plan.memoryProvenance
        var resources: [ContextManifestResource] = []
        var seen = Set<String>()

        func append(_ resource: ContextManifestResource) {
            let key = [
                resource.source.rawValue,
                resource.label,
                resource.referenceId,
                resource.state.rawValue
            ].joined(separator: ":")
            guard seen.insert(key).inserted else { return }
            resources.append(resource)
        }

        for layer in plan.promptTrace.promptLayers where memoryPromptLayers.contains(layer) {
            if layer == "memory_evidence", !plan.memoryEvidenceSourceIds.isEmpty {
                for sourceId in plan.memoryEvidenceSourceIds.sortedByUUIDString() {
                    append(ContextManifestResource(
                        source: .memory,
                        label: layer,
                        referenceId: sourceId.uuidString,
                        state: .loaded,
                        used: memoryWasUsed(
                            referenceId: sourceId.uuidString,
                            assistantContent: assistantContent,
                            hintsByReferenceId: memoryUsageHints
                        ),
                        provenance: memoryProvenance[sourceId.uuidString]
                    ))
                }
                continue
            }
            append(ContextManifestResource(
                source: .memory,
                label: layer,
                referenceId: layer,
                state: .loaded,
                used: memoryWasUsed(
                    referenceId: layer,
                    assistantContent: assistantContent,
                    hintsByReferenceId: memoryUsageHints
                ),
                provenance: memoryProvenance[layer]
            ))
        }

        if loadedPromptLayers.contains("citations") {
            let loadedCitationIds = plan.loadedCitationIds.isEmpty
                ? Set(plan.citations.map(\.node.id))
                : plan.loadedCitationIds
            for citation in plan.citations {
                guard loadedCitationIds.contains(citation.node.id) else { continue }
                append(ContextManifestResource(
                    source: .citation,
                    label: "node",
                    referenceId: citation.node.id.uuidString,
                    state: .loaded,
                    used: assistantContent.containsCaseFolded(citation.node.title)
                ))
            }
        }

        if loadedPromptLayers.contains("source_material") {
            for (sourceIndex, material) in plan.sourceMaterials.enumerated() {
                append(ContextManifestResource(
                    source: .sourceMaterial,
                    label: "source_material",
                    referenceId: material.sourceNodeId.uuidString,
                    state: .loaded,
                    used: sourceMaterialWasUsed(
                        material,
                        sourceIndex: sourceIndex,
                        assistantContent: assistantContent
                    )
                ))
            }
        }

        for skillId in plan.loadedSkillIds.sortedByUUIDString() {
            append(ContextManifestResource(
                source: .skill,
                label: "quick_action_skill",
                referenceId: skillId.uuidString,
                state: .loaded,
                used: usedSkillIds.contains(skillId)
            ))
        }

        for skillId in plan.indexedSkillIds.subtracting(plan.loadedSkillIds).sortedByUUIDString() {
            append(ContextManifestResource(
                source: .skill,
                label: "quick_action_skill",
                referenceId: skillId.uuidString,
                state: .indexed,
                used: usedSkillIds.contains(skillId)
            ))
        }

        return ContextManifestRecord(
            turnId: plan.turnId,
            conversationId: plan.prepared.node.id,
            assistantMessageId: assistantMessageId,
            resources: resources
        )
    }

    private static func toolLoadedSkillIds(from agentTraceJson: String?) -> Set<UUID> {
        Set(AgentTraceCodec.decode(agentTraceJson).compactMap { record -> UUID? in
            guard record.kind == .toolResult,
                  record.toolName == AgentToolNames.loadSkill,
                  record.outcome == .success,
                  let inputJSON = record.inputJSON,
                  let data = inputJSON.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let skillId = object["skill_id"] as? String else {
                return nil
            }
            return UUID(uuidString: skillId)
        })
    }

    private static func memoryWasUsed(
        referenceId: String,
        assistantContent: String,
        hintsByReferenceId: [String: [ContextManifestUsageHint]]
    ) -> Bool {
        guard let hints = hintsByReferenceId[referenceId] else { return false }
        return hints
            .flatMap(\.phrases)
            .contains { assistantContent.containsCaseFolded($0) }
    }

    private static func sourceMaterialWasUsed(
        _ material: SourceMaterialContext,
        sourceIndex: Int,
        assistantContent: String
    ) -> Bool {
        sourceMaterialIdentifiers(for: material, sourceIndex: sourceIndex)
            .contains { assistantContent.containsCaseFolded($0) }
    }

    private static func sourceMaterialIdentifiers(
        for material: SourceMaterialContext,
        sourceIndex: Int
    ) -> [String] {
        var identifiers = [material.title, material.originalURL, material.originalFilename]
            .compactMap { $0 }
        let sourceNumber = sourceIndex + 1
        identifiers.append("[S\(sourceNumber)]")
        identifiers.append(contentsOf: material.chunks.map { "[S\(sourceNumber).\($0.ordinal + 1)]" })
        if let originalURL = material.originalURL,
           let host = URL(string: originalURL)?.host {
            identifiers.append(host)
        }
        return identifiers
    }
}

private extension Collection where Element == UUID {
    func sortedByUUIDString() -> [UUID] {
        sorted { $0.uuidString < $1.uuidString }
    }
}

private extension String {
    func containsCaseFolded(_ other: String) -> Bool {
        let needle = other.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        let foldedSelf = folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let foldedNeedle = needle
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return foldedSelf.contains(foldedNeedle)
    }
}

final class GovernanceTelemetryStore {
    private static let recentTurnCognitionSnapshotLimit = 20
    private static let recentBehaviorEvalEventLimit = 100
    private static let recentContextManifestLimit = 100
    private static let recentDelegationMetricEventLimit = 100

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
        static let recentBehaviorEvalEvents = "nous.governance.recentBehaviorEvalEvents"
        static let recentContextManifests = "nous.governance.recentContextManifests"
        static let recentDelegationMetricEvents = "nous.governance.recentDelegationMetricEvents"

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
        if let event = DelegationMetricEvent(snapshot: snapshot) {
            recordRecentDelegationMetricEvent(event)
        }
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

    var behaviorEvalSummary: BehaviorEvalTelemetrySummary {
        BehaviorEvalTelemetrySummary.summarize(events: storedRecentBehaviorEvalEvents())
    }

    func recentBehaviorEvalEvents(limit: Int) -> [BehaviorEvalEvent] {
        guard limit > 0 else { return [] }
        return Array(storedRecentBehaviorEvalEvents().prefix(limit))
    }

    var contextManifestSummary: ContextManifestTelemetrySummary {
        ContextManifestTelemetrySummary.summarize(records: storedRecentContextManifests())
    }

    func recordContextManifest(_ record: ContextManifestRecord) {
        guard !record.resources.isEmpty else { return }
        recordRecentContextManifest(record)
    }

    func recentContextManifests(limit: Int) -> [ContextManifestRecord] {
        guard limit > 0 else { return [] }
        return Array(storedRecentContextManifests().prefix(limit))
    }

    var delegationMetricSummary: DelegationMetricSummary {
        DelegationMetricSummary.summarize(events: storedRecentDelegationMetricEvents())
    }

    func recentDelegationMetricEvents(limit: Int) -> [DelegationMetricEvent] {
        guard limit > 0 else { return [] }
        return Array(storedRecentDelegationMetricEvents().prefix(limit))
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

    private func recordRecentBehaviorEvalEvent(_ event: BehaviorEvalEvent) {
        var events = storedRecentBehaviorEvalEvents()
        events.insert(event, at: 0)
        if events.count > Self.recentBehaviorEvalEventLimit {
            events = Array(events.prefix(Self.recentBehaviorEvalEventLimit))
        }
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: Keys.recentBehaviorEvalEvents)
        }
    }

    private func storedRecentBehaviorEvalEvents() -> [BehaviorEvalEvent] {
        guard let data = defaults.data(forKey: Keys.recentBehaviorEvalEvents),
              let events = try? JSONDecoder().decode([BehaviorEvalEvent].self, from: data) else {
            return []
        }
        return events
    }

    private func recordRecentContextManifest(_ record: ContextManifestRecord) {
        var records = storedRecentContextManifests()
        records.insert(record, at: 0)
        if records.count > Self.recentContextManifestLimit {
            records = Array(records.prefix(Self.recentContextManifestLimit))
        }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Keys.recentContextManifests)
        }
    }

    private func storedRecentContextManifests() -> [ContextManifestRecord] {
        guard let data = defaults.data(forKey: Keys.recentContextManifests),
              let records = try? JSONDecoder().decode([ContextManifestRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func recordRecentDelegationMetricEvent(_ event: DelegationMetricEvent) {
        var events = storedRecentDelegationMetricEvents()
        events.insert(event, at: 0)
        if events.count > Self.recentDelegationMetricEventLimit {
            events = Array(events.prefix(Self.recentDelegationMetricEventLimit))
        }
        storeRecentDelegationMetricEvents(events)
    }

    private func recordDelegationOutcome(_ event: BehaviorEvalEvent) {
        var events = storedRecentDelegationMetricEvents()
        guard let index = events.firstIndex(where: { $0.assistantMessageId == event.assistantMessageId }) else {
            return
        }
        events[index] = events[index].recordingOutcome(event)
        storeRecentDelegationMetricEvents(events)
    }

    private func storeRecentDelegationMetricEvents(_ events: [DelegationMetricEvent]) {
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: Keys.recentDelegationMetricEvents)
        }
    }

    private func storedRecentDelegationMetricEvents() -> [DelegationMetricEvent] {
        guard let data = defaults.data(forKey: Keys.recentDelegationMetricEvents),
              let events = try? JSONDecoder().decode([DelegationMetricEvent].self, from: data) else {
            return []
        }
        return events
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

extension GovernanceTelemetryStore: BehaviorEvalTelemetryRecording {
    func recordBehaviorEvalEvent(_ event: BehaviorEvalEvent) {
        recordRecentBehaviorEvalEvent(event)
        recordDelegationOutcome(event)
    }
}
