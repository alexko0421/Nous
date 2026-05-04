import XCTest
@testable import Nous

final class PromptGovernanceTraceTests: XCTestCase {
    func testDecodesLegacyJSONWithoutTurnSteward() throws {
        let json = """
        {
          "promptLayers": ["anchor", "chat_mode"],
          "evidenceAttached": false,
          "safetyPolicyInvoked": false,
          "highRiskQueryDetected": false
        }
        """.data(using: .utf8)!

        let trace = try JSONDecoder().decode(PromptGovernanceTrace.self, from: json)

        XCTAssertEqual(trace.promptLayers, ["anchor", "chat_mode"])
        XCTAssertNil(trace.turnSteward)
        XCTAssertNil(trace.agentCoordination)
        XCTAssertNil(trace.citationTrace)
    }

    func testEncodesAndDecodesTurnStewardTrace() throws {
        let stewardTrace = TurnStewardTrace(
            route: .brainstorm,
            memoryPolicy: .lean,
            challengeStance: .useSilently,
            responseShape: .listDirections,
            projectSignalKind: nil,
            source: .deterministic,
            reason: "explicit brainstorm cue",
            responseStance: .companion,
            judgePolicy: .off,
            routerMode: .shadow,
            routerSource: .deterministic,
            confidence: nil,
            softerFallback: nil,
            fallbackUsed: false
        )
        let trace = PromptGovernanceTrace(
            promptLayers: ["anchor", "turn_steward"],
            evidenceAttached: false,
            safetyPolicyInvoked: false,
            highRiskQueryDetected: false,
            turnSteward: stewardTrace
        )

        let data = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(PromptGovernanceTrace.self, from: data)

        XCTAssertEqual(decoded.turnSteward, stewardTrace)
    }

