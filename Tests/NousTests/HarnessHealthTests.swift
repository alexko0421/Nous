import XCTest
@testable import Nous

final class HarnessHealthTests: XCTestCase {
    func testClassifiesAnchorAsProtectedFileChange() {
        let result = HarnessChangeClassifier.classify(
            changedPaths: ["Sources/Nous/Resources/anchor.md"],
            rootSwiftFiles: []
        )

        XCTAssertTrue(result.requiresFullGate)
        XCTAssertTrue(result.hasBlockingIssues)
        XCTAssertTrue(result.findings.contains(.protectedAnchorChanged))
    }

    func testClassifiesRootSwiftOrphanAsBlockingIssue() {
        let result = HarnessChangeClassifier.classify(
            changedPaths: [],
            rootSwiftFiles: ["Sources/Nous/Temporary.swift"]
        )

        XCTAssertTrue(result.hasBlockingIssues)
        XCTAssertTrue(result.findings.contains(.rootSwiftOrphan))
    }

    func testPromptModelAndMemoryChangesRequireFullGate() {
        let result = HarnessChangeClassifier.classify(
            changedPaths: [
                "Sources/Nous/Services/PromptContextAssembler.swift",
                "Sources/Nous/Services/LLMService.swift",
                "Sources/Nous/Services/MemoryProjectionService.swift"
            ],
            rootSwiftFiles: []
        )

        XCTAssertTrue(result.requiresFullGate)
        XCTAssertFalse(result.hasBlockingIssues)
        XCTAssertTrue(result.findings.contains(.promptSurfaceChanged))
        XCTAssertTrue(result.findings.contains(.modelSurfaceChanged))
        XCTAssertTrue(result.findings.contains(.memorySurfaceChanged))
    }

    func testSwiftSourceSetChangesRequireFullGate() {
        let result = HarnessChangeClassifier.classify(
            changedPaths: [
                "Sources/Nous/Models/NewHarnessModel.swift",
                "Tests/NousTests/NewHarnessModelTests.swift"
            ],
            rootSwiftFiles: []
        )

        XCTAssertTrue(result.requiresFullGate)
        XCTAssertFalse(result.hasBlockingIssues)
        XCTAssertTrue(result.findings.contains(.sourceSetChanged))
    }

    func testClassifierTracksUnclassifiedCurrentChanges() {
        let result = HarnessChangeClassifier.classify(
            changedPaths: ["docs/agentic-engineering-workflow.md"],
            rootSwiftFiles: [],
            changeSignature: "docs"
        )

        XCTAssertFalse(result.requiresFullGate)
        XCTAssertFalse(result.hasBlockingIssues)
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertTrue(result.hasCurrentChanges)
        XCTAssertEqual(result.changeSignature, "docs")
    }

