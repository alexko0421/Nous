import Foundation

enum HarnessGateMode: String, Codable, Equatable {
    case quick
    case full

    var displayName: String {
        switch self {
        case .quick:
            return "Quick"
        case .full:
            return "Full"
        }
    }
}

enum HarnessCheckStatus: String, Codable, Equatable {
    case passed
    case failed
    case skipped
}

enum HarnessFinding: String, Codable, CaseIterable, Equatable {
    case protectedAnchorChanged = "protected_anchor_changed"
    case rootSwiftOrphan = "root_swift_orphan"
    case promptSurfaceChanged = "prompt_surface_changed"
    case modelSurfaceChanged = "model_surface_changed"
    case memorySurfaceChanged = "memory_surface_changed"
    case projectConfigChanged = "project_config_changed"
    case sourceSetChanged = "source_set_changed"
    case fixtureSurfaceChanged = "fixture_surface_changed"

    var isBlocking: Bool {
        switch self {
        case .protectedAnchorChanged, .rootSwiftOrphan:
            return true
        case .promptSurfaceChanged,
             .modelSurfaceChanged,
             .memorySurfaceChanged,
             .projectConfigChanged,
             .sourceSetChanged,
             .fixtureSurfaceChanged:
            return false
        }
    }

    var requiresFullGate: Bool {
        switch self {
        case .protectedAnchorChanged,
             .promptSurfaceChanged,
             .modelSurfaceChanged,
             .memorySurfaceChanged,
             .projectConfigChanged,
             .sourceSetChanged,
             .fixtureSurfaceChanged:
            return true
        case .rootSwiftOrphan:
            return false
        }
    }

    var displayTitle: String {
        switch self {
        case .protectedAnchorChanged:
            return "anchor.md changed"
        case .rootSwiftOrphan:
            return "Root Swift orphan"
        case .promptSurfaceChanged:
            return "Prompt surface changed"
        case .modelSurfaceChanged:
            return "Model surface changed"
        case .memorySurfaceChanged:
            return "Memory surface changed"
        case .projectConfigChanged:
            return "Project config changed"
        case .sourceSetChanged:
            return "Source set changed"
        case .fixtureSurfaceChanged:
            return "Eval fixture changed"
        }
    }
}

struct HarnessChangeClassification: Codable, Equatable {
    var findings: [HarnessFinding]
    var rootSwiftFiles: [String]
    var changeSignature: String?
    var hasCurrentChanges: Bool

    init(
        findings: [HarnessFinding] = [],
        rootSwiftFiles: [String] = [],
        changeSignature: String? = nil,
        hasCurrentChanges: Bool? = nil
    ) {
        self.findings = Array(Set(findings)).sorted { $0.rawValue < $1.rawValue }
        self.rootSwiftFiles = rootSwiftFiles.sorted()
        self.changeSignature = changeSignature
        self.hasCurrentChanges = hasCurrentChanges ?? (!findings.isEmpty || !rootSwiftFiles.isEmpty)
    }

    var requiresFullGate: Bool {
        findings.contains { $0.requiresFullGate }
    }

    var hasBlockingIssues: Bool {
        findings.contains { $0.isBlocking }
    }
}

enum HarnessChangeClassifier {
    private static let anchorPath = "Sources/Nous/Resources/anchor.md"

    static func classify(
        changedPaths: [String],
        rootSwiftFiles: [String],
        changeSignature: String? = nil
    ) -> HarnessChangeClassification {
        let normalizedPaths = changedPaths.map(normalize)
        var findings: [HarnessFinding] = []

        if normalizedPaths.contains(anchorPath) {
            findings.append(.protectedAnchorChanged)
        }

        if !rootSwiftFiles.isEmpty {
            findings.append(.rootSwiftOrphan)
        }

        if normalizedPaths.contains(where: isPromptSurfacePath) {
            findings.append(.promptSurfaceChanged)
        }

        if normalizedPaths.contains(where: isModelSurfacePath) {
            findings.append(.modelSurfaceChanged)
        }

        if normalizedPaths.contains(where: isMemorySurfacePath) {
            findings.append(.memorySurfaceChanged)
        }

        if normalizedPaths.contains(where: isProjectConfigPath) {
            findings.append(.projectConfigChanged)
        }

        if normalizedPaths.contains(where: isSourceSetPath) {
            findings.append(.sourceSetChanged)
        }

        if normalizedPaths.contains(where: isFixtureSurfacePath) {
            findings.append(.fixtureSurfaceChanged)
        }

        return HarnessChangeClassification(
            findings: findings,
            rootSwiftFiles: rootSwiftFiles.map(normalize),
            changeSignature: changeSignature,
            hasCurrentChanges: !normalizedPaths.isEmpty || !rootSwiftFiles.isEmpty
        )
    }

