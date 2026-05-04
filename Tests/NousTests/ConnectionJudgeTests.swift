import XCTest
@testable import Nous

final class ConnectionJudgeTests: XCTestCase {
    func testRejectsMissingVerdict() {
        let judge = ConnectionJudge()

        let assessment = judge.assess(
            source: NousNode(type: .note, title: "A"),
            target: NousNode(type: .note, title: "B"),
            similarity: 0.91,
            verdict: nil
        )

        XCTAssertEqual(assessment.role, .connectionJudge)
        XCTAssertEqual(assessment.decision, .reject)
        XCTAssertNil(assessment.verdict)
    }

    func testRejectsSelfConnection() {
        let judge = ConnectionJudge()
        let node = NousNode(type: .note, title: "Same")
        let verdict = GalaxyRelationVerdict(
            relationKind: .topicSimilarity,
            confidence: 0.9,
            explanation: "same topic",
            sourceEvidence: "same",
            targetEvidence: "same"
        )

        let assessment = judge.assess(
            source: node,
            target: node,
            similarity: 0.9,
            verdict: verdict
        )

        XCTAssertEqual(assessment.decision, .reject)
    }

    func testAcceptsAtomBackedRelation() {
        let judge = ConnectionJudge()
        let sourceAtomId = UUID()
        let targetAtomId = UUID()
        let verdict = GalaxyRelationVerdict(
            relationKind: .supports,
            confidence: 0.82,
            explanation: "A reason supports a decision.",
            sourceEvidence: "Alex chose raw SQLite for ownership.",
            targetEvidence: "The data layer decision requires explicit control.",
            sourceAtomId: sourceAtomId,
            targetAtomId: targetAtomId
        )

        let assessment = judge.assess(
            source: NousNode(type: .note, title: "Reason"),
            target: NousNode(type: .note, title: "Decision"),
            similarity: 0.3,
            verdict: verdict
        )

        XCTAssertEqual(assessment.decision, .accept)
        XCTAssertEqual(assessment.verdict, verdict)
    }

    func testDefersGenericHighSimilarityTopicRelation() {
        let judge = ConnectionJudge()
        let verdict = GalaxyRelationVerdict(
            relationKind: .topicSimilarity,
            confidence: 0.96,
            explanation: "这只是语义相似，不是强结论；需要更多证据才能判断真正关系。",
            sourceEvidence: "Alex plans to buy shoes tomorrow.",
            targetEvidence: "Alex bought something before."
        )

        let assessment = judge.assess(
            source: NousNode(type: .conversation, title: "Shoes"),
            target: NousNode(type: .note, title: "Shopping"),
            similarity: 0.96,
            verdict: verdict
        )

        XCTAssertEqual(assessment.decision, .deferred)
    }
}
