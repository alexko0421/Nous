import XCTest
@testable import Nous

final class ReflectionValidatorDistinctConversationTests: XCTestCase {

    func test_rejectsClaimWithEvidenceFromOnlyOneConversation() throws {
        let nodeA = UUID()
        let m1 = UUID().uuidString
        let m2 = UUID().uuidString
        let messageIdToNodeId: [String: UUID] = [m1: nodeA, m2: nodeA]

        let json = """
        {"claims": [
          {
            "claim": "Alex returns to fear of being seen as inadequate",
            "confidence": 0.8,
            "supporting_turn_ids": ["\(m1)", "\(m2)"],
            "why_non_obvious": "Because surface topics differ"
          }
        ]}
        """

        let result = try ReflectionValidator.validate(
            rawJSON: json,
            validMessageIds: [m1, m2],
            messageIdToNodeId: messageIdToNodeId,
            runId: UUID()
        )
        XCTAssertEqual(result.claims.count, 0)
        XCTAssertEqual(result.rejectionReason, .singleConversationEvidence)
    }

    func test_acceptsClaimWithEvidenceFromTwoDistinctConversations() throws {
        let nodeA = UUID()
        let nodeB = UUID()
        let m1 = UUID().uuidString
        let m2 = UUID().uuidString
        let messageIdToNodeId: [String: UUID] = [m1: nodeA, m2: nodeB]

        let json = """
        {"claims": [
          {
            "claim": "Alex circles around dad's expectations across launches",
            "confidence": 0.85,
            "supporting_turn_ids": ["\(m1)", "\(m2)"],
            "why_non_obvious": "Twinned at the deeper motif"
          }
        ]}
        """

        let result = try ReflectionValidator.validate(
            rawJSON: json,
            validMessageIds: [m1, m2],
            messageIdToNodeId: messageIdToNodeId,
            runId: UUID()
        )
        XCTAssertEqual(result.claims.count, 1)
        XCTAssertNil(result.rejectionReason)
    }

    func test_rejectsClaimWithThreeMessagesAllSameConversation() throws {
        let nodeA = UUID()
        let m1 = UUID().uuidString
        let m2 = UUID().uuidString
        let m3 = UUID().uuidString
        let messageIdToNodeId: [String: UUID] = [m1: nodeA, m2: nodeA, m3: nodeA]

        let json = """
        {"claims": [
          {
            "claim": "test claim",
            "confidence": 0.9,
            "supporting_turn_ids": ["\(m1)", "\(m2)", "\(m3)"],
            "why_non_obvious": "test"
          }
        ]}
        """

        let result = try ReflectionValidator.validate(
            rawJSON: json,
            validMessageIds: [m1, m2, m3],
            messageIdToNodeId: messageIdToNodeId,
            runId: UUID()
        )
        XCTAssertEqual(result.claims.count, 0)
        XCTAssertEqual(result.rejectionReason, .singleConversationEvidence)
    }

    func test_emptyMessageIdToNodeIdMapResultsInRejection() throws {
        let m1 = UUID().uuidString
        let m2 = UUID().uuidString
        let json = """
        {"claims": [
          {"claim": "x", "confidence": 0.9, "supporting_turn_ids": ["\(m1)", "\(m2)"], "why_non_obvious": "x"}
        ]}
        """

        let result = try ReflectionValidator.validate(
            rawJSON: json,
            validMessageIds: [m1, m2],
            messageIdToNodeId: [:],  // resolver returned nothing
            runId: UUID()
        )
        XCTAssertEqual(result.claims.count, 0)
        // Treated as singleConversationEvidence (Set count = 0, < 2).
        XCTAssertEqual(result.rejectionReason, .singleConversationEvidence)
    }
}
