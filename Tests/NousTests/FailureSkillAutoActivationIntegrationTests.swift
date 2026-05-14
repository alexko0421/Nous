import XCTest
@testable import Nous

final class FailureSkillAutoActivationIntegrationTests: XCTestCase {
    func testApprovingEligibleJudgeFeedbackCandidateAutoActivatesWhenToggleIsOn() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let candidateStore = FailureSkillCandidateStore(nodeStore: nodeStore)
        let repairRunStore = FailureSkillRepairRunStore(nodeStore: nodeStore)
        let skillStore = SkillStore(nodeStore: nodeStore)
        let candidate = Self.makeCandidate()
        try candidateStore.upsertCandidate(candidate)

        let skill = try candidateStore.approveCandidate(
            id: candidate.id,
            skillStore: skillStore,
            repairRunStore: repairRunStore,
            autoActivationEnabled: true
        )

        let activated = try XCTUnwrap(candidateStore.fetchCandidate(id: candidate.id))
        XCTAssertEqual(activated.status, .activated)
        XCTAssertEqual(activated.activatedSkillId, skill?.id)
        XCTAssertEqual(try skillStore.fetchActiveSkills(userId: "alex").count, 1)
        XCTAssertThrowsError(try candidateStore.activateCandidate(id: candidate.id, skillStore: skillStore))
    }

    func testApprovingEligibleCandidateDoesNotAutoActivateWhenToggleIsOff() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let candidateStore = FailureSkillCandidateStore(nodeStore: nodeStore)
        let repairRunStore = FailureSkillRepairRunStore(nodeStore: nodeStore)
        let skillStore = SkillStore(nodeStore: nodeStore)
        let candidate = Self.makeCandidate()
        try candidateStore.upsertCandidate(candidate)

        let skill = try candidateStore.approveCandidate(
            id: candidate.id,
            skillStore: skillStore,
            repairRunStore: repairRunStore,
            autoActivationEnabled: false
        )

        let approved = try XCTUnwrap(candidateStore.fetchCandidate(id: candidate.id))
        XCTAssertNil(skill)
        XCTAssertEqual(approved.status, .approved)
        XCTAssertNil(approved.activatedSkillId)
        XCTAssertTrue(try skillStore.fetchActiveSkills(userId: "alex").isEmpty)
    }

    func testApproveCandidateDoesNotReapproveActivatedOrDismissedCandidate() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let candidateStore = FailureSkillCandidateStore(nodeStore: nodeStore)
        let repairRunStore = FailureSkillRepairRunStore(nodeStore: nodeStore)
        let skillStore = SkillStore(nodeStore: nodeStore)
        let candidate = Self.makeCandidate()
        try candidateStore.upsertCandidate(candidate)

        _ = try candidateStore.approveCandidate(
            id: candidate.id,
            skillStore: skillStore,
            repairRunStore: repairRunStore,
            autoActivationEnabled: true
        )

        XCTAssertThrowsError(try candidateStore.approveCandidate(
            id: candidate.id,
            skillStore: skillStore,
            repairRunStore: repairRunStore,
            autoActivationEnabled: true
        )) { error in
            XCTAssertEqual(error as? FailureSkillCandidateStoreError, .alreadyActivated)
        }

        let dismissed = Self.makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000B333")!,
            sourceId: "judge-2",
            status: .dismissed
        )
        try candidateStore.upsertCandidate(dismissed)

        XCTAssertThrowsError(try candidateStore.approveCandidate(
            id: dismissed.id,
            skillStore: skillStore,
            repairRunStore: repairRunStore,
            autoActivationEnabled: true
        )) { error in
            XCTAssertEqual(error as? FailureSkillCandidateStoreError, .approvalNotAllowed)
        }
    }

    private static func makeCandidate(
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-00000000B222")!,
        sourceId: String = "judge-1",
        status: FailureSkillStatus = .proposed
    ) -> FailureSkillCandidate {
        FailureSkillCandidate(
            id: id,
            userId: "alex",
            sourceKind: .judgeFeedback,
            sourceId: sourceId,
            turnId: nil,
            conversationId: nil,
            assistantMessageId: nil,
            signature: .judgeFeedbackTooRepetitive,
            repairKind: .promptSkill,
            status: status,
            evidence: [FailureSkillEvidence(source: .userFeedback, id: "judge-1", snippet: "too repetitive")],
            proposedSkillPayload: SkillPayload(
                payloadVersion: 1,
                name: "judge-feedback-too-repetitive",
                description: "Use when judge feedback says repeated challenges are getting stale.",
                useWhen: "Use when judge feedback says repeated challenges are getting stale.",
                source: .alex,
                trigger: SkillTrigger(kind: .always, modes: [], priority: 45),
                action: SkillAction(kind: .promptFragment, content: "Avoid repeating the same challenge frame; add novelty or skip the challenge."),
                rationale: "Alex explicitly marked the judge intervention as too repetitive.",
                antiPatternExamples: ["Repeating the same warning after Alex has already heard it."]
            ),
            checklist: SkillifyChecklist(
                rootCause: "Alex marked the judge intervention as too repetitive.",
                trigger: "thumbs-down judge feedback with too_repetitive reason",
                useWhen: "Use when judge feedback says repeated challenges are getting stale.",
                antiPatternExample: "Repeating the same warning after Alex has already heard it.",
                regressionTestReference: "ProvocationOrchestrationTests.testDownvoteFeedbackDetailCreatesFailureSkillCandidate",
                resolverTestReference: "SkillMatcherTests.testModeMatchFires",
                smokeTestCommand: "xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ProvocationOrchestrationTests/testDownvoteFeedbackDetailCreatesFailureSkillCandidate -only-testing:NousTests/SkillMatcherTests/testModeMatchFires -only-testing:NousTests/SkillifyChecklistEvaluatorTests"
            ),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            activatedSkillId: nil
        )
    }
}
