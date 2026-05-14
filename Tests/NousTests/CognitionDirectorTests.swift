import XCTest
@testable import Nous

final class CognitionDirectorTests: XCTestCase {
    func testFrameRecordsUsedAndSkippedOrgansWithoutPromptText() throws {
        let turnId = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let conversationId = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        let assistantId = UUID(uuidString: "00000000-0000-0000-0000-000000000203")!
        let skillId = UUID(uuidString: "00000000-0000-0000-0000-000000000204")!
        let evidenceId = UUID(uuidString: "00000000-0000-0000-0000-000000000205")!
        let citationId = UUID(uuidString: "00000000-0000-0000-0000-000000000206")!

        let plan = makePlan(
            turnId: turnId,
            conversationId: conversationId,
            promptTrace: PromptGovernanceTrace(
                promptLayers: ["anchor", "memory_evidence", "slow_cognition"],
                evidenceAttached: true,
                safetyPolicyInvoked: true,
                highRiskQueryDetected: false,
                turnSteward: TurnStewardTrace(
                    route: .ordinaryChat,
                    memoryPolicy: .full,
                    challengeStance: .surfaceTension,
                    responseShape: .answerNow,
                    projectSignalKind: nil,
                    source: .deterministic,
                    reason: "analysis skill cue"
                ),
                agentCoordination: AgentCoordinationTrace(
                    executionMode: .toolLoop,
                    quickActionMode: .plan,
                    provider: .claude,
                    reason: .explicitQuickActionToolLoop,
                    indexedSkillCount: 1
                ),
                slowCognitionTrace: SlowCognitionPromptTrace(
                    artifact: CognitionArtifact(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000207")!,
                        organ: .patternAnalyst,
                        title: "Weekly pattern",
                        summary: "A safe summary.",
                        confidence: 0.8,
                        jurisdiction: .selfReflection,
                        evidenceRefs: [CognitionEvidenceRef(source: .message, id: evidenceId.uuidString)]
                    )
                )
            ),
            judgeFallback: .ok,
            indexedSkillIds: [skillId],
            loadedSkillIds: [skillId],
            memoryEvidenceSourceIds: [evidenceId],
            loadedCitationIds: [citationId]
        )
        let committed = CommittedAssistantTurn(
            node: plan.prepared.node,
            assistantMessage: Message(
                id: assistantId,
                nodeId: conversationId,
                role: .assistant,
                content: "Assistant draft should not leak"
            ),
            messagesAfterAssistantAppend: plan.prepared.messagesAfterUserAppend
        )
        let review = CognitionArtifact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000208")!,
            organ: .reviewer,
            title: "Review",
            summary: "No issue.",
            confidence: 0.9,
            jurisdiction: .turnContext,
            evidenceRefs: [],
            riskFlags: ["unsupported_memory_reference"]
        )

        let frame = CognitionDirector().frame(plan: plan, committed: committed, reviewArtifact: review)

        XCTAssertEqual(frame.turnId, turnId)
        XCTAssertEqual(frame.conversationId, conversationId)
        XCTAssertEqual(frame.assistantMessageId, assistantId)
        XCTAssertEqual(frame.records.first(where: { $0.label == "turn_steward" })?.status, .used)
        XCTAssertEqual(frame.records.first(where: { $0.label == "memory_retriever" })?.status, .used)
        XCTAssertEqual(frame.records.first(where: { $0.label == "skill_fold" })?.status, .used)
        XCTAssertEqual(frame.records.first(where: { $0.label == "provocation_judge" })?.status, .used)
        XCTAssertEqual(frame.records.first(where: { $0.label == "slow_cognition" })?.status, .used)
        XCTAssertEqual(frame.records.first(where: { $0.label == "agent_loop" })?.status, .used)
        XCTAssertEqual(frame.records.first(where: { $0.label == "reviewer" })?.status, .used)
        XCTAssertTrue(frame.records.contains { $0.resourceIds.contains("skill:\(skillId.uuidString)") })
        XCTAssertTrue(frame.records.contains { $0.resourceIds.contains("citation:\(citationId.uuidString)") })

