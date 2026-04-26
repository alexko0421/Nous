import XCTest
@testable import Nous

final class ReflectionValidatorTests: XCTestCase {

    private let runId = UUID()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func validIds(_ ids: String...) -> Set<String> { Set(ids) }

    /// Returns a [messageId: UUID] map where each ID maps to a unique UUID,
    /// so every claim trivially satisfies the distinct-conversation rule.
    private func syntheticNodeMap(_ ids: Set<String>) -> [String: UUID] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, UUID()) })
    }

    // MARK: - Shape errors

    func testMalformedJSONThrowsMalformed() {
        XCTAssertThrowsError(
            try ReflectionValidator.validate(
                rawJSON: "not json at all",
                validMessageIds: [],
                messageIdToNodeId: [:],
                runId: runId,
                now: now
            )
        ) { error in
            guard case ReflectionValidator.ValidationError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    func testMissingClaimsKeyThrowsMalformed() {
        XCTAssertThrowsError(
            try ReflectionValidator.validate(
                rawJSON: #"{"other": []}"#,
                validMessageIds: [],
                messageIdToNodeId: [:],
                runId: runId,
                now: now
            )
        ) { error in
            guard case ReflectionValidator.ValidationError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    // MARK: - Rejection reasons

    func testEmptyClaimsArrayReturnsGenericRejection() throws {
        let out = try ReflectionValidator.validate(
            rawJSON: #"{"claims": []}"#,
            validMessageIds: [],
            messageIdToNodeId: [:],
            runId: runId,
            now: now
        )
        XCTAssertTrue(out.claims.isEmpty)
        XCTAssertEqual(out.rejectionReason, .generic)
    }

    func testAllLowConfidenceReturnsLowConfidence() throws {
        let json = #"""
        {"claims": [
          {"claim": "c1", "confidence": 0.4, "supporting_turn_ids": ["a","b"], "why_non_obvious": "w"},
          {"claim": "c2", "confidence": 0.49, "supporting_turn_ids": ["a","b"], "why_non_obvious": "w"}
        ]}
        """#
        let out = try ReflectionValidator.validate(
            rawJSON: json,
            validMessageIds: validIds("a", "b"),
            messageIdToNodeId: [:],
            runId: runId,
            now: now
        )
        XCTAssertTrue(out.claims.isEmpty)
        XCTAssertEqual(out.rejectionReason, .lowConfidence)
    }

    func testAllUngroundedReturnsUnsupported() throws {
        let json = #"""
        {"claims": [
          {"claim": "c1", "confidence": 0.8, "supporting_turn_ids": ["hallucinated-1"], "why_non_obvious": "w"},
          {"claim": "c2", "confidence": 0.9, "supporting_turn_ids": ["hallucinated-2","hallucinated-3"], "why_non_obvious": "w"}
        ]}
        """#
        let out = try ReflectionValidator.validate(
            rawJSON: json,
            validMessageIds: validIds("a", "b"),
            messageIdToNodeId: [:],
            runId: runId,
            now: now
        )
        XCTAssertTrue(out.claims.isEmpty)
        XCTAssertEqual(out.rejectionReason, .unsupported)
    }

    func testDominantReasonTiebreakPrefersLowConfidence() throws {
        // 1 dropped for low-confidence, 1 dropped for ungrounded. Tie → lowConfidence wins.
        let json = #"""
        {"claims": [
          {"claim": "c1", "confidence": 0.2, "supporting_turn_ids": ["a","b"], "why_non_obvious": "w"},
          {"claim": "c2", "confidence": 0.9, "supporting_turn_ids": ["fake"], "why_non_obvious": "w"}
        ]}
        """#
        let out = try ReflectionValidator.validate(
            rawJSON: json,
            validMessageIds: validIds("a", "b"),
            messageIdToNodeId: [:],
            runId: runId,
            now: now
        )
        XCTAssertTrue(out.claims.isEmpty)
        XCTAssertEqual(out.rejectionReason, .lowConfidence)
    }

    // MARK: - Happy path

    func testHappyPathReturnsTrimmedClampedClaimsNoRejection() throws {
        let json = #"""
        {"claims": [
          {"claim": "  padded claim  ", "confidence": 1.5, "supporting_turn_ids": ["a","b","c"], "why_non_obvious": "  w  "}
        ]}
        """#
        let ids = validIds("a", "b", "c")
        let out = try ReflectionValidator.validate(
            rawJSON: json,
            validMessageIds: ids,
            messageIdToNodeId: syntheticNodeMap(ids),
            runId: runId,
            now: now
        )
        XCTAssertNil(out.rejectionReason)
        XCTAssertEqual(out.claims.count, 1)
        let claim = out.claims[0]
        XCTAssertEqual(claim.claim, "padded claim")
        XCTAssertEqual(claim.whyNonObvious, "w")
        XCTAssertEqual(claim.confidence, 1.0, accuracy: 0.0001)  // clamped
        XCTAssertEqual(claim.runId, runId)
        XCTAssertEqual(claim.createdAt, now)
        XCTAssertEqual(claim.status, .active)
    }

    func testDuplicateSupportingIdsStillMeetMinimumAfterDedup() throws {
        // Two distinct IDs after dedup = passes minGroundedTurns.
        let json = #"""
        {"claims": [
          {"claim": "c", "confidence": 0.8, "supporting_turn_ids": ["a","a","b"], "why_non_obvious": "w"}
        ]}
        """#
        let ids = validIds("a", "b")
        let out = try ReflectionValidator.validate(
            rawJSON: json,
            validMessageIds: ids,
            messageIdToNodeId: syntheticNodeMap(ids),
            runId: runId,
            now: now
        )
        XCTAssertEqual(out.claims.count, 1)
        XCTAssertNil(out.rejectionReason)
    }

    func testDuplicateIdsCollapsingBelowMinimumFailsUngrounded() throws {
        // After dedup only 1 distinct ID survives → below minGroundedTurns (2).
        let json = #"""
        {"claims": [
          {"claim": "c", "confidence": 0.8, "supporting_turn_ids": ["a","a","a"], "why_non_obvious": "w"}
        ]}
        """#
        let out = try ReflectionValidator.validate(
            rawJSON: json,
            validMessageIds: validIds("a", "b"),
            messageIdToNodeId: [:],
            runId: runId,
            now: now
        )
        XCTAssertTrue(out.claims.isEmpty)
        XCTAssertEqual(out.rejectionReason, .unsupported)
    }

    func testEmptyClaimStringIsSkippedNotRejected() throws {
        // A whitespace-only claim is silently dropped; a valid sibling passes.
        let json = #"""
        {"claims": [
          {"claim": "   ", "confidence": 0.9, "supporting_turn_ids": ["a","b"], "why_non_obvious": "w"},
          {"claim": "real one", "confidence": 0.9, "supporting_turn_ids": ["a","b"], "why_non_obvious": "w"}
        ]}
        """#
        let ids = validIds("a", "b")
        let out = try ReflectionValidator.validate(
            rawJSON: json,
            validMessageIds: ids,
            messageIdToNodeId: syntheticNodeMap(ids),
            runId: runId,
            now: now
        )
        XCTAssertEqual(out.claims.count, 1)
        XCTAssertEqual(out.claims[0].claim, "real one")
    }

    func testMixedPassAndFailKeepsOnlyPassing() throws {
        let json = #"""
        {"claims": [
          {"claim": "keeper", "confidence": 0.8, "supporting_turn_ids": ["a","b"], "why_non_obvious": "w"},
          {"claim": "drop low conf", "confidence": 0.1, "supporting_turn_ids": ["a","b"], "why_non_obvious": "w"},
          {"claim": "drop ungrounded", "confidence": 0.9, "supporting_turn_ids": ["fake"], "why_non_obvious": "w"}
        ]}
        """#
        let ids = validIds("a", "b")
        let out = try ReflectionValidator.validate(
            rawJSON: json,
            validMessageIds: ids,
            messageIdToNodeId: syntheticNodeMap(ids),
            runId: runId,
            now: now
        )
        XCTAssertEqual(out.claims.count, 1)
        XCTAssertEqual(out.claims[0].claim, "keeper")
        XCTAssertNil(out.rejectionReason)
    }
}