    private static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isPromptSurfacePath(_ path: String) -> Bool {
        let targets = [
            "PromptContextAssembler",
            "PromptGovernanceTrace",
            "TurnPlanner",
            "TurnSteward",
            "ChatTurnRunner",
            "CognitionArtifactAdapters"
        ]
        return path == anchorPath || targets.contains { path.contains($0) }
    }

    private static func isModelSurfacePath(_ path: String) -> Bool {
        let targets = [
            "LLMService",
            "LocalLLMService",
            "Gemini",
            "Claude",
            "OpenAI",
            "OpenRouter"
        ]
        return targets.contains { path.contains($0) }
    }

    private static func isMemorySurfacePath(_ path: String) -> Bool {
        let targets = [
            "Memory",
            "VectorStore",
            "Embedding",
            "NodeStore",
            "Reflection",
            "ShadowLearning",
            "UserModel",
            "Contradiction"
        ]
        return targets.contains { path.contains($0) }
    }

    private static func isProjectConfigPath(_ path: String) -> Bool {
        path == "project.yml" || path.hasPrefix("Nous.xcodeproj/")
    }

    private static func isSourceSetPath(_ path: String) -> Bool {
        (path.hasPrefix("Sources/") || path.hasPrefix("Tests/")) &&
            path.hasSuffix(".swift")
    }

    private static func isFixtureSurfacePath(_ path: String) -> Bool {
        path.contains("FixtureRunner") ||
            path.contains("Sycophancy") ||
            path.contains("fixtures") ||
            path.hasPrefix("Tests/NousTests/PromptGovernance") ||
            path.hasPrefix("Tests/NousTests/RuntimeQuality")
    }
}

struct HarnessRunRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let mode: HarnessGateMode
    let status: HarnessCheckStatus
    let startedAt: Date
    let endedAt: Date
    let findings: [HarnessFinding]
    let detail: String
    let changeSignature: String?

    init(
        id: UUID = UUID(),
        mode: HarnessGateMode,
        status: HarnessCheckStatus,
        startedAt: Date,
        endedAt: Date,
        findings: [HarnessFinding] = [],
        detail: String = "",
        changeSignature: String? = nil
    ) {
        self.id = id
        self.mode = mode
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.findings = Array(Set(findings)).sorted { $0.rawValue < $1.rawValue }
        self.detail = detail
        self.changeSignature = changeSignature
    }
}

enum HarnessBuildStatus: String, Codable, Equatable {
    case neverRun
    case passed
    case failed
    case needsQuickGate
    case needsFullGate
}

struct HarnessHealthSnapshot: Equatable {
    var recentRuns: [HarnessRunRecord]
    var changeClassification: HarnessChangeClassification

    init(
        recentRuns: [HarnessRunRecord] = [],
        changeClassification: HarnessChangeClassification = HarnessChangeClassification()
    ) {
        self.recentRuns = recentRuns.sorted { $0.endedAt > $1.endedAt }
        self.changeClassification = changeClassification
    }

    static let empty = HarnessHealthSnapshot()

    var latestRun: HarnessRunRecord? {
        recentRuns.first
    }

    var latestQuickRun: HarnessRunRecord? {
        recentRuns.first { $0.mode == .quick }
    }

    var latestFullRun: HarnessRunRecord? {
        recentRuns.first { $0.mode == .full }
    }

