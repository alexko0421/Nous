import XCTest
@testable import Nous

final class FailureSkillCandidateStoreTests: XCTestCase {

    private var nodeStore: NodeStore!
    private var store: FailureSkillCandidateStore!

    override func setUp() {
        super.setUp()
        nodeStore = try! NodeStore(path: ":memory:")
        store = FailureSkillCandidateStore(nodeStore: nodeStore)
    }

    override func tearDown() {
        store = nil
        nodeStore = nil
        super.tearDown()
    }

    func testCandidateRoundTrip() throws {
        let candidate = makeCandidate()

        try store.upsertCandidate(candidate)

        let fetched = try XCTUnwrap(store.fetchCandidate(id: candidate.id))
        XCTAssertEqual(fetched, candidate)
        XCTAssertEqual(try store.fetchRecentCandidates(userId: "alex", limit: 10), [candidate])
    }

    func testUniquenessGuardUpdatesExistingCandidate() throws {
        let sourceId = UUID().uuidString
        let first = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            sourceId: sourceId,
            updatedAt: Date(timeIntervalSince1970: 10),
            evidence: [FailureSkillEvidence(source: .telemetry, id: "first")]
        )
        var second = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            sourceId: sourceId,
            updatedAt: Date(timeIntervalSince1970: 20),
            evidence: [FailureSkillEvidence(source: .telemetry, id: "second")]
        )
        second.status = .approved

        try store.upsertCandidate(first)
        try store.upsertCandidate(second)

        let fetched = try store.fetchRecentCandidates(userId: "alex", limit: 10)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].id, first.id)
        XCTAssertEqual(fetched[0].status, .approved)
        XCTAssertEqual(fetched[0].evidence.map(\.id), ["second"])
        XCTAssertEqual(fetched[0].updatedAt, Date(timeIntervalSince1970: 20))
    }

    func testDuplicateSignalDoesNotDowngradeApprovedCandidate() throws {
        let sourceId = UUID().uuidString
        var approved = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000121")!,
            sourceId: sourceId,
            updatedAt: Date(timeIntervalSince1970: 10),
            evidence: [FailureSkillEvidence(source: .telemetry, id: "approved")]
        )
        approved.status = .approved
        let duplicate = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000122")!,
            sourceId: sourceId,
            updatedAt: Date(timeIntervalSince1970: 20),
            evidence: [FailureSkillEvidence(source: .telemetry, id: "duplicate")]
        )

        try store.upsertCandidate(approved)
        try store.upsertCandidate(duplicate)

        let fetched = try XCTUnwrap(store.fetchCandidate(id: approved.id))
        XCTAssertEqual(fetched.status, .approved)
        XCTAssertEqual(fetched.evidence.map(\.id), ["duplicate"])
        XCTAssertEqual(fetched.updatedAt, Date(timeIntervalSince1970: 20))
        XCTAssertNil(try store.fetchCandidate(id: duplicate.id))
    }

    func testDuplicateSignalDoesNotClearApprovedActivationDraft() throws {
        let sourceId = UUID().uuidString
        var approved = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
            sourceId: sourceId,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        approved.status = .approved
        var duplicate = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000124")!,
            sourceId: sourceId,
            updatedAt: Date(timeIntervalSince1970: 20),
            evidence: [FailureSkillEvidence(source: .telemetry, id: "duplicate")]
        )
        duplicate.proposedSkillPayload = nil
        duplicate.checklist = SkillifyChecklist(rootCause: "Raw duplicate signal.")

        try store.upsertCandidate(approved)
        try store.upsertCandidate(duplicate)

        let fetched = try XCTUnwrap(store.fetchCandidate(id: approved.id))
        XCTAssertEqual(fetched.status, .approved)
        XCTAssertEqual(fetched.repairKind, approved.repairKind)
        XCTAssertEqual(fetched.proposedSkillPayload, approved.proposedSkillPayload)
        XCTAssertEqual(fetched.checklist, approved.checklist)
        XCTAssertTrue(SkillifyChecklistEvaluator().evaluate(fetched).canActivate)
    }

    func testDuplicateSignalWithDifferentRepairKindReplacesApprovedDraft() throws {
        let sourceId = UUID().uuidString
        var approved = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000125")!,
            sourceId: sourceId,
            signature: .judgeFeedbackTooForceful,
            repairKind: .promptSkill,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        approved.status = .approved
        var duplicate = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000126")!,
            sourceId: sourceId,
            signature: .judgeFeedbackTooForceful,
            repairKind: .regressionOnly,
            updatedAt: Date(timeIntervalSince1970: 20),
            evidence: [FailureSkillEvidence(source: .userFeedback, id: "note", snippet: "regression only")]
        )
        duplicate.proposedSkillPayload = nil
        duplicate.checklist = SkillifyChecklist(rootCause: "Explicit feedback said regression only.")

        try store.upsertCandidate(approved)
        try store.upsertCandidate(duplicate)

        let fetched = try XCTUnwrap(store.fetchCandidate(id: approved.id))
        XCTAssertEqual(fetched.status, .proposed)
        XCTAssertEqual(fetched.repairKind, .regressionOnly)
        XCTAssertNil(fetched.proposedSkillPayload)
        XCTAssertEqual(fetched.evidence.map(\.id), ["note"])
        XCTAssertFalse(SkillifyChecklistEvaluator().evaluate(fetched).canActivate)
        XCTAssertNil(try store.fetchCandidate(id: duplicate.id))
    }

    func testUniquenessGuardDoesNotReopenDismissedCandidate() throws {
        let sourceId = UUID().uuidString
        var dismissed = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
            sourceId: sourceId,
            updatedAt: Date(timeIntervalSince1970: 30),
            evidence: [FailureSkillEvidence(source: .telemetry, id: "dismissed")]
        )
        dismissed.status = .dismissed
        let duplicate = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000404")!,
            sourceId: sourceId,
            updatedAt: Date(timeIntervalSince1970: 40),
            evidence: [FailureSkillEvidence(source: .telemetry, id: "duplicate")]
        )

        try store.upsertCandidate(dismissed)
        try store.upsertCandidate(duplicate)

        let fetched = try XCTUnwrap(store.fetchCandidate(id: dismissed.id))
        XCTAssertEqual(fetched.status, .dismissed)
        XCTAssertEqual(fetched.evidence.map(\.id), ["dismissed"])
        XCTAssertEqual(fetched.updatedAt, Date(timeIntervalSince1970: 30))
        XCTAssertNil(try store.fetchCandidate(id: duplicate.id))
    }

    func testUniquenessGuardDoesNotReopenActivatedCandidate() throws {
        let sourceId = UUID().uuidString
        let activatedSkillId = UUID(uuidString: "00000000-0000-0000-0000-000000000505")!
        var activated = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000606")!,
            sourceId: sourceId,
            updatedAt: Date(timeIntervalSince1970: 50),
            evidence: [FailureSkillEvidence(source: .telemetry, id: "activated")]
        )
        activated.status = .activated
        activated.activatedSkillId = activatedSkillId
        let duplicate = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000707")!,
            sourceId: sourceId,
            updatedAt: Date(timeIntervalSince1970: 60),
            evidence: [FailureSkillEvidence(source: .telemetry, id: "duplicate")]
        )

        try store.upsertCandidate(activated)
        try store.upsertCandidate(duplicate)

        let fetched = try XCTUnwrap(store.fetchCandidate(id: activated.id))
        XCTAssertEqual(fetched.status, .activated)
        XCTAssertEqual(fetched.activatedSkillId, activatedSkillId)
        XCTAssertEqual(fetched.evidence.map(\.id), ["activated"])
        XCTAssertEqual(fetched.updatedAt, Date(timeIntervalSince1970: 50))
        XCTAssertNil(try store.fetchCandidate(id: duplicate.id))
    }

    func testStatusTransitionsPersist() throws {
        var candidate = makeCandidate()
        try store.upsertCandidate(candidate)

        candidate.status = .dismissed
        candidate.updatedAt = Date(timeIntervalSince1970: 40)
        try store.updateCandidate(candidate)

        XCTAssertEqual(try store.fetchCandidate(id: candidate.id)?.status, .dismissed)
        XCTAssertEqual(try store.fetchCandidate(id: candidate.id)?.updatedAt, Date(timeIntervalSince1970: 40))
    }

    func testInvalidJSONRowIsRejected() throws {
        let candidate = makeCandidate()
        try store.upsertCandidate(candidate)
        let stmt = try nodeStore.rawDatabase.prepare("""
            UPDATE failure_skill_candidates
            SET evidence_json = '{'
            WHERE id = ?;
        """)
        try stmt.bind(candidate.id.uuidString, at: 1)
        XCTAssertThrowsError(try stmt.step())

        XCTAssertEqual(try store.fetchCandidate(id: candidate.id), candidate)
        XCTAssertEqual(try store.fetchRecentCandidates(userId: "alex", limit: 10), [candidate])
    }

    func testRecurringPatternPromotionCreatesOnePatternCandidateAfterThreshold() throws {
        let first = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000801")!,
            sourceId: "source-a",
            updatedAt: Date(timeIntervalSince1970: 10),
            evidence: [FailureSkillEvidence(source: .telemetry, id: "first")]
        )
        let second = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000802")!,
            sourceId: "source-b",
            updatedAt: Date(timeIntervalSince1970: 20),
            evidence: [FailureSkillEvidence(source: .telemetry, id: "second")]
        )

        try store.upsertCandidate(first)
        XCTAssertTrue(try store.fetchRecentCandidates(userId: "alex", limit: 10).allSatisfy {
            $0.sourceKind != .recurringPattern
        })

        try store.upsertCandidate(second)

        let candidates = try store.fetchRecentCandidates(userId: "alex", limit: 10)
        let pattern = try XCTUnwrap(candidates.first(where: { $0.sourceKind == .recurringPattern }))
        XCTAssertEqual(pattern.sourceId, "ownCorpusIgnored:promptSkill")
        XCTAssertEqual(pattern.signature, .ownCorpusIgnored)
        XCTAssertEqual(pattern.repairKind, .promptSkill)
        XCTAssertEqual(pattern.status, .proposed)
        XCTAssertEqual(pattern.evidence.map(\.source), [.failureSkillCandidate, .failureSkillCandidate])
        XCTAssertEqual(Set(pattern.evidence.map(\.id)), Set([first.id.uuidString, second.id.uuidString]))
        XCTAssertNil(pattern.proposedSkillPayload)
        XCTAssertFalse(SkillifyChecklistEvaluator().evaluate(pattern).canActivate)

        let promotedAgain = try store.runRecurringPatternPromotion(
            userId: "alex",
            limit: 10,
            threshold: 2,
            now: Date(timeIntervalSince1970: 30)
        )
        let afterSecondPromotion = try store.fetchRecentCandidates(userId: "alex", limit: 10)
        XCTAssertEqual(promotedAgain, 1)
        XCTAssertEqual(afterSecondPromotion.filter { $0.sourceKind == .recurringPattern }.count, 1)
    }

    func testRecurringPatternPromotionDoesNotReopenDismissedPatternCandidate() throws {
        let first = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!,
            sourceId: "source-a",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let second = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000902")!,
            sourceId: "source-b",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        try store.upsertCandidate(first)
        try store.upsertCandidate(second)

        let pattern = try XCTUnwrap((try store.fetchRecentCandidates(userId: "alex", limit: 10)).first(where: {
            $0.sourceKind == .recurringPattern
        }))
        try store.setStatus(id: pattern.id, status: .dismissed, updatedAt: Date(timeIntervalSince1970: 25))

        let promoted = try store.runRecurringPatternPromotion(
            userId: "alex",
            limit: 10,
            threshold: 2,
            now: Date(timeIntervalSince1970: 30)
        )

        let candidates = try store.fetchRecentCandidates(userId: "alex", limit: 10)
        let patterns = candidates.filter { $0.sourceKind == .recurringPattern }
        XCTAssertEqual(promoted, 0)
        XCTAssertEqual(patterns.count, 1)
        XCTAssertEqual(patterns[0].status, .dismissed)
    }

    func testRecurringPatternPromotionMarksPatternIncompleteWhenSignalsFallBelowThreshold() throws {
        let first = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001001")!,
            sourceKind: .judgeFeedback,
            sourceId: "event-a",
            signature: .judgeFeedbackTooForceful,
            updatedAt: Date(timeIntervalSince1970: 10),
            proposedSkillPayload: nil,
            checklist: SkillifyChecklist(rootCause: "first downvote")
        )
        let second = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001002")!,
            sourceKind: .judgeFeedback,
            sourceId: "event-b",
            signature: .judgeFeedbackTooForceful,
            updatedAt: Date(timeIntervalSince1970: 20),
            proposedSkillPayload: nil,
            checklist: SkillifyChecklist(rootCause: "second downvote")
        )

        try store.upsertCandidate(first)
        try store.upsertCandidate(second)

        var pattern = try XCTUnwrap((try store.fetchRecentCandidates(userId: "alex", limit: 10)).first(where: {
            $0.sourceKind == .recurringPattern
        }))
        XCTAssertTrue(SkillifyChecklistEvaluator().evaluate(pattern).canActivate)

        try store.dismissCandidates(
            sourceKind: .judgeFeedback,
            sourceId: "event-a",
            updatedAt: Date(timeIntervalSince1970: 25)
        )
        _ = try store.runRecurringPatternPromotion(
            userId: "alex",
            limit: 10,
            threshold: 2,
            now: Date(timeIntervalSince1970: 30)
        )

        pattern = try XCTUnwrap((try store.fetchRecentCandidates(userId: "alex", limit: 10)).first(where: {
            $0.sourceKind == .recurringPattern
        }))
        XCTAssertEqual(pattern.status, .proposed)
        XCTAssertEqual(pattern.evidence.map(\.id), [second.id.uuidString])
        XCTAssertNil(pattern.proposedSkillPayload)
        XCTAssertFalse(SkillifyChecklistEvaluator().evaluate(pattern).canActivate)
    }

    func testDismissingSourceSignalRefreshesRecurringPatternImmediately() throws {
        let first = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001101")!,
            sourceKind: .judgeFeedback,
            sourceId: "event-a",
            signature: .judgeFeedbackTooForceful,
            updatedAt: Date(timeIntervalSince1970: 10),
            proposedSkillPayload: nil,
            checklist: SkillifyChecklist(rootCause: "first downvote")
        )
        let second = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001102")!,
            sourceKind: .judgeFeedback,
            sourceId: "event-b",
            signature: .judgeFeedbackTooForceful,
            updatedAt: Date(timeIntervalSince1970: 20),
            proposedSkillPayload: nil,
            checklist: SkillifyChecklist(rootCause: "second downvote")
        )

        try store.upsertCandidate(first)
        try store.upsertCandidate(second)

        var pattern = try XCTUnwrap((try store.fetchRecentCandidates(userId: "alex", limit: 10)).first(where: {
            $0.sourceKind == .recurringPattern
        }))
        XCTAssertTrue(SkillifyChecklistEvaluator().evaluate(pattern).canActivate)

        try store.dismissCandidates(
            sourceKind: .judgeFeedback,
            sourceId: "event-a",
            updatedAt: Date(timeIntervalSince1970: 25)
        )

        pattern = try XCTUnwrap((try store.fetchRecentCandidates(userId: "alex", limit: 10)).first(where: {
            $0.sourceKind == .recurringPattern
        }))
        XCTAssertEqual(pattern.status, .proposed)
        XCTAssertEqual(pattern.evidence.map(\.id), [second.id.uuidString])
        XCTAssertNil(pattern.proposedSkillPayload)
        XCTAssertFalse(SkillifyChecklistEvaluator().evaluate(pattern).canActivate)
    }

    func testAutoTriageDoesNotRedraftIncompleteRecurringPattern() throws {
        let first = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001201")!,
            sourceKind: .judgeFeedback,
            sourceId: "event-a",
            signature: .judgeFeedbackTooForceful,
            updatedAt: Date(timeIntervalSince1970: 10),
            proposedSkillPayload: nil,
            checklist: SkillifyChecklist(rootCause: "first downvote")
        )
        let second = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001202")!,
            sourceKind: .judgeFeedback,
            sourceId: "event-b",
            signature: .judgeFeedbackTooForceful,
            updatedAt: Date(timeIntervalSince1970: 20),
            proposedSkillPayload: nil,
            checklist: SkillifyChecklist(rootCause: "second downvote")
        )

        try store.upsertCandidate(first)
        try store.upsertCandidate(second)
        try store.dismissCandidates(
            sourceKind: .judgeFeedback,
            sourceId: "event-a",
            updatedAt: Date(timeIntervalSince1970: 25)
        )

        _ = try store.runAutoTriage(userId: "alex", limit: 10)

        let pattern = try XCTUnwrap((try store.fetchRecentCandidates(userId: "alex", limit: 10)).first(where: {
            $0.sourceKind == .recurringPattern
        }))
        XCTAssertEqual(pattern.evidence.map(\.id), [second.id.uuidString])
        XCTAssertNil(pattern.proposedSkillPayload)
        XCTAssertFalse(SkillifyChecklistEvaluator().evaluate(pattern).canActivate)
    }

    func testManualStatusDismissRefreshesRecurringPatternImmediately() throws {
        let first = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001301")!,
            sourceKind: .judgeFeedback,
            sourceId: "event-a",
            signature: .judgeFeedbackTooForceful,
            updatedAt: Date(timeIntervalSince1970: 10),
            proposedSkillPayload: nil,
            checklist: SkillifyChecklist(rootCause: "first downvote")
        )
        let second = makeCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001302")!,
            sourceKind: .judgeFeedback,
            sourceId: "event-b",
            signature: .judgeFeedbackTooForceful,
            updatedAt: Date(timeIntervalSince1970: 20),
            proposedSkillPayload: nil,
            checklist: SkillifyChecklist(rootCause: "second downvote")
        )

        try store.upsertCandidate(first)
        try store.upsertCandidate(second)
        try store.setStatus(id: first.id, status: .dismissed, updatedAt: Date(timeIntervalSince1970: 25))

        let pattern = try XCTUnwrap((try store.fetchRecentCandidates(userId: "alex", limit: 10)).first(where: {
            $0.sourceKind == .recurringPattern
        }))
        XCTAssertEqual(pattern.status, .proposed)
        XCTAssertEqual(pattern.evidence.map(\.id), [second.id.uuidString])
        XCTAssertNil(pattern.proposedSkillPayload)
        XCTAssertFalse(SkillifyChecklistEvaluator().evaluate(pattern).canActivate)
    }

    private func makeCandidate(
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        sourceKind: FailureSkillSourceKind = .corpusFidelity,
        sourceId: String = "source-1",
        signature: FailureSignature = .ownCorpusIgnored,
        repairKind: FailureRepairKind = .promptSkill,
        updatedAt: Date = Date(timeIntervalSince1970: 2),
        evidence: [FailureSkillEvidence] = [FailureSkillEvidence(source: .telemetry, id: "memory-a", snippet: "bounded")],
        proposedSkillPayload: SkillPayload? = SkillPayload(
            payloadVersion: 2,
            name: "own-corpus-before-borrowed-authority",
            description: "Prefer Alex corpus when it is available.",
            useWhen: "Use when own corpus cards are available.",
            source: .alex,
            trigger: SkillTrigger(kind: .always, modes: [.direction], priority: 40),
            action: SkillAction(kind: .promptFragment, content: "Use Alex corpus before outside frameworks."),
            rationale: "Prevents borrowed authority leakage.",
            antiPatternExamples: ["Opening with Kahneman when Alex's own notes are available."]
        ),
        checklist: SkillifyChecklist = SkillifyChecklist(
            rootCause: "Own corpus was available but ignored.",
            trigger: "own corpus available",
            useWhen: "Use when Alex corpus cards are available.",
            antiPatternExample: "Borrowed authority first.",
            regressionTestReference: "FailureToSkillDetectorTests.testCorpusIgnoredCreatesPromptSkillCandidate",
            resolverTestReference: "SkillMatcherTests.testModeMatchFires",
            smokeTestCommand: "xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/FailureToSkillDetectorTests/testCorpusIgnoredCreatesPromptSkillCandidate -only-testing:NousTests/SkillMatcherTests/testModeMatchFires -only-testing:NousTests/SkillifyChecklistEvaluatorTests"
        )
    ) -> FailureSkillCandidate {
        FailureSkillCandidate(
            id: id,
            userId: "alex",
            sourceKind: sourceKind,
            sourceId: sourceId,
            turnId: UUID(uuidString: "00000000-0000-0000-0000-000000000011"),
            conversationId: UUID(uuidString: "00000000-0000-0000-0000-000000000012"),
            assistantMessageId: UUID(uuidString: "00000000-0000-0000-0000-000000000013"),
            signature: signature,
            repairKind: repairKind,
            status: .proposed,
            evidence: evidence,
            proposedSkillPayload: proposedSkillPayload,
            checklist: checklist,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: updatedAt,
            activatedSkillId: nil
        )
    }
}