    func testDecodesLegacyTurnStewardTraceWithoutResponseStanceFields() throws {
        let json = """
        {
          "route": "ordinaryChat",
          "memoryPolicy": "full",
          "challengeStance": "useSilently",
          "responseShape": "answerNow",
          "source": "deterministic",
          "reason": "ordinary chat default"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TurnStewardTrace.self, from: json)

        XCTAssertEqual(decoded.route, .ordinaryChat)
        XCTAssertEqual(decoded.challengeStance, .useSilently)
        XCTAssertNil(decoded.responseStance)
        XCTAssertNil(decoded.judgePolicy)
        XCTAssertNil(decoded.routerMode)
        XCTAssertNil(decoded.routerSource)
        XCTAssertNil(decoded.confidence)
        XCTAssertNil(decoded.softerFallback)
        XCTAssertNil(decoded.fallbackUsed)
    }

    func testEncodesAndDecodesCitationTrace() throws {
        let citationTrace = CitationTrace(
            citationCount: 2,
            longGapCount: 1,
            minSimilarity: 0.62,
            maxSimilarity: 0.91
        )
        let trace = PromptGovernanceTrace(
            promptLayers: ["anchor", "citations"],
            evidenceAttached: false,
            safetyPolicyInvoked: false,
            highRiskQueryDetected: false,
            citationTrace: citationTrace
        )

        let data = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(PromptGovernanceTrace.self, from: data)

        XCTAssertEqual(decoded.citationTrace, citationTrace)
    }

    func testSlowCognitionLayerCountsAsMemorySignal() {
        let trace = PromptGovernanceTrace(
            promptLayers: ["anchor", "chat_mode", "slow_cognition"],
            evidenceAttached: false,
            safetyPolicyInvoked: false,
            highRiskQueryDetected: false
        )

        XCTAssertTrue(trace.hasMemorySignal)
    }

    func testEncodesAndDecodesAgentCoordinationTrace() throws {
        let coordination = AgentCoordinationTrace(
            executionMode: .toolLoop,
            quickActionMode: .direction,
            provider: .openrouter,
            reason: .explicitQuickActionToolLoop,
            indexedSkillCount: 2
        )
        let trace = PromptGovernanceTrace(
            promptLayers: ["anchor", "agent_coordination"],
            evidenceAttached: false,
            safetyPolicyInvoked: false,
            highRiskQueryDetected: false,
            agentCoordination: coordination
        )

        let data = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(PromptGovernanceTrace.self, from: data)

        XCTAssertEqual(decoded.agentCoordination, coordination)
    }

    func testGovernanceTraceAddsTurnStewardLayer() {
        let stewardTrace = TurnStewardTrace(
            route: .direction,
            memoryPolicy: .full,
            challengeStance: .surfaceTension,
            responseShape: .narrowNextStep,
            projectSignalKind: nil,
            source: .deterministic,
            reason: "explicit direction cue"
        )

        let trace = PromptContextAssembler.governanceTrace(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            turnSteward: stewardTrace
        )

        XCTAssertTrue(trace.promptLayers.contains("turn_steward"))
        XCTAssertEqual(trace.turnSteward, stewardTrace)
    }

    func testGovernanceTraceAddsOperatingContextLayerOnlyWhenNonEmpty() {
        let withContext = PromptContextAssembler.governanceTrace(
            operatingContext: OperatingContext(
                identity: "Alex is building Nous.",
                currentWork: "",
                communicationStyle: "",
                boundaries: ""
            ),
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        let emptyContext = PromptContextAssembler.governanceTrace(
            operatingContext: OperatingContext(),
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(withContext.promptLayers.contains("operating_context"))
        XCTAssertTrue(withContext.hasMemorySignal)
        XCTAssertFalse(emptyContext.promptLayers.contains("operating_context"))
        XCTAssertFalse(emptyContext.hasMemorySignal)
    }

    func testGovernanceTraceAddsAgentCoordinationLayer() {
        let coordination = AgentCoordinationTrace(
            executionMode: .singleShot,
            quickActionMode: .brainstorm,
            provider: .openrouter,
            reason: .modeSingleShotByContract,
            indexedSkillCount: 0
        )

        let trace = PromptContextAssembler.governanceTrace(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            agentCoordination: coordination
        )

        XCTAssertTrue(trace.promptLayers.contains("agent_coordination"))
        XCTAssertEqual(trace.agentCoordination, coordination)
    }

    func testPromptTraceEvaluationHarnessPassesHealthyMemoryRAGCase() {
        let trace = PromptGovernanceTrace(
            promptLayers: ["anchor", "chat_mode", "memory_evidence", "citations", "long_gap_bridge_guidance"],
            evidenceAttached: true,
            safetyPolicyInvoked: false,
            highRiskQueryDetected: false,
            citationTrace: CitationTrace(
                citationCount: 3,
                longGapCount: 1,
                minSimilarity: 0.68,
                maxSimilarity: 0.91
            )
        )

        let summary = PromptTraceEvaluationHarness().run([
            PromptTraceEvaluationCase(
                name: "healthy memory RAG",
                trace: trace,
                expectations: PromptTraceEvaluationExpectations(
                    memorySignal: .required,
                    citationQuality: PromptTraceCitationExpectation(
                        minimumSimilarity: 0.62,
                        maximumLongGapShare: 0.5
                    )
                )
            )
        ])

        XCTAssertTrue(summary.passed)
        XCTAssertEqual(summary.passedCount, 1)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(summary.results.first?.findings ?? [], [])
    }

    func testPromptTraceEvaluationSummaryReportsVerdictAndQualityScore() {
        let summary = PromptTraceEvaluationSummary(results: [
            PromptTraceEvaluationResult(
                name: "healthy",
                findings: []
            ),
            PromptTraceEvaluationResult(
                name: "long gap",
                findings: [
                    PromptTraceEvaluationFinding(
                        code: .longGapDominated,
                        severity: .warning,
                        message: "Long-gap citations dominated the retrieved evidence for this turn."
                    )
                ]
            )
        ])

        XCTAssertEqual(summary.verdict, .warning)
        XCTAssertEqual(summary.qualityScore, 90)
    }

    func testPromptTraceEvaluationHarnessFlagsWeakCitationEvidence() {
        let trace = PromptGovernanceTrace(
            promptLayers: ["anchor", "chat_mode", "citations"],
            evidenceAttached: false,
            safetyPolicyInvoked: false,
            highRiskQueryDetected: false,
            citationTrace: CitationTrace(
                citationCount: 2,
                longGapCount: 0,
                minSimilarity: 0.41,
                maxSimilarity: 0.73
            )
        )

        let result = PromptTraceEvaluationHarness().evaluate(
            PromptTraceEvaluationCase(
                name: "weak citation",
                trace: trace,
                expectations: PromptTraceEvaluationExpectations(
                    citationQuality: PromptTraceCitationExpectation(
                        minimumSimilarity: 0.62,
                        maximumLongGapShare: 0.5
                    )
                )
            )
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.findings.map(\.code), [.weakCitationEvidence])
        XCTAssertEqual(result.findings.first?.severity, .failure)
    }

    func testPromptTraceEvaluationHarnessFlagsMissingCitationTrace() {
        let trace = PromptGovernanceTrace(
            promptLayers: ["anchor", "chat_mode", "citations"],
            evidenceAttached: false,
            safetyPolicyInvoked: false,
            highRiskQueryDetected: false
        )

        let result = PromptTraceEvaluationHarness().evaluate(
            PromptTraceEvaluationCase(
                name: "missing citation trace",
                trace: trace,
                expectations: PromptTraceEvaluationExpectations(
                    citationQuality: PromptTraceCitationExpectation(
                        minimumSimilarity: 0.62,
                        maximumLongGapShare: 0.5
                    )
                )
            )
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.findings.map(\.code), [.missingCitationTrace])
    }

    func testPromptTraceEvaluationHarnessFlagsLongGapDominanceAsWarning() {
        let trace = PromptGovernanceTrace(
            promptLayers: ["anchor", "chat_mode", "citations", "long_gap_bridge_guidance"],
            evidenceAttached: false,
            safetyPolicyInvoked: false,
            highRiskQueryDetected: false,
            citationTrace: CitationTrace(
                citationCount: 3,
                longGapCount: 2,
                minSimilarity: 0.72,
                maxSimilarity: 0.88
            )
        )

        let result = PromptTraceEvaluationHarness().evaluate(
            PromptTraceEvaluationCase(
                name: "long gap dominated",
                trace: trace,
                expectations: PromptTraceEvaluationExpectations(
                    citationQuality: PromptTraceCitationExpectation(
                        minimumSimilarity: 0.62,
                        maximumLongGapShare: 0.5
                    )
                )
            )
        )

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.findings.map(\.code), [.longGapDominated])
        XCTAssertEqual(result.findings.first?.severity, .warning)
    }

    func testPromptTraceEvaluationHarnessFlagsSafetyMiss() {
        let trace = PromptGovernanceTrace(
            promptLayers: ["anchor", "chat_mode"],
            evidenceAttached: false,
            safetyPolicyInvoked: false,
            highRiskQueryDetected: true
        )

        let result = PromptTraceEvaluationHarness().evaluate(
            PromptTraceEvaluationCase(name: "safety miss", trace: trace)
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.findings.map(\.code), [.safetyPolicyMissing])
    }

    func testPromptTraceEvaluationHarnessRequiresHighRiskPromptLayer() {
        let trace = PromptGovernanceTrace(
            promptLayers: ["anchor", "chat_mode"],
            evidenceAttached: false,
            safetyPolicyInvoked: true,
            highRiskQueryDetected: true
        )

        let result = PromptTraceEvaluationHarness().evaluate(
            PromptTraceEvaluationCase(
                name: "high risk layer missing",
                trace: trace,
                expectations: PromptTraceEvaluationExpectations(
                    requiredPromptLayers: ["high_risk_safety_mode"]
                )
            )
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.findings.map(\.code), [.missingRequiredPromptLayer])
    }

    func testPromptTraceEvaluationHarnessFlagsUnexpectedMemorySignal() {
        let trace = PromptGovernanceTrace(
            promptLayers: ["anchor", "chat_mode", "citations"],
            evidenceAttached: false,
            safetyPolicyInvoked: false,
            highRiskQueryDetected: false,
            citationTrace: CitationTrace(
                citationCount: 1,
                longGapCount: 0,
                minSimilarity: 0.72,
                maxSimilarity: 0.72
            )
        )

        let result = PromptTraceEvaluationHarness().evaluate(
            PromptTraceEvaluationCase(
                name: "memory should be absent",
                trace: trace,
                expectations: PromptTraceEvaluationExpectations(memorySignal: .forbidden)
            )
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.findings.map(\.code), [.unexpectedMemorySignal])
    }

    func testPromptTraceEvaluationHarnessFlagsForbiddenDurableMemoryLayer() {
        let trace = PromptGovernanceTrace(
            promptLayers: ["anchor", "chat_mode", "user_model"],
            evidenceAttached: false,
            safetyPolicyInvoked: false,
            highRiskQueryDetected: false
        )

        let result = PromptTraceEvaluationHarness().evaluate(
            PromptTraceEvaluationCase(
                name: "durable memory forbidden",
                trace: trace,
                expectations: PromptTraceEvaluationExpectations(
                    memorySignal: .forbidden,
                    forbiddenPromptLayers: ["user_model"]
                )
            )
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(Set(result.findings.map(\.code)), Set([.unexpectedMemorySignal, .unexpectedPromptLayer]))
    }

    func testPromptTraceEvaluationHarnessFlagsSlowCognitionLayerWithoutTrace() {
        let trace = PromptGovernanceTrace(
            promptLayers: ["anchor", "chat_mode", "slow_cognition"],
            evidenceAttached: false,
            safetyPolicyInvoked: false,
            highRiskQueryDetected: false
        )

        let result = PromptTraceEvaluationHarness().evaluate(
            PromptTraceEvaluationCase(name: "missing slow cognition trace", trace: trace)
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.findings.map(\.code), [.missingSlowCognitionTrace])
    }

    func testPromptTraceEvaluationFixtureSuiteCoversBaselineFailuresAndWarnings() {
        let summary = PromptTraceEvaluationFixtureSuite.baseline.run()
        let findingCodes = summary.results.flatMap { $0.findings.map(\.code) }

        XCTAssertEqual(summary.results.count, 5)
        XCTAssertEqual(summary.failedCount, 3)
        XCTAssertEqual(summary.warningCount, 1)
        XCTAssertTrue(findingCodes.contains(.weakCitationEvidence))
        XCTAssertTrue(findingCodes.contains(.missingCitationTrace))
        XCTAssertTrue(findingCodes.contains(.safetyPolicyMissing))
        XCTAssertTrue(findingCodes.contains(.longGapDominated))
        XCTAssertEqual(summary.verdict, .failure)
    }
}

final class GovernanceTelemetryStoreTests: XCTestCase {
    func testPolicyOnlyPromptTraceDoesNotIncrementMemoryUsefulness() {
        let telemetry = makeTelemetry()

        telemetry.recordPromptTrace(
            PromptGovernanceTrace(
                promptLayers: [
                    "anchor",
                    "memory_interpretation_policy",
                    "core_safety_policy",
                    "stoic_grounding_policy",
                    "real_world_decision_policy",
                    "summary_output_policy",
                    "conversation_title_output_policy",
                    "chat_mode",
                    "high_risk_safety_mode"
                ],
                evidenceAttached: false,
                safetyPolicyInvoked: true,
                highRiskQueryDetected: true
            )
        )

        XCTAssertEqual(telemetry.value(for: .memoryUsefulness), 0)
        XCTAssertEqual(telemetry.value(for: .safetyMissRate), 0)
    }

    func testMemoryPromptTraceIncrementsMemoryUsefulness() {
        let telemetry = makeTelemetry()

        telemetry.recordPromptTrace(
            PromptGovernanceTrace(
                promptLayers: ["anchor", "chat_mode", "citations"],
                evidenceAttached: false,
                safetyPolicyInvoked: false,
                highRiskQueryDetected: false
            )
        )

        XCTAssertEqual(telemetry.value(for: .memoryUsefulness), 1)
    }

    func testRecordPromptTraceStoresEvaluationSummary() {
        let telemetry = makeTelemetry()

        telemetry.recordPromptTrace(
            PromptGovernanceTrace(
                promptLayers: ["anchor", "chat_mode", "citations"],
                evidenceAttached: false,
                safetyPolicyInvoked: false,
                highRiskQueryDetected: false,
                citationTrace: CitationTrace(
                    citationCount: 2,
                    longGapCount: 0,
                    minSimilarity: 0.41,
                    maxSimilarity: 0.72
                )
            )
        )

        let summary = telemetry.lastPromptEvaluationSummary

        XCTAssertEqual(summary?.results.count, 1)
        XCTAssertEqual(summary?.failedCount, 1)
        XCTAssertEqual(summary?.results.first?.findings.map(\.code), [.weakCitationEvidence])
    }

    func testRecordPromptTraceStoresSafetyMissEvaluation() {
        let telemetry = makeTelemetry()

        telemetry.recordPromptTrace(
            PromptGovernanceTrace(
                promptLayers: ["anchor", "chat_mode"],
                evidenceAttached: false,
                safetyPolicyInvoked: false,
                highRiskQueryDetected: true
            )
        )

        XCTAssertEqual(
            telemetry.lastPromptEvaluationSummary?.results.first?.findings.map(\.code),
            [.safetyPolicyMissing]
        )
        XCTAssertEqual(telemetry.value(for: .safetyMissRate), 1)
    }

    func testRecordPromptTraceAggregatesEvaluationMetrics() {
        let telemetry = makeTelemetry()

        telemetry.recordPromptTrace(
            PromptGovernanceTrace(
                promptLayers: ["anchor", "chat_mode", "citations"],
                evidenceAttached: false,
                safetyPolicyInvoked: false,
                highRiskQueryDetected: false,
                citationTrace: CitationTrace(
                    citationCount: 1,
                    longGapCount: 0,
                    minSimilarity: 0.72,
                    maxSimilarity: 0.72
                )
            )
        )
        telemetry.recordPromptTrace(
            PromptGovernanceTrace(
                promptLayers: ["anchor", "chat_mode", "citations"],
                evidenceAttached: false,
                safetyPolicyInvoked: false,
                highRiskQueryDetected: false,
                citationTrace: CitationTrace(
                    citationCount: 2,
                    longGapCount: 0,
                    minSimilarity: 0.41,
                    maxSimilarity: 0.72
                )
            )
        )
        telemetry.recordPromptTrace(
            PromptGovernanceTrace(
                promptLayers: ["anchor", "chat_mode", "citations", "long_gap_bridge_guidance"],
                evidenceAttached: false,
                safetyPolicyInvoked: false,
                highRiskQueryDetected: false,
                citationTrace: CitationTrace(
                    citationCount: 3,
                    longGapCount: 2,
                    minSimilarity: 0.72,
                    maxSimilarity: 0.88
                )
            )
        )

        let metrics = telemetry.promptEvaluationMetrics

        XCTAssertEqual(metrics.runCount, 3)
        XCTAssertEqual(metrics.failedRunCount, 1)
        XCTAssertEqual(metrics.warningRunCount, 1)
        XCTAssertEqual(metrics.findingCount(.weakCitationEvidence), 1)
        XCTAssertEqual(metrics.findingCount(.longGapDominated), 1)
        XCTAssertEqual(metrics.passRate, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testPromptEvaluationMetricsSurviveStoreRecreation() {
        let suiteName = "GovernanceTelemetryStoreTests.metrics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let first = GovernanceTelemetryStore(defaults: defaults)

        first.recordPromptTrace(
            PromptGovernanceTrace(
                promptLayers: ["anchor", "chat_mode"],
                evidenceAttached: false,
                safetyPolicyInvoked: false,
                highRiskQueryDetected: true
            )
        )

        let second = GovernanceTelemetryStore(defaults: defaults)

        XCTAssertEqual(second.promptEvaluationMetrics.runCount, 1)
        XCTAssertEqual(second.promptEvaluationMetrics.failedRunCount, 1)
        XCTAssertEqual(second.promptEvaluationMetrics.findingCount(.safetyPolicyMissing), 1)
    }

    func testRecordsMemorySuppressionByReason() {
        let telemetry = makeTelemetry()

        telemetry.recordMemoryStorageSuppressed(reason: .hardOptOut)
        telemetry.recordMemoryStorageSuppressed(reason: .sensitiveConsentRequired)
        telemetry.recordMemoryStorageSuppressed(reason: .hardOptOut)

        XCTAssertEqual(telemetry.memoryStorageSuppressedCount(), 3)
        XCTAssertEqual(telemetry.memoryStorageSuppressedCount(reason: .hardOptOut), 2)
        XCTAssertEqual(telemetry.memoryStorageSuppressedCount(reason: .sensitiveConsentRequired), 1)
        XCTAssertEqual(telemetry.memoryStorageSuppressedCount(reason: .unspecified), 0)
    }

    func testRecordCognitionArtifactStoresLatestAndCountsUnsupportedMemoryReference() {
        let telemetry = makeTelemetry()
        let artifact = CognitionArtifact(
            organ: .reviewer,
            title: "Silent reviewer audit",
            summary: "Reviewer flagged a possible memory-boundary issue.",
            confidence: 0.62,
            jurisdiction: .turnContext,
            evidenceRefs: [
                CognitionEvidenceRef(source: .message, id: UUID().uuidString, quote: "plan")
            ],
            riskFlags: ["unsupported_memory_reference"],
            trace: CognitionTrace(producer: .reviewer, sourceJobId: "silent_post_turn_review")
        )

        telemetry.recordCognitionArtifact(artifact)

        XCTAssertEqual(telemetry.lastCognitionArtifact?.id, artifact.id)
        XCTAssertEqual(telemetry.lastCognitionArtifact?.organ, .reviewer)
        XCTAssertEqual(telemetry.value(for: .overInferenceRate), 1)
    }

    func testRecordCognitionArtifactIgnoresInvalidArtifacts() {
        let telemetry = makeTelemetry()
        let artifact = CognitionArtifact(
            organ: .reviewer,
            title: "Invalid reviewer audit",
            summary: "This should not be stored.",
            confidence: 1.2,
            jurisdiction: .turnContext,
            evidenceRefs: [],
            trace: CognitionTrace(producer: .reviewer, sourceJobId: "silent_post_turn_review")
        )

        telemetry.recordCognitionArtifact(artifact)

        XCTAssertNil(telemetry.lastCognitionArtifact)
        XCTAssertEqual(telemetry.value(for: .overInferenceRate), 0)
    }

    func testRecordConversationRecoveryStoresLatestAndCounts() {
        let telemetry = makeTelemetry()
        let event = ConversationRecoveryTelemetryEvent(
            reason: .missingCurrentNode,
            originalNodeId: UUID(uuidString: "00000000-0000-0000-0000-000000000801")!,
            recoveredNodeId: UUID(uuidString: "00000000-0000-0000-0000-000000000802")!,
            rebasedMessageCount: 2,
            recordedAt: Date(timeIntervalSince1970: 123)
        )

        telemetry.recordConversationRecovery(event)

        XCTAssertEqual(telemetry.conversationRecoveryCount(), 1)
        XCTAssertEqual(telemetry.lastConversationRecovery, event)
    }

    func testRecordTurnCognitionSnapshotStoresLatestAndCountsWithoutPromptText() throws {
        let telemetry = makeTelemetry()
        let snapshot = TurnCognitionSnapshot(
            turnId: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!,
            conversationId: UUID(uuidString: "00000000-0000-0000-0000-000000000902")!,
            assistantMessageId: UUID(uuidString: "00000000-0000-0000-0000-000000000903")!,
            promptLayers: ["anchor", "chat_mode", "slow_cognition"],
            slowCognitionAttached: true,
            slowCognitionArtifactId: UUID(uuidString: "00000000-0000-0000-0000-000000000907")!,
            slowCognitionEvidenceRefIds: ["evidence-a", "evidence-b"],
            slowCognitionEvidenceRefCount: 2,
            reviewArtifactId: UUID(uuidString: "00000000-0000-0000-0000-000000000904")!,
            reviewRiskFlags: ["unsupported_memory_reference"],
            reviewConfidence: 0.62,
            conversationRecoveryReason: "missing_current_node",
            conversationRecoveryOriginalNodeId: UUID(uuidString: "00000000-0000-0000-0000-000000000905")!,
            conversationRecoveryRecoveredNodeId: UUID(uuidString: "00000000-0000-0000-0000-000000000906")!,
            conversationRecoveryRebasedMessageCount: 2,
            recordedAt: Date(timeIntervalSince1970: 456)
        )

        telemetry.recordTurnCognitionSnapshot(snapshot)

        XCTAssertEqual(telemetry.turnCognitionSnapshotCount(), 1)
        XCTAssertEqual(telemetry.lastTurnCognitionSnapshot, snapshot)
        let encoded = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("Help me plan"))
        XCTAssertFalse(encoded.contains("Assistant draft"))
    }

    func testDecodesLegacyTurnCognitionSnapshotWithoutSlowProvenance() throws {
        let json = """
        {
          "turnId": "00000000-0000-0000-0000-000000000911",
          "conversationId": "00000000-0000-0000-0000-000000000912",
          "assistantMessageId": "00000000-0000-0000-0000-000000000913",
          "promptLayers": ["anchor", "chat_mode", "slow_cognition"],
          "slowCognitionAttached": true,
          "reviewArtifactId": "00000000-0000-0000-0000-000000000914",
          "reviewRiskFlags": [],
          "reviewConfidence": 0.74,
          "conversationRecoveryRebasedMessageCount": 0,
          "recordedAt": 456
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(TurnCognitionSnapshot.self, from: json)

        XCTAssertTrue(snapshot.slowCognitionAttached)
        XCTAssertNil(snapshot.slowCognitionArtifactId)
        XCTAssertEqual(snapshot.slowCognitionEvidenceRefIds, [])
        XCTAssertEqual(snapshot.slowCognitionEvidenceRefCount, 0)
    }

    func testTurnCognitionSummaryIsEmptyWithoutSnapshots() {
        let telemetry = makeTelemetry()

        let summary = telemetry.turnCognitionSummary

        XCTAssertEqual(summary.totalTurnCount, 0)
        XCTAssertEqual(summary.slowCognitionAttachedCount, 0)
        XCTAssertEqual(summary.slowCognitionSourcedCount, 0)
        XCTAssertEqual(summary.reviewedTurnCount, 0)
        XCTAssertEqual(summary.conversationRecoveryTurnCount, 0)
        XCTAssertEqual(summary.reviewRiskFlagCounts, [:])
        XCTAssertEqual(summary.slowCognitionAttachmentRate, 0)
        XCTAssertEqual(summary.slowCognitionSourceCoverageRate, 0)
        XCTAssertEqual(summary.reviewCoverageRate, 0)
        XCTAssertEqual(summary.overInferenceRate, 0)
        XCTAssertNil(summary.lastSnapshot)
    }

    func testTurnCognitionSummaryAggregatesRuntimeSignalsWithoutPromptText() throws {
        let telemetry = makeTelemetry()
        let first = makeSnapshot(
            suffix: "921",
            promptLayers: ["anchor", "chat_mode", "slow_cognition"],
            slowCognitionAttached: true,
            slowCognitionArtifactId: UUID(uuidString: "00000000-0000-0000-0000-000000000931")!,
            slowCognitionEvidenceRefIds: ["evidence-a", "evidence-b"],
            slowCognitionEvidenceRefCount: 2,
            reviewArtifactId: UUID(uuidString: "00000000-0000-0000-0000-000000000941")!
        )
        let second = makeSnapshot(
            suffix: "922",
            promptLayers: ["anchor", "chat_mode", "slow_cognition"],
            slowCognitionAttached: true,
            reviewArtifactId: UUID(uuidString: "00000000-0000-0000-0000-000000000942")!,
            reviewRiskFlags: ["unsupported_memory_reference", "weak_reasoning"],
            conversationRecoveryReason: "missing_current_node",
            conversationRecoveryRebasedMessageCount: 1
        )
        let third = makeSnapshot(
            suffix: "923",
            promptLayers: ["anchor", "chat_mode"],
            slowCognitionAttached: false
        )

        telemetry.recordTurnCognitionSnapshot(first)
        telemetry.recordTurnCognitionSnapshot(second)
        telemetry.recordTurnCognitionSnapshot(third)

        let summary = telemetry.turnCognitionSummary

        XCTAssertEqual(summary.totalTurnCount, 3)
        XCTAssertEqual(summary.slowCognitionAttachedCount, 2)
        XCTAssertEqual(summary.slowCognitionSourcedCount, 1)
        XCTAssertEqual(summary.reviewedTurnCount, 2)
        XCTAssertEqual(summary.conversationRecoveryTurnCount, 1)
        XCTAssertEqual(summary.reviewRiskFlagCount("unsupported_memory_reference"), 1)
        XCTAssertEqual(summary.reviewRiskFlagCount("weak_reasoning"), 1)
        XCTAssertEqual(summary.reviewRiskFlagCount("missing"), 0)
        XCTAssertEqual(summary.slowCognitionAttachmentRate, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(summary.slowCognitionSourceCoverageRate, 0.5, accuracy: 0.0001)
        XCTAssertEqual(summary.reviewCoverageRate, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(summary.overInferenceRate, 0.5, accuracy: 0.0001)
        XCTAssertEqual(summary.lastSnapshot, third)

        let encoded = String(data: try JSONEncoder().encode(summary.reviewRiskFlagCounts), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("Help me plan"))
        XCTAssertFalse(encoded.contains("Assistant draft"))
    }

    func testTurnCognitionSummaryDoesNotCountSourceWhenSlowSignalWasNotAttached() {
        let telemetry = makeTelemetry()
        let inconsistentSnapshot = makeSnapshot(
            suffix: "924",
            promptLayers: ["anchor", "chat_mode"],
            slowCognitionAttached: false,
            slowCognitionArtifactId: UUID(uuidString: "00000000-0000-0000-0000-000000000934")!,
            slowCognitionEvidenceRefIds: ["evidence-a"],
            slowCognitionEvidenceRefCount: 1
        )

        telemetry.recordTurnCognitionSnapshot(inconsistentSnapshot)

        let summary = telemetry.turnCognitionSummary
        XCTAssertEqual(summary.slowCognitionAttachedCount, 0)
        XCTAssertEqual(summary.slowCognitionSourcedCount, 0)
        XCTAssertEqual(summary.slowCognitionSourceCoverageRate, 0)
    }

    func testRecentTurnCognitionSnapshotsReturnNewestFirstAndHonorLimit() {
        let telemetry = makeTelemetry()
        let first = makeSnapshot(suffix: "925", promptLayers: ["anchor"], slowCognitionAttached: false)
        let second = makeSnapshot(suffix: "926", promptLayers: ["anchor", "slow_cognition"], slowCognitionAttached: true)
        let third = makeSnapshot(suffix: "927", promptLayers: ["anchor"], slowCognitionAttached: false)

        telemetry.recordTurnCognitionSnapshot(first)
        telemetry.recordTurnCognitionSnapshot(second)
        telemetry.recordTurnCognitionSnapshot(third)

        XCTAssertEqual(telemetry.recentTurnCognitionSnapshots(limit: 2).map(\.turnId), [
            third.turnId,
            second.turnId
        ])
        XCTAssertEqual(telemetry.recentTurnCognitionSnapshots(limit: 0), [])
        XCTAssertEqual(telemetry.recentTurnCognitionSnapshots(limit: -3), [])
    }

    func testRecentTurnCognitionSnapshotsKeepBoundedWindowAndSurviveStoreRecreation() {
        let suiteName = "GovernanceTelemetryStoreTests.recent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let firstStore = GovernanceTelemetryStore(defaults: defaults)
        let snapshots = (900..<925).map { suffix in
            makeSnapshot(
                suffix: String(suffix),
                promptLayers: ["anchor"],
                slowCognitionAttached: false
            )
        }

        for snapshot in snapshots {
            firstStore.recordTurnCognitionSnapshot(snapshot)
        }

        let secondStore = GovernanceTelemetryStore(defaults: defaults)
        let recent = secondStore.recentTurnCognitionSnapshots(limit: 50)

        XCTAssertEqual(recent.count, 20)
        XCTAssertEqual(recent.first?.turnId, snapshots.last?.turnId)
        XCTAssertEqual(recent.last?.turnId, snapshots[5].turnId)
    }

    func testRecentTurnCognitionSnapshotsIgnoreMalformedStoredWindow() {
        let suiteName = "GovernanceTelemetryStoreTests.malformedRecent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(Data("not json".utf8), forKey: "nous.governance.recentTurnCognitionSnapshots")
        let telemetry = GovernanceTelemetryStore(defaults: defaults)

        XCTAssertEqual(telemetry.recentTurnCognitionSnapshots(limit: 10), [])
    }

    private func makeTelemetry() -> GovernanceTelemetryStore {
        let suiteName = "GovernanceTelemetryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return GovernanceTelemetryStore(defaults: defaults)
    }

    private func makeSnapshot(
        suffix: String,
        promptLayers: [String],
        slowCognitionAttached: Bool,
        slowCognitionArtifactId: UUID? = nil,
        slowCognitionEvidenceRefIds: [String] = [],
        slowCognitionEvidenceRefCount: Int = 0,
        reviewArtifactId: UUID? = nil,
        reviewRiskFlags: [String] = [],
        conversationRecoveryReason: String? = nil,
        conversationRecoveryRebasedMessageCount: Int = 0
    ) -> TurnCognitionSnapshot {
        TurnCognitionSnapshot(
            turnId: UUID(uuidString: "00000000-0000-0000-0000-000000000\(suffix)")!,
            conversationId: UUID(uuidString: "00000000-0000-0000-0000-000000001\(suffix)")!,
            assistantMessageId: UUID(uuidString: "00000000-0000-0000-0000-000000002\(suffix)")!,
            promptLayers: promptLayers,
            slowCognitionAttached: slowCognitionAttached,
            slowCognitionArtifactId: slowCognitionArtifactId,
            slowCognitionEvidenceRefIds: slowCognitionEvidenceRefIds,
            slowCognitionEvidenceRefCount: slowCognitionEvidenceRefCount,
            reviewArtifactId: reviewArtifactId,
            reviewRiskFlags: reviewRiskFlags,
            reviewConfidence: reviewArtifactId == nil ? nil : 0.74,
            conversationRecoveryReason: conversationRecoveryReason,
            conversationRecoveryOriginalNodeId: nil,
            conversationRecoveryRecoveredNodeId: nil,
            conversationRecoveryRebasedMessageCount: conversationRecoveryRebasedMessageCount,
            recordedAt: Date(timeIntervalSince1970: TimeInterval(Int(suffix) ?? 0))
        )
    }
}