    var buildStatus: HarnessBuildStatus {
        if changeClassification.hasBlockingIssues {
            return .failed
        }

        if latestRun == nil {
            if changeClassification.requiresFullGate {
                return .needsFullGate
            }
            return changeClassification.hasCurrentChanges ? .needsQuickGate : .neverRun
        }

        if latestRun?.status == .failed {
            return .failed
        }

        if changeClassification.hasCurrentChanges {
            if changeClassification.requiresFullGate {
                return latestFullRunCoversCurrentChanges ? .passed : .needsFullGate
            }

            if !latestPassedRunCoversCurrentChanges {
                return .needsQuickGate
            }
        }

        if latestRun?.status == .passed {
            return .passed
        }

        return .neverRun
    }

    var statusText: String {
        switch buildStatus {
        case .neverRun:
            return "Harness not run"
        case .passed:
            if changeClassification.requiresFullGate,
               let latestFullRun {
                return "\(latestFullRun.mode.displayName) gate passed"
            }
            guard let latestRun else { return "Harness passed" }
            return "\(latestRun.mode.displayName) gate passed"
        case .failed:
            if let latestRun, latestRun.status == .failed {
                return "\(latestRun.mode.displayName) gate failed"
            }
            return "Harness blocked"
        case .needsQuickGate:
            return "Quick gate needed"
        case .needsFullGate:
            return "Full gate needed"
        }
    }

    var founderLoopSummary: [String] {
        var summary: [String] = []

        if buildStatus == .failed {
            summary.append("Fix quality gates before closing work.")
        } else if buildStatus == .needsQuickGate {
            summary.append("Run the quick gate before closing work.")
        } else if buildStatus == .needsFullGate {
            summary.append("Run the full gate before calling risky changes done.")
        } else if buildStatus == .passed {
            summary.append("Quality gate is clear for the current surface.")
        } else {
            summary.append("Run the quick gate before closing work.")
        }

        if !changeClassification.rootSwiftFiles.isEmpty {
            summary.append("Move Swift orphans into Sources/Nous subdirectories.")
        }

        if let latestRun, !latestRun.detail.isEmpty {
            summary.append(latestRun.detail)
        }

        return summary
    }

    var findingTitles: [String] {
        let local = changeClassification.findings.map(\.displayTitle)
        let latest = latestRun?.findings.map(\.displayTitle) ?? []
        return Array(Set(local + latest)).sorted()
    }

    private var latestPassedRunCoversCurrentChanges: Bool {
        guard let currentSignature = changeClassification.changeSignature else {
            return false
        }

        return recentRuns.contains { run in
            run.status == .passed && run.changeSignature == currentSignature
        }
    }

    private var latestFullRunCoversCurrentChanges: Bool {
        guard let latestFullRun,
              latestFullRun.status == .passed,
              let currentSignature = changeClassification.changeSignature,
              let runSignature = latestFullRun.changeSignature else {
            return false
        }

        return currentSignature == runSignature
    }
}

enum ModelHarnessToolSchema: Equatable {
    case unsupported
    case openRouterFunctionTools
}

enum ModelHarnessCacheStrategy: Equatable {
    case unsupported
    case geminiCachedContent
    case anthropicEphemeralSystemPrefix
    case openRouterSystemBlockCacheControl
}

enum ModelHarnessThinkingStrategy: Equatable {
    case unsupported
    case geminiThinkingConfig
    case anthropicThinkingBudget
    case openRouterReasoningBudget
}

enum ModelHarnessAgentLoopSupport: Equatable {
    case unsupported
    case openRouterClaudeSonnet46
}

enum ModelHarnessFallbackStrategy: Equatable {
    case inlineConfigurationMessage
    case inlineProviderError
    case providerCannotUseToolLoop
}

struct ModelHarnessProfile: Equatable {
    let provider: LLMProvider
    let toolSchema: ModelHarnessToolSchema
    let cacheStrategy: ModelHarnessCacheStrategy
    let thinkingStrategy: ModelHarnessThinkingStrategy
    let thinkingBudgetTokens: Int?
    let agentLoopSupport: ModelHarnessAgentLoopSupport
    let requiredToolLoopModel: String?
    let fallbackStrategy: ModelHarnessFallbackStrategy

    var supportsAgentToolUse: Bool {
        agentLoopSupport != .unsupported
    }

