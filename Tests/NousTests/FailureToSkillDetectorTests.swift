import XCTest
@testable import Nous

final class FailureToSkillDetectorTests: XCTestCase {

    func testCorpusIgnoredCreatesPromptSkillCandidate() {
        let turnId = UUID()
        let conversationId = UUID()
        let assistantMessageId = UUID()
        let record = CorpusFidelityRecord(
            turnId: turnId,
            conversationId: conversationId,
            assistantMessageId: assistantMessageId,
            signal: CorpusFidelitySignal(
                borrowedAuthorityHits: [],
                ownCorpusCitedIds: [],
                ownCorpusCitationRate: 0,
                ownCorpusAvailableCount: 2
            ),
            recordedAt: Date(timeIntervalSince1970: 10)
        )

        let candidates = FailureToSkillDetector().candidates(
            corpusFidelity: record,
            contextManifest: nil
        )

        XCTAssertEqual(candidates.count, 1)
        let candidate = candidates[0]
        XCTAssertEqual(candidate.sourceKind, .corpusFidelity)
        XCTAssertEqual(candidate.sourceId, record.id.uuidString)
        XCTAssertEqual(candidate.turnId, turnId)
        XCTAssertEqual(candidate.conversationId, conversationId)
        XCTAssertEqual(candidate.assistantMessageId, assistantMessageId)
        XCTAssertEqual(candidate.signature, .ownCorpusIgnored)
        XCTAssertEqual(candidate.repairKind, .promptSkill)
        XCTAssertEqual(candidate.status, .proposed)
        XCTAssertNil(candidate.proposedSkillPayload)
        XCTAssertEqual(candidate.evidence.map(\.id), ["available:2", "cited:0"])
    }

    func testBorrowedAuthorityLeakageCreatesPromptSkillCandidate() {
        let record = CorpusFidelityRecord(
            turnId: UUID(),
            conversationId: UUID(),
            assistantMessageId: UUID(),
            signal: CorpusFidelitySignal(
                borrowedAuthorityHits: ["Kahneman", "Munger"],
                ownCorpusCitedIds: ["memory-a"],
                ownCorpusCitationRate: 0.5,
                ownCorpusAvailableCount: 2
            )
        )

        let candidates = FailureToSkillDetector().candidates(
            corpusFidelity: record,
            contextManifest: nil
        )

        XCTAssertEqual(candidates.map(\.signature), [.borrowedAuthorityLeakage])
        XCTAssertEqual(candidates[0].evidence.map(\.id), ["Kahneman", "Munger"])
    }

    func testSourceMaterialIgnoredCreatesPromptSkillCandidate() {
        let turnId = UUID()
        let conversationId = UUID()
        let assistantMessageId = UUID()
        let sourceNodeId = UUID()
        let record = ContextManifestRecord(
            turnId: turnId,
            conversationId: conversationId,
            assistantMessageId: assistantMessageId,
            resources: [
                ContextManifestResource(
                    source: .sourceMaterial,
                    label: "source_material",
                    referenceId: sourceNodeId.uuidString,
                    state: .loaded,
                    used: false
                )
            ],
            recordedAt: Date(timeIntervalSince1970: 20)
        )

        let candidates = FailureToSkillDetector().candidates(
            corpusFidelity: nil,
            contextManifest: record
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].sourceKind, .contextManifest)
        XCTAssertEqual(candidates[0].sourceId, record.id.uuidString)
        XCTAssertEqual(candidates[0].signature, .sourceMaterialIgnored)
        XCTAssertEqual(candidates[0].evidence.map(\.id), [sourceNodeId.uuidString])
    }

    func testPartialSourceMaterialUseDoesNotCreateIgnoredCandidate() {
        let usedSourceId = UUID()
        let unusedSourceId = UUID()
        let record = ContextManifestRecord(
            turnId: UUID(),
            conversationId: UUID(),
            assistantMessageId: UUID(),
            resources: [
                ContextManifestResource(
                    source: .sourceMaterial,
                    label: "source_material",
                    referenceId: usedSourceId.uuidString,
                    state: .loaded,
                    used: true
                ),
                ContextManifestResource(
                    source: .sourceMaterial,
                    label: "source_material",
                    referenceId: unusedSourceId.uuidString,
                    state: .loaded,
                    used: false
                )
            ]
        )

        let candidates = FailureToSkillDetector().candidates(
            corpusFidelity: nil,
            contextManifest: record
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testHealthySignalsCreateNoCandidate() {
        let fidelity = CorpusFidelityRecord(
            turnId: UUID(),
            conversationId: UUID(),
            assistantMessageId: UUID(),
            signal: CorpusFidelitySignal(
                borrowedAuthorityHits: [],
                ownCorpusCitedIds: ["memory-a"],
                ownCorpusCitationRate: 1,
                ownCorpusAvailableCount: 1
            )
        )
        let manifest = ContextManifestRecord(
            turnId: UUID(),
            conversationId: UUID(),
            assistantMessageId: UUID(),
            resources: [
                ContextManifestResource(
                    source: .sourceMaterial,
                    label: "source_material",
                    referenceId: UUID().uuidString,
                    state: .loaded,
                    used: true
                )
            ]
        )

        let candidates = FailureToSkillDetector().candidates(
            corpusFidelity: fidelity,
            contextManifest: manifest
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testDuplicateSignalsCollapseToOneCandidatePerSignature() {
        let sourceNodeId = UUID()
        let record = ContextManifestRecord(
            turnId: UUID(),
            conversationId: UUID(),
            assistantMessageId: UUID(),
            resources: [
                ContextManifestResource(
                    source: .sourceMaterial,
                    label: "source_material",
                    referenceId: sourceNodeId.uuidString,
                    state: .loaded,
                    used: false
                ),
                ContextManifestResource(
                    source: .sourceMaterial,
                    label: "source_material",
                    referenceId: sourceNodeId.uuidString,
                    state: .loaded,
                    used: false
                )
            ]
        )

        let candidates = FailureToSkillDetector().candidates(
            corpusFidelity: nil,
            contextManifest: record
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].evidence.count, 1)
    }

    func testFeedbackNoteCanOverridePromptSkillToRegressionOnly() {
        var event = JudgeEvent(
            id: UUID(),
            ts: Date(timeIntervalSince1970: 1),
            nodeId: UUID(),
            messageId: UUID(),
            chatMode: .strategist,
            provider: .claude,
            verdictJSON: "{}",
            fallbackReason: .ok,
            userFeedback: .down,
            feedbackTs: Date(timeIntervalSince1970: 1),
            feedbackReason: .notUseful,
            feedbackNote: "This should be regression only, not a new prompt skill."
        )

        let candidate = FailureToSkillDetector().candidate(from: event)

        XCTAssertEqual(candidate?.signature, .judgeFeedbackNotUseful)
        XCTAssertEqual(candidate?.repairKind, .regressionOnly)
        XCTAssertNil(candidate?.proposedSkillPayload)

        event.feedbackNote = "This is deterministic, patch code instead."
        XCTAssertEqual(FailureToSkillDetector().candidate(from: event)?.repairKind, .deterministicFix)
    }
}
