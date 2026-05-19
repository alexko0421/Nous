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

    func testHarnessDiagnosticTextNamesProtectedAnchorPath() {
        let snapshot = HarnessHealthSnapshot(
            changeClassification: HarnessChangeClassifier.classify(
                changedPaths: ["Sources/Nous/Resources/anchor.md"],
                rootSwiftFiles: []
            )
        )

        XCTAssertTrue(snapshot.diagnosticDetailText.contains("anchor.md changed"))
        XCTAssertTrue(snapshot.diagnosticDetailText.contains("Sources/Nous/Resources/anchor.md"))
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

    func testBehaviorEvalChangesAreFixtureSurfaceChanges() {
        let result = HarnessChangeClassifier.classify(
            changedPaths: [
                "Sources/Nous/Models/BehaviorEval.swift",
                "Sources/Nous/Models/BehaviorDataset.swift",
                "Sources/Nous/Services/BehaviorDatasetStudio.swift",
                "Sources/Nous/Models/BehaviorExperiment.swift",
                "Sources/Nous/Services/BehaviorExperimentRunner.swift",
                "Sources/Nous/Models/BehaviorFineTuneExport.swift",
                "Sources/Nous/Services/BehaviorFineTuneExporter.swift",
                "Sources/Nous/Services/BehaviorLocalModelEvaluator.swift",
                "Tests/NousTests/BehaviorEvalTests.swift"
            ],
            rootSwiftFiles: []
        )

        XCTAssertTrue(result.requiresFullGate)
        XCTAssertFalse(result.hasBlockingIssues)
        XCTAssertTrue(result.findings.contains(.fixtureSurfaceChanged))
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

    func testOutcomeContractHealthSummarizesMissingFields() {
        let ready = AgentOutcomeContractSummary(
            workerProfile: .worker,
            hasObjective: true,
            hasContextIncluded: true,
            hasContextExcluded: true,
            hasOwnershipPaths: true,
            hasForbiddenActions: true,
            hasSandboxPolicy: true,
            hasOutputSchema: true,
            hasStopCondition: true,
            hasFailureBehavior: true,
            hasAcceptanceRubric: true,
            hasVerificationEvidence: true
        )
        let missing = AgentOutcomeContractSummary(
            workerProfile: .explorer,
            hasObjective: true,
            hasContextIncluded: false,
            hasContextExcluded: true,
            hasOwnershipPaths: true,
            hasForbiddenActions: true,
            hasSandboxPolicy: true,
            hasOutputSchema: false,
            hasStopCondition: true,
            hasFailureBehavior: true,
            hasAcceptanceRubric: true,
            hasVerificationEvidence: true
        )

        let summary = AgentOutcomeContractHealthSummary.summarize([ready, missing])

        XCTAssertFalse(summary.isComplete)
        XCTAssertEqual(summary.totalIssueCount, 2)
        XCTAssertEqual(summary.completeIssueCount, 1)
        XCTAssertEqual(summary.incompleteIssueCount, 1)
        XCTAssertEqual(summary.missingFieldCounts["context-in"], 1)
        XCTAssertEqual(summary.missingFieldCounts["output"], 1)
        XCTAssertTrue(summary.summaryText.contains("Outcome contracts 1/2 ready"))
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

    func testRuntimeHarnessExposesLastVisibleResponseLanguageTarget() {
        let telemetry = makeRuntimeHarnessTelemetry()
        telemetry.recordPromptTrace(
            PromptGovernanceTrace(
                promptLayers: ["anchor", "chat_mode", "visible_response_language_target"],
                evidenceAttached: false,
                safetyPolicyInvoked: false,
                highRiskQueryDetected: false,
                visibleResponseLanguageTarget: .english,
                visibleResponseLanguageSource: .explicitLanguageRequest
            )
        )

        let snapshot = RuntimeHarnessService(telemetry: telemetry).loadSnapshot()

        XCTAssertEqual(snapshot.visibleResponseLanguageTarget, .english)
        XCTAssertEqual(snapshot.visibleResponseLanguageSource, .explicitLanguageRequest)
        XCTAssertEqual(snapshot.visibleResponseLanguageSummaryText, "Visible language target English · explicit language request")
    }

    func testRuntimeHarnessLanguageTargetIsQuietWithoutPromptTrace() {
        let snapshot = RuntimeHarnessService(telemetry: makeRuntimeHarnessTelemetry()).loadSnapshot()

        XCTAssertEqual(snapshot.visibleResponseLanguageTarget, .unspecified)
        XCTAssertEqual(snapshot.visibleResponseLanguageSource, .none)
        XCTAssertEqual(snapshot.visibleResponseLanguageSummaryText, "No visible language target recorded.")
    }

    func testRuntimeHarnessLanguageTargetSummaryNamesMandarin() {
        let snapshot = RuntimeHarnessSnapshot(
            visibleResponseLanguageTarget: .mandarin,
            visibleResponseLanguageSource: .currentTurnMandarin
        )

        XCTAssertEqual(snapshot.visibleResponseLanguageSummaryText, "Visible language target Mandarin · current message uses Mandarin")
    }

    func testRuntimeHarnessSummarizesDelegationMetricsAgainstSingleShotBaseline() {
        let telemetry = makeRuntimeHarnessTelemetry()
        let delegatedAssistantId = UUID(uuidString: "00000000-0000-0000-0000-00000000D101")!
        let singleShotAssistantId = UUID(uuidString: "00000000-0000-0000-0000-00000000D102")!
        telemetry.recordTurnCognitionSnapshot(TurnCognitionSnapshot(
            turnId: UUID(),
            conversationId: UUID(),
            assistantMessageId: delegatedAssistantId,
            promptLayers: ["anchor", "agent_coordination"],
            slowCognitionAttached: false,
            reviewArtifactId: UUID(),
            reviewRiskFlags: [],
            reviewConfidence: 0.8,
            agentCoordination: AgentCoordinationTrace(
                executionMode: .toolLoop,
                quickActionMode: .direction,
                provider: .openrouter,
                reason: .explicitQuickActionToolLoop,
                indexedSkillCount: 2
            )
        ))
        telemetry.recordTurnCognitionSnapshot(TurnCognitionSnapshot(
            turnId: UUID(),
            conversationId: UUID(),
            assistantMessageId: singleShotAssistantId,
            promptLayers: ["anchor", "agent_coordination"],
            slowCognitionAttached: false,
            reviewArtifactId: nil,
            reviewRiskFlags: [],
            reviewConfidence: nil,
            agentCoordination: AgentCoordinationTrace(
                executionMode: .singleShot,
                quickActionMode: .direction,
                provider: .gemini,
                reason: .providerCannotUseToolLoop,
                indexedSkillCount: 0
            )
        ))
        telemetry.recordBehaviorEvalEvent(BehaviorEvalEvent(
            conversationId: UUID(),
            assistantMessageId: delegatedAssistantId,
            userMessageId: UUID(),
            outcome: .retry
        ))
        telemetry.recordBehaviorEvalEvent(BehaviorEvalEvent(
            conversationId: UUID(),
            assistantMessageId: singleShotAssistantId,
            userMessageId: UUID(),
            outcome: .continued
        ))

        let snapshot = RuntimeHarnessService(telemetry: telemetry).loadSnapshot()

        XCTAssertEqual(snapshot.delegationMetrics.totalEventCount, 2)
        XCTAssertEqual(snapshot.delegationMetrics.delegatedTurnCount, 1)
        XCTAssertEqual(snapshot.delegationMetrics.verifierTurnCount, 1)
        XCTAssertEqual(snapshot.delegationMetrics.evaluatedDelegatedTurnCount, 1)
        XCTAssertEqual(snapshot.delegationMetrics.delegatedReworkCount, 1)
        XCTAssertEqual(snapshot.delegationMetrics.evaluatedSingleShotTurnCount, 1)
        XCTAssertEqual(snapshot.delegationMetrics.singleShotReworkCount, 0)
        XCTAssertEqual(snapshot.delegationMetrics.delegationReworkRate, 1, accuracy: 0.0001)
        XCTAssertEqual(snapshot.delegationMetrics.singleShotReworkRate, 0, accuracy: 0.0001)
        XCTAssertEqual(
            snapshot.delegationMetrics.summaryText,
            "Delegation 1 turns · rework 1/1 · single-shot 0/1 · verifier 1 turns"
        )
    }

    func testRuntimeHarnessDelegationMetricsAreQuietWithoutSignals() {
        let snapshot = RuntimeHarnessService(telemetry: makeRuntimeHarnessTelemetry()).loadSnapshot()

        XCTAssertEqual(snapshot.delegationMetrics.totalEventCount, 0)
        XCTAssertEqual(snapshot.delegationMetrics.summaryText, "No delegation metric signals recorded.")
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

    func testModelHarnessProfileChecksRequiredToolLoopModel() {
        let profile = ModelHarnessProfile(
            provider: .openrouter,
            toolSchema: .openRouterFunctionTools,
            cacheStrategy: .openRouterSystemBlockCacheControl,
            thinkingStrategy: .openRouterReasoningBudget,
            thinkingBudgetTokens: 1024,
            agentLoopSupport: .openRouterClaudeSonnet46,
            requiredToolLoopModel: "provider/required-tool-model",
            fallbackStrategy: .providerCannotUseToolLoop
        )

        XCTAssertTrue(profile.allowsAgentToolUse(model: "provider/required-tool-model"))
        XCTAssertFalse(profile.allowsAgentToolUse(model: "provider/other-model"))
    }

    func testTurnExecutorOnlyRequestsProviderReasoningBudgetForDeepTier() {
        XCTAssertNil(TurnExecutor.reasoningBudgetTokens(for: .gemini, latencyTier: .fast))
        XCTAssertNil(TurnExecutor.reasoningBudgetTokens(for: .gemini, latencyTier: .normal))
        XCTAssertEqual(TurnExecutor.reasoningBudgetTokens(for: .gemini, latencyTier: .deep), 2000)

        XCTAssertNil(TurnExecutor.reasoningBudgetTokens(for: .claude, latencyTier: .fast))
        XCTAssertNil(TurnExecutor.reasoningBudgetTokens(for: .claude, latencyTier: .normal))
        XCTAssertEqual(TurnExecutor.reasoningBudgetTokens(for: .claude, latencyTier: .deep), 1024)

        XCTAssertNil(TurnExecutor.reasoningBudgetTokens(for: .openrouter, latencyTier: .fast))
        XCTAssertNil(TurnExecutor.reasoningBudgetTokens(for: .openrouter, latencyTier: .normal))
        XCTAssertEqual(TurnExecutor.reasoningBudgetTokens(for: .openrouter, latencyTier: .deep), 1024)

        XCTAssertNil(TurnExecutor.reasoningBudgetTokens(for: .openai, latencyTier: .deep))
        XCTAssertNil(TurnExecutor.reasoningBudgetTokens(for: .local, latencyTier: .deep))
    }

    func testOpenRouterToolSupportUsesRequiredProfileModel() throws {
        let requiredModel = try XCTUnwrap(
            ModelHarnessProfileCatalog.profile(for: .openrouter).requiredToolLoopModel
        )

        XCTAssertTrue(ModelHarnessProfileCatalog.allowsAgentToolUse(for: .openrouter, model: requiredModel))
        XCTAssertFalse(ModelHarnessProfileCatalog.allowsAgentToolUse(
            for: .openrouter,
            model: "anthropic/claude-sonnet-4.5"
        ))

        var openRouter = OpenRouterLLMService(apiKey: "test")
        openRouter.model = requiredModel
        XCTAssertTrue(openRouter.supportsAgentToolUse)

        openRouter.model = "anthropic/claude-sonnet-4.5"
        XCTAssertFalse(openRouter.supportsAgentToolUse)
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

    func testHarnessDefaultsBehaviorEvalLiveModeToNever() throws {
        let repoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoURL.appendingPathComponent("scripts/nous_harness_check.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("NOUS_BEHAVIOR_EVAL_LIVE_MODE"))
        XCTAssertTrue(script.contains(#"DEFAULT_BEHAVIOR_EVAL_LIVE_MODE="never""#))
        XCTAssertFalse(script.contains(#"DEFAULT_BEHAVIOR_EVAL_LIVE_MODE="auto""#))
        XCTAssertTrue(script.contains(#"BEHAVIOR_EVAL_LIVE_MODE="${NOUS_BEHAVIOR_EVAL_LIVE_MODE:-$DEFAULT_BEHAVIOR_EVAL_LIVE_MODE}""#))
        XCTAssertTrue(script.contains(#"run_behavior_evals quick never"#))
        XCTAssertTrue(script.contains(#"run_behavior_evals full "$BEHAVIOR_EVAL_LIVE_MODE""#))
    }

    func testBehaviorEvalCLIDoesNotResolveAmbientProviderForOfflineRuns() throws {
        let repoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let main = try String(
            contentsOf: repoURL.appendingPathComponent("Sources/BehaviorEvalRunner/main.swift"),
            encoding: .utf8
        )
        let experimentCLI = try String(
            contentsOf: repoURL.appendingPathComponent("Sources/BehaviorEvalRunner/BehaviorExperimentCLI.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(main.contains("func resolvedProviderForLiveMode("))
        XCTAssertTrue(main.contains(#"guard live != "never" else { return nil }"#))
        XCTAssertTrue(main.contains("resolvedProviderForLiveMode(\n        live: options.live"))
        XCTAssertTrue(experimentCLI.contains("resolvedProviderForLiveMode(\n        live: options.live"))
        XCTAssertFalse(experimentCLI.contains("options.provider ?? resolvedProviderFromEnvironment()"))
    }

    private func makeRuntimeHarnessTelemetry() -> GovernanceTelemetryStore {
        let suiteName = "HarnessHealthTests.runtime.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return GovernanceTelemetryStore(defaults: defaults)
    }
}
