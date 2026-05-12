import XCTest
@testable import Nous

final class FailureSkillCandidateStoreTriageTests: XCTestCase {
    func testUpsertAutoTriagePersistsDraftPayloadAndChecklist() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = FailureSkillCandidateStore(nodeStore: nodeStore)
        let candidate = makeCandidate()

        try store.upsertCandidate(candidate)

        let fetched = try XCTUnwrap(store.fetchCandidate(id: candidate.id))
        XCTAssertNil(fetched.proposedSkillPayload)
        XCTAssertEqual(fetched.checklist.resolverTestReference, "SkillMatcherTests.testModeMatchFires")
        XCTAssertFalse(SkillifyChecklistEvaluator().evaluate(fetched).canActivate)
    }

    func testRunAutoTriageBackfillsExistingCandidates() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = FailureSkillCandidateStore(nodeStore: nodeStore)
        var candidate = makeCandidate()
        candidate.status = .approved
        try store.insertCandidateWithoutAutoTriageForTests(candidate)

        let updatedCount = try store.runAutoTriage(userId: "alex", limit: 20)

        let fetched = try XCTUnwrap(store.fetchCandidate(id: candidate.id))
        XCTAssertEqual(updatedCount, 1)
        XCTAssertEqual(fetched.status, .approved)
        XCTAssertNil(fetched.proposedSkillPayload)
        XCTAssertFalse(SkillifyChecklistEvaluator().evaluate(fetched).canActivate)
    }

    private func makeCandidate() -> FailureSkillCandidate {
        FailureSkillCandidate(
            id: UUID(),
            userId: "alex",
            sourceKind: .corpusFidelity,
            sourceId: "fidelity-1",
            turnId: UUID(),
            conversationId: UUID(),
            assistantMessageId: UUID(),
            signature: .ownCorpusIgnored,
            repairKind: .promptSkill,
            status: .proposed,
            evidence: [FailureSkillEvidence(source: .telemetry, id: "available:2")],
            proposedSkillPayload: nil,
            checklist: SkillifyChecklist(rootCause: "Own corpus was ignored."),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            activatedSkillId: nil
        )
    }
}
