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

    func testStatusTransitionsPersist() throws {
        var candidate = makeCandidate()
        try store.upsertCandidate(candidate)

        candidate.status = .dismissed
        candidate.updatedAt = Date(timeIntervalSince1970: 40)
        try store.updateCandidate(candidate)

        XCTAssertEqual(try store.fetchCandidate(id: candidate.id)?.status, .dismissed)
        XCTAssertEqual(try store.fetchCandidate(id: candidate.id)?.updatedAt, Date(timeIntervalSince1970: 40))
    }

    func testInvalidJSONRowIsSkipped() throws {
        let candidate = makeCandidate()
        try store.upsertCandidate(candidate)
        let stmt = try nodeStore.rawDatabase.prepare("""
            UPDATE failure_skill_candidates
            SET evidence_json = '{'
            WHERE id = ?;
        """)
        try stmt.bind(candidate.id.uuidString, at: 1)
        try stmt.step()

        XCTAssertNil(try store.fetchCandidate(id: candidate.id))
        XCTAssertEqual(try store.fetchRecentCandidates(userId: "alex", limit: 10), [])
    }

    private func makeCandidate(
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        sourceId: String = "source-1",
        updatedAt: Date = Date(timeIntervalSince1970: 2),
        evidence: [FailureSkillEvidence] = [FailureSkillEvidence(source: .telemetry, id: "memory-a", snippet: "bounded")]
    ) -> FailureSkillCandidate {
        FailureSkillCandidate(
            id: id,
            userId: "alex",
            sourceKind: .corpusFidelity,
            sourceId: sourceId,
            turnId: UUID(uuidString: "00000000-0000-0000-0000-000000000011"),
            conversationId: UUID(uuidString: "00000000-0000-0000-0000-000000000012"),
            assistantMessageId: UUID(uuidString: "00000000-0000-0000-0000-000000000013"),
            signature: .ownCorpusIgnored,
            repairKind: .promptSkill,
            status: .proposed,
            evidence: evidence,
            proposedSkillPayload: SkillPayload(
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
            checklist: SkillifyChecklist(
                rootCause: "Own corpus was available but ignored.",
                trigger: "own corpus available",
                useWhen: "Use when Alex corpus cards are available.",
                antiPatternExample: "Borrowed authority first.",
                regressionTestReference: "FailureToSkillDetectorTests.testCorpusIgnoredCreatesPromptSkillCandidate",
                resolverTestReference: "SkillMatcherTests.testModeMatchFires",
                smokeTestCommand: "xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/FailureToSkillDetectorTests"
            ),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: updatedAt,
            activatedSkillId: nil
        )
    }
}