        let encoded = String(data: try JSONEncoder().encode(frame), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("Help me plan"))
        XCTAssertFalse(encoded.contains("Assistant draft should not leak"))
    }

    func testFrameMarksOptionalOrgansSkippedWhenAbsent() {
        let plan = makePlan(
            promptTrace: PromptGovernanceTrace(
                promptLayers: ["anchor", "chat_mode"],
                evidenceAttached: false,
                safetyPolicyInvoked: true,
                highRiskQueryDetected: false,
                turnSteward: TurnStewardTrace(
                    route: .ordinaryChat,
                    memoryPolicy: .lean,
                    challengeStance: .useSilently,
                    responseShape: .answerNow,
                    projectSignalKind: nil,
                    source: .deterministic,
                    reason: "memory opt-out cue"
                ),
                agentCoordination: AgentCoordinationTrace(
                    executionMode: .singleShot,
                    quickActionMode: nil,
                    provider: .local,
                    reason: .ordinaryChatSingleShot,
                    indexedSkillCount: 0
                )
            ),
            judgeFallback: .providerLocal
        )
        let committed = CommittedAssistantTurn(
            node: plan.prepared.node,
            assistantMessage: Message(nodeId: plan.prepared.node.id, role: .assistant, content: "ok"),
            messagesAfterAssistantAppend: plan.prepared.messagesAfterUserAppend
        )

        let frame = CognitionDirector().frame(plan: plan, committed: committed, reviewArtifact: nil)

        XCTAssertEqual(frame.records.first(where: { $0.label == "memory_retriever" })?.status, .skipped)
        XCTAssertEqual(frame.records.first(where: { $0.label == "skill_fold" })?.status, .skipped)
        XCTAssertEqual(frame.records.first(where: { $0.label == "provocation_judge" })?.status, .skipped)
        XCTAssertEqual(frame.records.first(where: { $0.label == "in_turn_pattern_naming" })?.status, .skipped)
        XCTAssertEqual(frame.records.first(where: { $0.label == "slow_cognition" })?.status, .skipped)
        XCTAssertEqual(frame.records.first(where: { $0.label == "agent_loop" })?.status, .skipped)
        XCTAssertEqual(frame.records.first(where: { $0.label == "reviewer" })?.status, .skipped)
    }

    func testFrameRecordsInTurnPatternSignalWithoutUserText() throws {
        let sensitiveInput = "I keep comparing myself to private school details and F-1 status."
        let plan = makePlan(
            promptTrace: PromptGovernanceTrace(
                promptLayers: ["anchor", "turn_steward"],
                evidenceAttached: false,
                safetyPolicyInvoked: true,
                highRiskQueryDetected: false,
                turnSteward: TurnStewardTrace(
                    route: .ordinaryChat,
                    memoryPolicy: .full,
                    challengeStance: .useSilently,
                    responseShape: .answerNow,
                    projectSignalKind: nil,
                    source: .deterministic,
                    reason: sensitiveInput,
                    inTurnPatternSignal: InTurnPatternSignal(
                        kind: .comparisonLoop,
                        confidence: 0.92,
                        surfacePolicy: .directName,
                        reasonCode: "comparison_status_progress"
                    )
                )
            ),
            judgeFallback: .judgeUnavailable
        )
        let committed = CommittedAssistantTurn(
            node: plan.prepared.node,
            assistantMessage: Message(nodeId: plan.prepared.node.id, role: .assistant, content: "ok"),
            messagesAfterAssistantAppend: plan.prepared.messagesAfterUserAppend
        )

        let frame = CognitionDirector().frame(plan: plan, committed: committed, reviewArtifact: nil)
        let record = try XCTUnwrap(frame.records.first { $0.label == "in_turn_pattern_naming" })
        let encoded = String(data: try JSONEncoder().encode(frame), encoding: .utf8)!

        XCTAssertEqual(record.organ, .patternAnalyst)
        XCTAssertEqual(record.status, .used)
        XCTAssertEqual(record.reason, "pattern:comparisonLoop reason:comparison_status_progress")
        XCTAssertEqual(record.resourceIds, ["pattern:comparisonLoop"])
        XCTAssertFalse(encoded.contains(sensitiveInput))
        XCTAssertFalse(encoded.contains("private school"))
    }

    func testFrameSanitizesUnexpectedPatternReasonCode() throws {
        let rawReason = "私立学校身份"
        let plan = makePlan(
            promptTrace: PromptGovernanceTrace(
                promptLayers: ["anchor", "turn_steward"],
                evidenceAttached: false,
                safetyPolicyInvoked: true,
                highRiskQueryDetected: false,
                turnSteward: TurnStewardTrace(
                    route: .ordinaryChat,
                    memoryPolicy: .full,
                    challengeStance: .useSilently,
                    responseShape: .answerNow,
                    projectSignalKind: nil,
                    source: .deterministic,
                    reason: "ordinary chat default",
                    inTurnPatternSignal: InTurnPatternSignal(
                        kind: .comparisonLoop,
                        confidence: 0.92,
                        surfacePolicy: .directName,
                        reasonCode: rawReason
                    )
                )
            ),
            judgeFallback: .judgeUnavailable
        )
        let committed = CommittedAssistantTurn(
            node: plan.prepared.node,
            assistantMessage: Message(nodeId: plan.prepared.node.id, role: .assistant, content: "ok"),
            messagesAfterAssistantAppend: plan.prepared.messagesAfterUserAppend
        )

        let frame = CognitionDirector().frame(plan: plan, committed: committed, reviewArtifact: nil)
        let record = try XCTUnwrap(frame.records.first { $0.label == "in_turn_pattern_naming" })
        let encoded = String(data: try JSONEncoder().encode(frame), encoding: .utf8)!

        XCTAssertEqual(record.reason, "pattern:comparisonLoop reason:invalid_reason_code")
        XCTAssertFalse(encoded.contains(rawReason))
        XCTAssertFalse(encoded.contains("private school"))
    }

    func testFrameRecordsReflectiveMeaningSignalWithoutUserTextOrHypothesis() throws {
        let sensitiveInput = "演唱会嗰个女仔真正牵住我嘅係咩"
        let plan = makePlan(
            promptTrace: PromptGovernanceTrace(
                promptLayers: ["anchor", "turn_steward"],
                evidenceAttached: false,
                safetyPolicyInvoked: true,
                highRiskQueryDetected: false,
                turnSteward: TurnStewardTrace(
                    route: .ordinaryChat,
                    memoryPolicy: .full,
                    challengeStance: .useSilently,
                    responseShape: .answerNow,
                    projectSignalKind: nil,
                    source: .deterministic,
                    reason: sensitiveInput,
                    reflectiveMeaningSignal: ReflectiveMeaningSignal(
                        confidence: 0.86,
                        surfacePolicy: .compact,
                        reasonCode: "reflective_meaning_request"
                    )
                )
            ),
            judgeFallback: .judgeUnavailable
        )
        let committed = CommittedAssistantTurn(
            node: plan.prepared.node,
            assistantMessage: Message(nodeId: plan.prepared.node.id, role: .assistant, content: "ok"),
            messagesAfterAssistantAppend: plan.prepared.messagesAfterUserAppend
        )

        let frame = CognitionDirector().frame(plan: plan, committed: committed, reviewArtifact: nil)
        let record = try XCTUnwrap(frame.records.first { $0.label == "reflective_meaning_signal" })
        let encoded = String(data: try JSONEncoder().encode(frame), encoding: .utf8)!

        XCTAssertEqual(record.organ, .meaningAnalyst)
        XCTAssertEqual(record.status, .used)
        XCTAssertEqual(record.reason, "surface:compact reason:reflective_meaning_request")
        XCTAssertTrue(record.resourceIds.isEmpty)
        XCTAssertFalse(encoded.contains(sensitiveInput))
        XCTAssertFalse(encoded.contains("演唱会"))
        XCTAssertFalse(encoded.contains("女仔"))
        XCTAssertFalse(encoded.contains("atmosphere"))
    }

    func testFrameMarksReflectiveMeaningSkippedWhenAbsent() throws {
        let plan = makePlan(
            promptTrace: PromptGovernanceTrace(
                promptLayers: ["anchor", "turn_steward"],
                evidenceAttached: false,
                safetyPolicyInvoked: true,
                highRiskQueryDetected: false,
                turnSteward: TurnStewardTrace(
                    route: .ordinaryChat,
                    memoryPolicy: .full,
                    challengeStance: .useSilently,
                    responseShape: .answerNow,
                    projectSignalKind: nil,
                    source: .deterministic,
                    reason: "ordinary chat default"
                )
            ),
            judgeFallback: .judgeUnavailable
        )
        let committed = CommittedAssistantTurn(
            node: plan.prepared.node,
            assistantMessage: Message(nodeId: plan.prepared.node.id, role: .assistant, content: "ok"),
            messagesAfterAssistantAppend: plan.prepared.messagesAfterUserAppend
        )

        let frame = CognitionDirector().frame(plan: plan, committed: committed, reviewArtifact: nil)
        let record = try XCTUnwrap(frame.records.first { $0.label == "reflective_meaning_signal" })

        XCTAssertEqual(record.organ, .meaningAnalyst)
        XCTAssertEqual(record.status, .skipped)
        XCTAssertEqual(record.reason, "no_reflective_meaning_signal")
    }

    func testFrameSanitizesUnexpectedReflectiveMeaningReasonCode() throws {
        let rawReason = "牵动点：演唱会氛围"
        let plan = makePlan(
            promptTrace: PromptGovernanceTrace(
                promptLayers: ["anchor", "turn_steward"],
                evidenceAttached: false,
                safetyPolicyInvoked: true,
                highRiskQueryDetected: false,
                turnSteward: TurnStewardTrace(
                    route: .ordinaryChat,
                    memoryPolicy: .full,
                    challengeStance: .useSilently,
                    responseShape: .answerNow,
                    projectSignalKind: nil,
                    source: .deterministic,
                    reason: "ordinary chat default",
                    reflectiveMeaningSignal: ReflectiveMeaningSignal(
                        confidence: 0.86,
                        surfacePolicy: .compact,
                        reasonCode: rawReason
                    )
                )
            ),
            judgeFallback: .judgeUnavailable
        )
        let committed = CommittedAssistantTurn(
            node: plan.prepared.node,
            assistantMessage: Message(nodeId: plan.prepared.node.id, role: .assistant, content: "ok"),
            messagesAfterAssistantAppend: plan.prepared.messagesAfterUserAppend
        )

        let frame = CognitionDirector().frame(plan: plan, committed: committed, reviewArtifact: nil)
        let record = try XCTUnwrap(frame.records.first { $0.label == "reflective_meaning_signal" })
        let encoded = String(data: try JSONEncoder().encode(frame), encoding: .utf8)!

        XCTAssertEqual(record.reason, "surface:compact reason:invalid_reason_code")
        XCTAssertFalse(encoded.contains(rawReason))
        XCTAssertFalse(encoded.contains("演唱会"))
    }

    func testFrameMarksReviewerFailedWhenSilentReviewThrows() throws {
        let plan = makePlan(
            promptTrace: PromptGovernanceTrace(
                promptLayers: ["anchor", "chat_mode"],
                evidenceAttached: false,
                safetyPolicyInvoked: true,
                highRiskQueryDetected: false,
                turnSteward: TurnStewardTrace(
                    route: .direction,
                    memoryPolicy: .full,
                    challengeStance: .surfaceTension,
                    responseShape: .narrowNextStep,
                    projectSignalKind: nil,
                    source: .deterministic,
                    reason: "explicit direction cue"
                )
            ),
            judgeFallback: .judgeUnavailable
        )
        let committed = CommittedAssistantTurn(
            node: plan.prepared.node,
            assistantMessage: Message(nodeId: plan.prepared.node.id, role: .assistant, content: "ok"),
            messagesAfterAssistantAppend: plan.prepared.messagesAfterUserAppend
        )

        let frame = CognitionDirector().frame(
            plan: plan,
            committed: committed,
            reviewArtifact: nil,
            reviewerFailed: true
        )
        let reviewer = try XCTUnwrap(frame.records.first { $0.label == "reviewer" })

        XCTAssertEqual(reviewer.status, .failed)
        XCTAssertEqual(reviewer.reason, "silent_review_failed")
    }

    func testFrameDoesNotPersistTurnStewardClassifierReasonText() throws {
        let rawClassifierReason = "The user wrote Help me plan the private visa timeline."
        let plan = makePlan(
            promptTrace: PromptGovernanceTrace(
                promptLayers: ["anchor", "turn_steward"],
                evidenceAttached: false,
                safetyPolicyInvoked: true,
                highRiskQueryDetected: false,
                turnSteward: TurnStewardTrace(
                    route: .plan,
                    memoryPolicy: .lean,
                    challengeStance: .surfaceTension,
                    responseShape: .producePlan,
                    projectSignalKind: nil,
                    source: .deterministic,
                    reason: rawClassifierReason,
                    routerMode: .active,
                    routerSource: .classifier,
                    confidence: 0.81,
                    fallbackUsed: false,
                    routerReason: rawClassifierReason
                )
            ),
            judgeFallback: .judgeUnavailable
        )
        let committed = CommittedAssistantTurn(
            node: plan.prepared.node,
            assistantMessage: Message(nodeId: plan.prepared.node.id, role: .assistant, content: "ok"),
            messagesAfterAssistantAppend: plan.prepared.messagesAfterUserAppend
        )

        let frame = CognitionDirector().frame(plan: plan, committed: committed, reviewArtifact: nil)
        let steward = try XCTUnwrap(frame.records.first { $0.label == "turn_steward" })
        let encoded = String(data: try JSONEncoder().encode(frame), encoding: .utf8)!

        XCTAssertFalse(steward.reason.contains(rawClassifierReason))
        XCTAssertFalse(encoded.contains("private visa timeline"))
        XCTAssertTrue(steward.reason.contains("route:plan"))
        XCTAssertTrue(steward.reason.contains("router:classifier"))
    }

    private func makePlan(
        turnId: UUID = UUID(),
        conversationId: UUID = UUID(),
        promptTrace: PromptGovernanceTrace,
        judgeFallback: JudgeFallbackReason,
        indexedSkillIds: Set<UUID> = [],
        loadedSkillIds: Set<UUID> = [],
        memoryEvidenceSourceIds: Set<UUID> = [],
        loadedCitationIds: Set<UUID> = []
    ) -> TurnPlan {
        let node = NousNode(id: conversationId, type: .conversation, title: "Current")
        let user = Message(nodeId: conversationId, role: .user, content: "Help me plan")
        return TurnPlan(
            turnId: turnId,
            prepared: PreparedConversationTurn(
                node: node,
                userMessage: user,
                messagesAfterUserAppend: [user]
            ),
            citations: [],
            sourceMaterials: [],
            promptTrace: promptTrace,
            effectiveMode: .companion,
            nextQuickActionModeIfCompleted: nil,
            agentLoopMode: promptTrace.agentCoordination?.executionMode == .toolLoop ? .plan : nil,
            judgeEventDraft: JudgeEvent(
                id: UUID(),
                ts: Date(timeIntervalSince1970: 100),
                nodeId: conversationId,
                messageId: nil,
                chatMode: .companion,
                provider: .gemini,
                verdictJSON: "{}",
                fallbackReason: judgeFallback,
                userFeedback: nil,
                feedbackTs: nil
            ),
            turnSlice: TurnSystemSlice(
                stable: "stable prompt should not leak",
                volatile: "volatile prompt should not leak"
            ),
            transcriptMessages: [],
            focusBlock: nil,
            provider: .gemini,
            indexedSkillIds: indexedSkillIds,
            loadedSkillIds: loadedSkillIds,
            memoryEvidenceSourceIds: memoryEvidenceSourceIds,
            loadedCitationIds: loadedCitationIds
        )
    }
}
