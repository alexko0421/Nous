import XCTest
@testable import Nous

final class SkillifyChecklistEvaluatorTests: XCTestCase {

    func testBlocksIncompleteCandidate() {
        let candidate = makeCandidate(checklist: SkillifyChecklist(rootCause: "Too vague."))

        let result = SkillifyChecklistEvaluator().evaluate(candidate)

        XCTAssertFalse(result.canActivate)
        XCTAssertTrue(result.missingItems.contains(.trigger))
        XCTAssertTrue(result.missingItems.contains(.regressionTestReference))
        XCTAssertLessThan(result.completedCount, result.requiredCount)
    }

    func testPassesCompletePromptSkillCandidate() {
        let candidate = makeCandidate()

        let result = SkillifyChecklistEvaluator().evaluate(candidate)

        XCTAssertTrue(result.canActivate)
        XCTAssertEqual(result.missingItems, [])
        XCTAssertEqual(result.completedCount, result.requiredCount)
    }

    func testBlocksDeterministicFixActivationEvenWhenChecklistIsComplete() {
        var candidate = makeCandidate(
            repairKind: .deterministicFix,
            checklist: completeChecklist(codeReference: "Sources/Nous/Services/VectorStore.swift")
        )
        candidate.proposedSkillPayload = nil

        let result = SkillifyChecklistEvaluator().evaluate(candidate)

        XCTAssertFalse(result.canActivate)
        XCTAssertEqual(result.blockingReason, .deterministicFixCannotActivateSkill)
        XCTAssertEqual(result.missingItems, [])
    }

    func testRejectsInvalidSkillPayload() {
        let payload = SkillPayload(
            payloadVersion: 2,
            name: "invalid-empty-cues",
            description: nil,
            useWhen: "Use when analysis is requested.",
            source: .alex,
            trigger: SkillTrigger(kind: .analysisGate, modes: [], priority: 50, cues: []),
            action: SkillAction(kind: .promptFragment, content: "Surface the tension."),
            rationale: nil,
            antiPatternExamples: ["Silent yes-man reply."]
        )
        let candidate = makeCandidate(payload: payload)

        let result = SkillifyChecklistEvaluator().evaluate(candidate)

        XCTAssertFalse(result.canActivate)
        XCTAssertEqual(result.blockingReason, .invalidSkillPayload)
    }

    private func makeCandidate(
        repairKind: FailureRepairKind = .promptSkill,
        payload: SkillPayload? = validPayload(),
        checklist: SkillifyChecklist = completeChecklist()
    ) -> FailureSkillCandidate {
        FailureSkillCandidate(
            id: UUID(),
            userId: "alex",
            sourceKind: .corpusFidelity,
            sourceId: "source-1",
            turnId: UUID(),
            conversationId: UUID(),
            assistantMessageId: UUID(),
            signature: .ownCorpusIgnored,
            repairKind: repairKind,
            status: .approved,
            evidence: [FailureSkillEvidence(source: .telemetry, id: "memory-a")],
            proposedSkillPayload: payload,
            checklist: checklist,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            activatedSkillId: nil
        )
    }

    private static func validPayload() -> SkillPayload {
        SkillPayload(
            payloadVersion: 2,
            name: "own-corpus-before-borrowed-authority",
            description: "Prefer Alex corpus before borrowed authority.",
            useWhen: "Use when Alex corpus cards are available.",
            source: .alex,
            trigger: SkillTrigger(kind: .always, modes: [.direction], priority: 50),
            action: SkillAction(kind: .promptFragment, content: "Use Alex corpus before outside frameworks."),
            rationale: "Prevents borrowed authority leakage.",
            antiPatternExamples: ["Opening with Kahneman when Alex corpus is available."]
        )
    }

    private static func completeChecklist(codeReference: String? = nil) -> SkillifyChecklist {
        SkillifyChecklist(
            rootCause: "The reply ignored available own-corpus evidence.",
            trigger: "own corpus available",
            useWhen: "Use when Alex corpus cards are available.",
            antiPatternExample: "Borrowed authority first.",
            regressionTestReference: "FailureToSkillDetectorTests.testCorpusIgnoredCreatesPromptSkillCandidate",
            resolverTestReference: "SkillMatcherTests.testModeMatchFires",
            smokeTestCommand: "xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS'",
            codeReference: codeReference
        )
    }
}
