import XCTest
@testable import Nous

final class FailureSkillAutoActivationPolicyTests: XCTestCase {
    func testAllowsCompleteApprovedLowRiskJudgeFeedbackPromptSkill() throws {
        let candidate = Self.makeCandidate(signature: .judgeFeedbackTooForceful)

        XCTAssertTrue(FailureSkillAutoActivationPolicy(isEnabled: true).canAutoActivate(candidate: candidate, latestRun: nil))
    }

    func testBlocksSourceCorpusAndWrongMemorySignatures() throws {
        let policy = FailureSkillAutoActivationPolicy(isEnabled: true)

        XCTAssertFalse(policy.canAutoActivate(candidate: Self.makeCandidate(signature: .ownCorpusIgnored), latestRun: nil))
        XCTAssertFalse(policy.canAutoActivate(candidate: Self.makeCandidate(signature: .borrowedAuthorityLeakage), latestRun: nil))
        XCTAssertFalse(policy.canAutoActivate(candidate: Self.makeCandidate(signature: .sourceMaterialIgnored), latestRun: nil))
        XCTAssertFalse(policy.canAutoActivate(candidate: Self.makeCandidate(signature: .judgeFeedbackWrongMemory), latestRun: nil))
    }

    func testBlocksNonJudgeFeedbackSourceKindEvenWithPostureSignature() throws {
        let policy = FailureSkillAutoActivationPolicy(isEnabled: true)

        XCTAssertFalse(policy.canAutoActivate(
            candidate: Self.makeCandidate(signature: .judgeFeedbackTooForceful, sourceKind: .corpusFidelity),
            latestRun: nil
        ))
        XCTAssertFalse(policy.canAutoActivate(
            candidate: Self.makeCandidate(signature: .judgeFeedbackTooForceful, sourceKind: .recurringPattern),
            latestRun: nil
        ))
    }

    func testBlocksDisabledSettingRepairKindsInvalidPayloadAndActiveRun() throws {
        var candidate = Self.makeCandidate(signature: .judgeFeedbackNotUseful)
        XCTAssertFalse(FailureSkillAutoActivationPolicy(isEnabled: false).canAutoActivate(candidate: candidate, latestRun: nil))

        candidate.repairKind = .deterministicFix
        XCTAssertFalse(FailureSkillAutoActivationPolicy(isEnabled: true).canAutoActivate(candidate: candidate, latestRun: nil))

        candidate = Self.makeCandidate(signature: .judgeFeedbackNotUseful)
        candidate.proposedSkillPayload = nil
        XCTAssertFalse(FailureSkillAutoActivationPolicy(isEnabled: true).canAutoActivate(candidate: candidate, latestRun: nil))

        let activeRun = FailureSkillRepairRun(
            id: UUID(),
            candidateId: candidate.id,
            status: .running,
            beadId: nil,
            branchName: "codex/failure-repair-test",
            commitSHA: nil,
            prURL: nil,
            logExcerpt: nil,
            error: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        XCTAssertFalse(FailureSkillAutoActivationPolicy(isEnabled: true).canAutoActivate(candidate: Self.makeCandidate(signature: .judgeFeedbackNotUseful), latestRun: activeRun))
    }

    private static func makeCandidate(
        signature: FailureSignature,
        sourceKind: FailureSkillSourceKind = .judgeFeedback
    ) -> FailureSkillCandidate {
        FailureSkillCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000B111")!,
            userId: "alex",
            sourceKind: sourceKind,
            sourceId: "judge-1",
            turnId: nil,
            conversationId: nil,
            assistantMessageId: nil,
            signature: signature,
            repairKind: .promptSkill,
            status: .approved,
            evidence: [FailureSkillEvidence(source: .userFeedback, id: "judge-1", snippet: "too forceful")],
            proposedSkillPayload: SkillPayload(
                payloadVersion: 1,
                name: "judge-feedback-auto-activation-test",
                description: "Use when judge feedback says the challenge posture should be softened.",
                useWhen: "Use when judge feedback says the challenge posture should be softened.",
                source: .alex,
                trigger: SkillTrigger(kind: .always, modes: [], priority: 45),
                action: SkillAction(kind: .promptFragment, content: "Adjust the next challenge to be lighter, more specific, and easier to decline."),
                rationale: "Alex explicitly marked the judge intervention as unhelpfully forceful.",
                antiPatternExamples: ["Escalating a small concern into a hard verdict."]
            ),
            checklist: SkillifyChecklist(
                rootCause: "Alex marked the judge intervention as too forceful.",
                trigger: "thumbs-down judge feedback with posture reason",
                useWhen: "Use when judge feedback says the challenge posture should be softened.",
                antiPatternExample: "Escalating a small concern into a hard verdict.",
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