    func allowsAgentToolUse(model: String?) -> Bool {
        guard supportsAgentToolUse else { return false }
        guard let requiredToolLoopModel else { return true }
        return model == requiredToolLoopModel
    }
}

struct ModelHarnessProfileCoverageSummary: Equatable {
    let totalProviderCount: Int
    let coveredProviderCount: Int
    let agentLoopProviderCount: Int
    let cacheStrategyCount: Int
    let thinkingStrategyCount: Int
    let missingProviders: [LLMProvider]

    static let empty = ModelHarnessProfileCoverageSummary(
        totalProviderCount: 0,
        coveredProviderCount: 0,
        agentLoopProviderCount: 0,
        cacheStrategyCount: 0,
        thinkingStrategyCount: 0,
        missingProviders: []
    )

    var isComplete: Bool {
        missingProviders.isEmpty && totalProviderCount == coveredProviderCount
    }

    var summaryText: String {
        guard totalProviderCount > 0 else {
            return "No model harness profiles recorded."
        }
        guard missingProviders.isEmpty else {
            return "Model profiles missing \(missingProviders.map(\.rawValue).joined(separator: ", "))"
        }

        return "Model profiles \(coveredProviderCount)/\(totalProviderCount) covered · agent loop \(agentLoopProviderCount) · cache \(cacheStrategyCount) · thinking \(thinkingStrategyCount)"
    }

    static func summarize(
        profiles: [ModelHarnessProfile],
        expectedProviders: [LLMProvider]
    ) -> ModelHarnessProfileCoverageSummary {
        let coveredProviders = Set(profiles.map(\.provider))
        let expectedProviderSet = Set(expectedProviders)
        let missingProviders = expectedProviders.filter { !coveredProviders.contains($0) }

        return ModelHarnessProfileCoverageSummary(
            totalProviderCount: expectedProviders.count,
            coveredProviderCount: coveredProviders.intersection(expectedProviderSet).count,
            agentLoopProviderCount: profiles.filter { $0.agentLoopSupport != .unsupported }.count,
            cacheStrategyCount: profiles.filter { $0.cacheStrategy != .unsupported }.count,
            thinkingStrategyCount: profiles.filter { $0.thinkingStrategy != .unsupported }.count,
            missingProviders: missingProviders
        )
    }
}

enum ModelHarnessProfileCatalog {
    static let allProfiles: [ModelHarnessProfile] = [
        ModelHarnessProfile(
            provider: .local,
            toolSchema: .unsupported,
            cacheStrategy: .unsupported,
            thinkingStrategy: .unsupported,
            thinkingBudgetTokens: nil,
            agentLoopSupport: .unsupported,
            requiredToolLoopModel: nil,
            fallbackStrategy: .inlineConfigurationMessage
        ),
        ModelHarnessProfile(
            provider: .gemini,
            toolSchema: .unsupported,
            cacheStrategy: .geminiCachedContent,
            thinkingStrategy: .geminiThinkingConfig,
            thinkingBudgetTokens: 2000,
            agentLoopSupport: .unsupported,
            requiredToolLoopModel: nil,
            fallbackStrategy: .inlineProviderError
        ),
        ModelHarnessProfile(
            provider: .claude,
            toolSchema: .unsupported,
            cacheStrategy: .anthropicEphemeralSystemPrefix,
            thinkingStrategy: .anthropicThinkingBudget,
            thinkingBudgetTokens: 1024,
            agentLoopSupport: .unsupported,
            requiredToolLoopModel: nil,
            fallbackStrategy: .inlineProviderError
        ),
        ModelHarnessProfile(
            provider: .openai,
            toolSchema: .unsupported,
            cacheStrategy: .unsupported,
            thinkingStrategy: .unsupported,
            thinkingBudgetTokens: nil,
            agentLoopSupport: .unsupported,
            requiredToolLoopModel: nil,
            fallbackStrategy: .inlineProviderError
        ),
        ModelHarnessProfile(
            provider: .openrouter,
            toolSchema: .openRouterFunctionTools,
            cacheStrategy: .openRouterSystemBlockCacheControl,
            thinkingStrategy: .openRouterReasoningBudget,
            thinkingBudgetTokens: 1024,
            agentLoopSupport: .openRouterClaudeSonnet46,
            requiredToolLoopModel: "anthropic/claude-sonnet-4.6",
            fallbackStrategy: .providerCannotUseToolLoop
        )
    ]

