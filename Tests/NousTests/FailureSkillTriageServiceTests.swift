import XCTest
@testable import Nous

final class FailureSkillTriageServiceTests: XCTestCase {
    func testContextSensitiveTelemetryCandidateGetsChecklistButNoBroadPromptSkillPayload() {
        let candidate = makeCandidate(signature: .sourceMaterialIgnored, repairKind: .promptSkill)

        let triaged = FailureSkillTriageService().triage(candidate)
        let evaluation = SkillifyChecklistEvaluator().evaluate(triaged)

        XCTAssertEqual(triaged.status, .proposed)
        XCTAssertEqual(triaged.repairKind, .promptSkill)
        XCTAssertNil(triaged.proposedSkillPayload)
        XCTAssertEqual(triaged.checklist.resolverTestReference, "SkillMatcherTests.testModeMatchFires")
        XCTAssertTrue(triaged.checklist.smokeTestCommand?.contains("FailureToSkillDetectorTests") == true)
        XCTAssertFalse(evaluation.canActivate)
        XCTAssertTrue(evaluation.missingItems.contains(.proposedSkillPayload))
    }

    func testJudgeFeedbackPromptCandidateCanDraftActivatablePayload() {
        let candidate = makeCandidate(signature: .judgeFeedbackTooForceful, repairKind: .promptSkill)

        let triaged = FailureSkillTriageService().triage(candidate)
        let evaluation = SkillifyChecklistEvaluator().evaluate(triaged)

        XCTAssertEqual(triaged.proposedSkillPayload?.name, "judge-feedback-too-forceful")
        XCTAssertEqual(triaged.proposedSkillPayload?.payloadVersion, 1)
        XCTAssertEqual(triaged.proposedSkillPayload?.trigger.kind, .always)
        XCTAssertEqual(triaged.proposedSkillPayload?.trigger.modes, [])
        XCTAssertTrue(evaluation.canActivate)
    }

    func testDeterministicFixCandidateGetsCodeChecklistButNoPromptSkillPayload() {
        let candidate = makeCandidate(signature: .judgeFeedbackWrongMemory, repairKind: .deterministicFix)

        let triaged = FailureSkillTriageService().triage(candidate)
        let evaluation = SkillifyChecklistEvaluator().evaluate(triaged)

        XCTAssertEqual(triaged.repairKind, .deterministicFix)
        XCTAssertNil(triaged.proposedSkillPayload)
        XCTAssertEqual(triaged.checklist.codeReference, "Judge feedback wrong-memory path requires a deterministic fix or regression-only patch.")
        XCTAssertEqual(evaluation.blockingReason, .deterministicFixCannotActivateSkill)
    }

    func testDismissedAndActivatedCandidatesAreNotAutoRewritten() {
        var dismissed = makeCandidate(signature: .borrowedAuthorityLeakage, repairKind: .promptSkill)
        dismissed.status = .dismissed
        var activated = makeCandidate(signature: .ownCorpusIgnored, repairKind: .promptSkill)
        activated.status = .activated
        activated.activatedSkillId = UUID()

        XCTAssertEqual(FailureSkillTriageService().triage(dismissed), dismissed)
        XCTAssertEqual(FailureSkillTriageService().triage(activated), activated)
    }

    func testPatternsGroupRecurringCandidatesBySignatureAndRepairKind() {
        let candidates = [
            makeCandidate(signature: .sourceMaterialIgnored, repairKind: .promptSkill, sourceId: "a"),
            makeCandidate(signature: .sourceMaterialIgnored, repairKind: .promptSkill, sourceId: "b"),
            makeCandidate(signature: .borrowedAuthorityLeakage, repairKind: .promptSkill, sourceId: "c")
        ].map { FailureSkillTriageService().triage($0) }

        let patterns = FailureSkillTriageService().patterns(from: candidates)

        XCTAssertEqual(patterns.count, 2)
        XCTAssertEqual(patterns.first?.signature, .sourceMaterialIgnored)
        XCTAssertEqual(patterns.first?.candidateCount, 2)
        XCTAssertTrue(patterns.first?.isRecurring == true)
        XCTAssertEqual(patterns.first?.readyCount, 0)
    }

    func testPatternsIgnoreRecurringPatternRollupCandidates() {
        let candidates = [
            makeCandidate(signature: .sourceMaterialIgnored, repairKind: .promptSkill, sourceId: "a"),
            makeCandidate(signature: .sourceMaterialIgnored, repairKind: .promptSkill, sourceId: "b"),
            makeCandidate(
                signature: .sourceMaterialIgnored,
                repairKind: .promptSkill,
                sourceKind: .recurringPattern,
                sourceId: "sourceMaterialIgnored:promptSkill"
            )
        ].map { FailureSkillTriageService().triage($0) }

        let pattern = FailureSkillTriageService().patterns(from: candidates).first

        XCTAssertEqual(pattern?.candidateCount, 2)
        XCTAssertEqual(pattern?.readyCount, 0)
    }

    private func makeCandidate(
        signature: FailureSignature,
        repairKind: FailureRepairKind,
        sourceKind: FailureSkillSourceKind = .contextManifest,
        sourceId: String = "source-1"
    ) -> FailureSkillCandidate {
        FailureSkillCandidate(
            id: UUID(),
            userId: "alex",
            sourceKind: sourceKind,
            sourceId: sourceId,
            turnId: UUID(),
            conversationId: UUID(),
            assistantMessageId: UUID(),
            signature: signature,
            repairKind: repairKind,
            status: .proposed,
            evidence: [FailureSkillEvidence(source: .telemetry, id: sourceId)],
            proposedSkillPayload: nil,
            checklist: SkillifyChecklist(rootCause: signature.displayName),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            activatedSkillId: nil
        )
    }
}