    func testHarnessSnapshotSummarizesFailedRecentRuns() {
        let recentRun = HarnessRunRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!,
            mode: .quick,
            status: .failed,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 12),
            findings: [.rootSwiftOrphan],
            detail: "Root Swift files found."
        )

        let snapshot = HarnessHealthSnapshot(
            recentRuns: [recentRun],
            changeClassification: HarnessChangeClassification(
                findings: [.rootSwiftOrphan],
                rootSwiftFiles: ["Sources/Nous/Temporary.swift"]
            )
        )

        XCTAssertEqual(snapshot.buildStatus, .failed)
        XCTAssertEqual(snapshot.statusText, "Quick gate failed")
        XCTAssertTrue(snapshot.founderLoopSummary.contains("Fix quality gates before closing work."))
    }

    func testUnclassifiedChangesNeedFreshQuickGate() {
        let staleQuickRun = HarnessRunRecord(
            mode: .quick,
            status: .passed,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            detail: "Quick gate passed.",
            changeSignature: "old"
        )
        let snapshot = HarnessHealthSnapshot(
            recentRuns: [staleQuickRun],
            changeClassification: HarnessChangeClassification(
                changeSignature: "new",
                hasCurrentChanges: true
            )
        )

        XCTAssertEqual(snapshot.buildStatus, .needsQuickGate)
        XCTAssertEqual(snapshot.statusText, "Quick gate needed")
        XCTAssertTrue(snapshot.founderLoopSummary.contains("Run the quick gate before closing work."))
    }

    func testMatchingQuickSignatureCoversUnclassifiedChanges() {
        let freshQuickRun = HarnessRunRecord(
            mode: .quick,
            status: .passed,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            detail: "Quick gate passed.",
            changeSignature: "same"
        )
        let snapshot = HarnessHealthSnapshot(
            recentRuns: [freshQuickRun],
            changeClassification: HarnessChangeClassification(
                changeSignature: "same",
                hasCurrentChanges: true
            )
        )

        XCTAssertEqual(snapshot.buildStatus, .passed)
        XCTAssertEqual(snapshot.statusText, "Quick gate passed")
    }

    func testFullGateMustMatchCurrentChangeSignature() {
        let staleFullRun = HarnessRunRecord(
            mode: .full,
            status: .passed,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            findings: [.sourceSetChanged],
            detail: "Full gate passed.",
            changeSignature: "old"
        )
        let snapshot = HarnessHealthSnapshot(
            recentRuns: [staleFullRun],
            changeClassification: HarnessChangeClassification(
                findings: [.sourceSetChanged],
                changeSignature: "new"
            )
        )

        XCTAssertEqual(snapshot.buildStatus, .needsFullGate)
        XCTAssertEqual(snapshot.statusText, "Full gate needed")
    }

    func testMatchingFullGateSignatureCoversCurrentRiskyChanges() {
        let freshFullRun = HarnessRunRecord(
            mode: .full,
            status: .passed,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            findings: [.sourceSetChanged],
            detail: "Full gate passed.",
            changeSignature: "same"
        )
        let snapshot = HarnessHealthSnapshot(
            recentRuns: [freshFullRun],
            changeClassification: HarnessChangeClassification(
                findings: [.sourceSetChanged],
                changeSignature: "same"
            )
        )

        XCTAssertEqual(snapshot.buildStatus, .passed)
        XCTAssertEqual(snapshot.statusText, "Full gate passed")
    }

    func testLegacyFullGateWithoutSignatureDoesNotCoverCurrentRiskyChanges() {
        let legacyFullRun = HarnessRunRecord(
            mode: .full,
            status: .passed,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            findings: [.sourceSetChanged],
            detail: "Full gate passed."
        )
        let snapshot = HarnessHealthSnapshot(
            recentRuns: [legacyFullRun],
            changeClassification: HarnessChangeClassification(
                findings: [.sourceSetChanged],
                changeSignature: "current"
            )
        )

        XCTAssertEqual(snapshot.buildStatus, .needsFullGate)
    }

    func testSycophancyTrendAcceptsBooleanHistoryRows() throws {
        let repoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let historyURL = repoURL.appendingPathComponent("results/sycophancy/history.jsonl")
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let history = """
        {"run_id":"old","passed":true}
        {"run_id":"latest","passed":true}
        {"run_id":"latest","passed":false}
        """
        try history.write(to: historyURL, atomically: true, encoding: .utf8)

        let snapshot = RuntimeHarnessService(repoURL: repoURL).loadSnapshot()

        XCTAssertEqual(snapshot.sycophancyFixtureTrend, "1/2 sycophancy fixtures passing")
    }

    func testRuntimeHarnessSummarizesAgentToolReliabilityFromRecentTraces() throws {
        let store = try NodeStore(path: ":memory:")
        let conversation = NousNode(type: .conversation, title: "Harness trace source")
        try store.insertNode(conversation)
        try store.insertMessage(Message(
            nodeId: conversation.id,
            role: .assistant,
            content: "Answer",
            agentTraceJson: AgentTraceCodec.encode([
                AgentTraceRecord(
                    kind: .toolResult,
                    toolName: AgentToolNames.searchMemory,
                    title: "Memory results",
                    detail: "ok",
                    provider: .openrouter,
                    quickActionMode: .direction,
                    durationMilliseconds: 8,
                    iteration: 1,
                    outcome: .success
                ),
                AgentTraceRecord(
                    kind: .toolError,
                    toolName: AgentToolNames.searchMemory,
                    title: "search_memory failed",
                    detail: "Unknown failure",
                    provider: .openrouter,
                    quickActionMode: .direction,
                    durationMilliseconds: 3,
                    iteration: 1,
                    outcome: .failure,
                    errorCategory: .unknown
                ),
                AgentTraceRecord(
                    kind: .toolError,
                    toolName: AgentToolNames.readNote,
                    title: "read_note failed",
                    detail: "Timeout",
                    provider: .openrouter,
                    quickActionMode: .plan,
                    durationMilliseconds: 10,
                    iteration: 2,
                    outcome: .failure,
                    errorCategory: .timeout
                )
            ])
        ))

        let snapshot = RuntimeHarnessService(
            telemetry: makeRuntimeHarnessTelemetry(),
            nodeStore: store
        ).loadSnapshot()

        XCTAssertEqual(snapshot.agentToolReliability.totalToolCallCount, 3)
        XCTAssertEqual(snapshot.agentToolReliability.failedToolCallCount, 2)
        XCTAssertEqual(snapshot.agentToolReliability.unknownErrorCount, 1)
        XCTAssertEqual(snapshot.agentToolReliability.timeoutErrorCount, 1)
        XCTAssertEqual(snapshot.agentToolReliability.topFailingTools.first?.toolName, AgentToolNames.searchMemory)
        XCTAssertEqual(snapshot.agentToolReliability.topFailingTools.first?.failureCount, 1)
        XCTAssertEqual(snapshot.agentToolReliability.failureRate, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testRuntimeHarnessAgentToolReliabilityIsQuietWithoutTraces() throws {
        let store = try NodeStore(path: ":memory:")
        let snapshot = RuntimeHarnessService(
            telemetry: makeRuntimeHarnessTelemetry(),
            nodeStore: store
        ).loadSnapshot()

        XCTAssertEqual(snapshot.agentToolReliability.totalToolCallCount, 0)
        XCTAssertEqual(snapshot.agentToolReliability.failedToolCallCount, 0)
        XCTAssertEqual(snapshot.agentToolReliability.summaryText, "No agent tool traces recorded.")
    }

    func testRuntimeHarnessSummarizesBehaviorEvalSignals() throws {
        let telemetry = makeRuntimeHarnessTelemetry()
        telemetry.recordBehaviorEvalEvent(BehaviorEvalEvent(
            conversationId: UUID(),
            assistantMessageId: UUID(),
            userMessageId: UUID(),
            outcome: .continued,
            latencySeconds: 8
        ))
        telemetry.recordBehaviorEvalEvent(BehaviorEvalEvent(
            conversationId: UUID(),
            assistantMessageId: UUID(),
            userMessageId: UUID(),
            outcome: .correction,
            latencySeconds: 12
        ))
        telemetry.recordBehaviorEvalEvent(BehaviorEvalEvent(
            conversationId: UUID(),
            assistantMessageId: UUID(),
            userMessageId: UUID(),
            outcome: .retry,
            latencySeconds: 20
        ))
        telemetry.recordBehaviorEvalEvent(BehaviorEvalEvent(
            conversationId: UUID(),
            assistantMessageId: UUID(),
            userMessageId: nil,
            outcome: .delete,
            latencySeconds: 4
        ))

        let snapshot = RuntimeHarnessService(telemetry: telemetry).loadSnapshot()

        XCTAssertEqual(snapshot.behaviorEval.totalOutcomeCount, 4)
        XCTAssertEqual(snapshot.behaviorEval.continuedCount, 1)
        XCTAssertEqual(snapshot.behaviorEval.correctionCount, 1)
        XCTAssertEqual(snapshot.behaviorEval.retryCount, 1)
        XCTAssertEqual(snapshot.behaviorEval.deleteCount, 1)
        XCTAssertEqual(snapshot.behaviorEval.keepRate, 0.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.behaviorEval.interventionRate, 0.75, accuracy: 0.0001)
        XCTAssertEqual(
            snapshot.behaviorEval.summaryText,
            "Behavior keep-rate 25% · correction 1 · retry 1 · delete 1"
        )
    }

    func testRuntimeHarnessBehaviorEvalIsQuietWithoutSignals() {
        let snapshot = RuntimeHarnessService(telemetry: makeRuntimeHarnessTelemetry()).loadSnapshot()

        XCTAssertEqual(snapshot.behaviorEval.totalOutcomeCount, 0)
        XCTAssertEqual(snapshot.behaviorEval.keepRate, 0)
        XCTAssertEqual(snapshot.behaviorEval.summaryText, "No behavior eval signals recorded.")
    }

    func testRuntimeHarnessSummarizesContextManifestSignals() {
        let telemetry = makeRuntimeHarnessTelemetry()
        telemetry.recordContextManifest(ContextManifestRecord(
            turnId: UUID(),
            conversationId: UUID(),
            assistantMessageId: UUID(),
            resources: [
                ContextManifestResource(
                    source: .memory,
                    label: "global_memory",
                    referenceId: "global_memory",
                    state: .loaded,
                    used: false
                ),
                ContextManifestResource(
                    source: .citation,
                    label: "node",
                    referenceId: UUID().uuidString,
                    state: .loaded,
                    used: true
                ),
                ContextManifestResource(
                    source: .skill,
                    label: "quick_action_skill",
                    referenceId: UUID().uuidString,
                    state: .indexed,
                    used: false
                )
            ]
        ))

        let snapshot = RuntimeHarnessService(telemetry: telemetry).loadSnapshot()

        XCTAssertEqual(snapshot.contextManifest.totalManifestCount, 1)
        XCTAssertEqual(snapshot.contextManifest.totalResourceCount, 3)
        XCTAssertEqual(snapshot.contextManifest.loadedMemoryCount, 1)
        XCTAssertEqual(snapshot.contextManifest.loadedCitationCount, 1)
        XCTAssertEqual(snapshot.contextManifest.indexedSkillCount, 1)
        XCTAssertEqual(snapshot.contextManifest.usedCitationCount, 1)
        XCTAssertEqual(snapshot.contextManifest.usageRate, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(
            snapshot.contextManifest.summaryText,
            "Context manifest 3 resources · 1 used · memory 1 · citation 1 · skill indexed 1"
        )
    }

    func testRuntimeHarnessContextManifestIsQuietWithoutSignals() {
        let snapshot = RuntimeHarnessService(telemetry: makeRuntimeHarnessTelemetry()).loadSnapshot()

        XCTAssertEqual(snapshot.contextManifest.totalManifestCount, 0)
        XCTAssertEqual(snapshot.contextManifest.totalResourceCount, 0)
        XCTAssertEqual(snapshot.contextManifest.summaryText, "No context manifest signals recorded.")
    }

    func testModelHarnessProfilesCoverEveryProviderWithExplicitCapabilities() {
        let profiles = ModelHarnessProfileCatalog.allProfiles

        XCTAssertEqual(Set(profiles.map(\.provider)), Set(LLMProvider.allCases))
        XCTAssertTrue(ModelHarnessProfileCatalog.coverageSummary.isComplete)

        let gemini = ModelHarnessProfileCatalog.profile(for: .gemini)
        XCTAssertEqual(gemini.toolSchema, .unsupported)
        XCTAssertEqual(gemini.cacheStrategy, .geminiCachedContent)
        XCTAssertEqual(gemini.thinkingStrategy, .geminiThinkingConfig)
        XCTAssertEqual(gemini.thinkingBudgetTokens, 2000)
        XCTAssertEqual(gemini.agentLoopSupport, .unsupported)
        XCTAssertEqual(gemini.fallbackStrategy, .inlineProviderError)

        let claude = ModelHarnessProfileCatalog.profile(for: .claude)
        XCTAssertEqual(claude.cacheStrategy, .anthropicEphemeralSystemPrefix)
        XCTAssertEqual(claude.thinkingStrategy, .anthropicThinkingBudget)
        XCTAssertEqual(claude.thinkingBudgetTokens, 1024)

        let local = ModelHarnessProfileCatalog.profile(for: .local)
        XCTAssertEqual(local.fallbackStrategy, .inlineConfigurationMessage)

        let openRouter = ModelHarnessProfileCatalog.profile(for: .openrouter)
        XCTAssertEqual(openRouter.toolSchema, .openRouterFunctionTools)
        XCTAssertEqual(openRouter.cacheStrategy, .openRouterSystemBlockCacheControl)
        XCTAssertEqual(openRouter.thinkingStrategy, .openRouterReasoningBudget)
        XCTAssertEqual(openRouter.agentLoopSupport, .openRouterClaudeSonnet46)
        XCTAssertEqual(openRouter.requiredToolLoopModel, "anthropic/claude-sonnet-4.6")
        XCTAssertEqual(openRouter.fallbackStrategy, .providerCannotUseToolLoop)
    }

    func testRuntimeHarnessSummarizesModelHarnessProfiles() {
        let snapshot = RuntimeHarnessService(telemetry: makeRuntimeHarnessTelemetry()).loadSnapshot()

        XCTAssertEqual(snapshot.modelHarnessProfiles.totalProviderCount, LLMProvider.allCases.count)
        XCTAssertEqual(snapshot.modelHarnessProfiles.coveredProviderCount, LLMProvider.allCases.count)
        XCTAssertEqual(snapshot.modelHarnessProfiles.agentLoopProviderCount, 1)
        XCTAssertEqual(snapshot.modelHarnessProfiles.cacheStrategyCount, 3)
        XCTAssertEqual(snapshot.modelHarnessProfiles.thinkingStrategyCount, 3)
        XCTAssertEqual(
            snapshot.modelHarnessProfiles.summaryText,
            "Model profiles 5/5 covered · agent loop 1 · cache 3 · thinking 3"
        )
    }

    func testModelHarnessProfileSummaryFlagsMissingProviderCoverage() {
        let incomplete = ModelHarnessProfileCoverageSummary.summarize(
            profiles: ModelHarnessProfileCatalog.allProfiles.filter { $0.provider != .local },
            expectedProviders: LLMProvider.allCases
        )

        XCTAssertFalse(incomplete.isComplete)
        XCTAssertEqual(incomplete.missingProviders, [.local])
        XCTAssertEqual(incomplete.summaryText, "Model profiles missing Local (MLX)")
    }

    func testWindowRuntimeSmokeUsesCGWindowListAsTheWindowOracle() throws {
        let repoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoURL.appendingPathComponent("scripts/smoke_nous_window.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("CGWindowListCopyWindowInfo"))
        XCTAssertTrue(script.contains("NOUS_DATABASE_PROFILE"))
        XCTAssertTrue(script.contains("-scheme Nous"))
        XCTAssertFalse(script.contains("count windows"))
    }

    private func makeRuntimeHarnessTelemetry() -> GovernanceTelemetryStore {
        let suiteName = "HarnessHealthTests.runtime.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return GovernanceTelemetryStore(defaults: defaults)
    }
}