    static let coverageSummary = ModelHarnessProfileCoverageSummary.summarize(
        profiles: allProfiles,
        expectedProviders: LLMProvider.allCases
    )

    static func profile(for provider: LLMProvider) -> ModelHarnessProfile {
        allProfiles.first { $0.provider == provider } ?? ModelHarnessProfile(
            provider: provider,
            toolSchema: .unsupported,
            cacheStrategy: .unsupported,
            thinkingStrategy: .unsupported,
            thinkingBudgetTokens: nil,
            agentLoopSupport: .unsupported,
            requiredToolLoopModel: nil,
            fallbackStrategy: .inlineProviderError
        )
    }

    static func thinkingBudgetTokens(for provider: LLMProvider) -> Int? {
        profile(for: provider).thinkingBudgetTokens
    }

    static func allowsAgentToolUse(for provider: LLMProvider, model: String?) -> Bool {
        profile(for: provider).allowsAgentToolUse(model: model)
    }
}

struct RuntimeHarnessSnapshot: Equatable {
    var totalTurnCount: Int
    var reviewedTurnCount: Int
    var reviewerCoverageRate: Double
    var riskFlagCounts: [String: Int]
    var lastRiskFlags: [String]
    var sycophancyFixtureTrend: String
    var agentToolReliability: AgentToolReliabilitySummary
    var behaviorEval: BehaviorEvalTelemetrySummary
    var contextManifest: ContextManifestTelemetrySummary
    var delegationMetrics: DelegationMetricSummary
    var modelHarnessProfiles: ModelHarnessProfileCoverageSummary
    var visibleResponseLanguageTarget: VisibleResponseLanguageTarget
    var visibleResponseLanguageSource: VisibleResponseLanguageSource

    init(
        totalTurnCount: Int = 0,
        reviewedTurnCount: Int = 0,
        reviewerCoverageRate: Double = 0,
        riskFlagCounts: [String: Int] = [:],
        lastRiskFlags: [String] = [],
        sycophancyFixtureTrend: String = "No fixture history yet",
        agentToolReliability: AgentToolReliabilitySummary = .empty,
        behaviorEval: BehaviorEvalTelemetrySummary = .empty,
        contextManifest: ContextManifestTelemetrySummary = .empty,
        delegationMetrics: DelegationMetricSummary = .empty,
        modelHarnessProfiles: ModelHarnessProfileCoverageSummary = ModelHarnessProfileCatalog.coverageSummary,
        visibleResponseLanguageTarget: VisibleResponseLanguageTarget = .unspecified,
        visibleResponseLanguageSource: VisibleResponseLanguageSource = .none
    ) {
        self.totalTurnCount = totalTurnCount
        self.reviewedTurnCount = reviewedTurnCount
        self.reviewerCoverageRate = reviewerCoverageRate
        self.riskFlagCounts = riskFlagCounts
        self.lastRiskFlags = lastRiskFlags.sorted()
        self.sycophancyFixtureTrend = sycophancyFixtureTrend
        self.agentToolReliability = agentToolReliability
        self.behaviorEval = behaviorEval
        self.contextManifest = contextManifest
        self.delegationMetrics = delegationMetrics
        self.modelHarnessProfiles = modelHarnessProfiles
        self.visibleResponseLanguageTarget = visibleResponseLanguageTarget
        self.visibleResponseLanguageSource = visibleResponseLanguageSource
    }

    static let empty = RuntimeHarnessSnapshot()

    var statusText: String {
        if !modelHarnessProfiles.isComplete {
            return "Model harness profile missing"
        }
        if agentToolReliability.unknownErrorCount > 0 {
            return "Agent harness unknown error recorded"
        }
        if totalTurnCount == 0 {
            return "No runtime turns recorded"
        }
        if !lastRiskFlags.isEmpty {
            return "Recent runtime risk recorded"
        }
        return "Runtime reviewer quiet"
    }

    var reviewerCoverageText: String {
        "\(Int((reviewerCoverageRate * 100).rounded()))% reviewed"
    }

    var riskFlagSummary: String {
        let flags = riskFlagCounts
            .filter { $0.value > 0 }
            .sorted { left, right in
                if left.value == right.value {
                    return left.key < right.key
                }
                return left.value > right.value
            }
            .prefix(3)
            .map { "\($0.key) \($0.value)" }

        if flags.isEmpty {
            return "No runtime risk flags recorded."
        }

        return flags.joined(separator: " · ")
    }

    var visibleResponseLanguageSummaryText: String {
        guard visibleResponseLanguageTarget != .unspecified else {
            return "No visible language target recorded."
        }
        if let summaryLabel = visibleResponseLanguageSource.summaryLabel {
            return "Visible language target \(visibleResponseLanguageTarget.promptLabel) · \(summaryLabel)"
        }
        return "Visible language target \(visibleResponseLanguageTarget.promptLabel)"
    }
}

struct AgentToolFailureCount: Equatable {
    let toolName: String
    let failureCount: Int
}

struct AgentToolReliabilitySummary: Equatable {
    var totalToolCallCount: Int
    var failedToolCallCount: Int
    var unknownErrorCount: Int
    var timeoutErrorCount: Int
    var topFailingTools: [AgentToolFailureCount]

    init(
        totalToolCallCount: Int = 0,
        failedToolCallCount: Int = 0,
        unknownErrorCount: Int = 0,
        timeoutErrorCount: Int = 0,
        topFailingTools: [AgentToolFailureCount] = []
    ) {
        self.totalToolCallCount = totalToolCallCount
        self.failedToolCallCount = failedToolCallCount
        self.unknownErrorCount = unknownErrorCount
        self.timeoutErrorCount = timeoutErrorCount
        self.topFailingTools = topFailingTools
    }

    static let empty = AgentToolReliabilitySummary()

    var failureRate: Double {
        guard totalToolCallCount > 0 else { return 0 }
        return Double(failedToolCallCount) / Double(totalToolCallCount)
    }

    var summaryText: String {
        guard totalToolCallCount > 0 else {
            return "No agent tool traces recorded."
        }

        let failurePercent = Int((failureRate * 100).rounded())
        var pieces = [
            "Agent tools \(failedToolCallCount)/\(totalToolCallCount) failed",
            "\(failurePercent)% failure"
        ]
        if unknownErrorCount > 0 {
            pieces.append("unknown \(unknownErrorCount)")
        }
        if timeoutErrorCount > 0 {
            pieces.append("timeout \(timeoutErrorCount)")
        }
        if let top = topFailingTools.first {
            pieces.append("top \(top.toolName) \(top.failureCount)")
        }
        return pieces.joined(separator: " · ")
    }

    static func summarize(records: [AgentTraceRecord]) -> AgentToolReliabilitySummary {
        let toolRecords = records.filter { record in
            record.kind == .toolResult || record.kind == .toolError
        }
        let failedRecords = toolRecords.filter { $0.kind == .toolError || $0.outcome == .failure }
        var failureCountsByTool: [String: Int] = [:]
        var firstFailureIndexByTool: [String: Int] = [:]
        for (index, record) in failedRecords.enumerated() {
            let toolName = record.toolName ?? "unknown_tool"
            failureCountsByTool[toolName, default: 0] += 1
            firstFailureIndexByTool[toolName] = firstFailureIndexByTool[toolName] ?? index
        }
        let failureCounts = failureCountsByTool
            .map { AgentToolFailureCount(toolName: $0.key, failureCount: $0.value) }
            .sorted { left, right in
                if left.failureCount == right.failureCount {
                    return (firstFailureIndexByTool[left.toolName] ?? Int.max)
                        < (firstFailureIndexByTool[right.toolName] ?? Int.max)
                }
                return left.failureCount > right.failureCount
            }

        return AgentToolReliabilitySummary(
            totalToolCallCount: toolRecords.count,
            failedToolCallCount: failedRecords.count,
            unknownErrorCount: failedRecords.filter { $0.errorCategory == .unknown }.count,
            timeoutErrorCount: failedRecords.filter { $0.errorCategory == .timeout }.count,
            topFailingTools: Array(failureCounts.prefix(3))
        )
    }
}
