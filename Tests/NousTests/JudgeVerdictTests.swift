// Tests/NousTests/JudgeVerdictTests.swift
import XCTest
@testable import Nous

final class JudgeVerdictTests: XCTestCase {

    func testDecodesWellFormedJSON() throws {
        let json = """
        {
          "tension_exists": true,
          "user_state": "deciding",
          "should_provoke": true,
          "entry_id": "ABCD-1234",
          "reason": "User is choosing pricing; prior entry explicitly rejected price competition.",
          "inferred_mode": "strategist"
        }
        """.data(using: .utf8)!

        let verdict = try JSONDecoder().decode(JudgeVerdict.self, from: json)

        XCTAssertTrue(verdict.tensionExists)
        XCTAssertEqual(verdict.userState, .deciding)
        XCTAssertTrue(verdict.shouldProvoke)
        XCTAssertEqual(verdict.entryId, "ABCD-1234")
        XCTAssertTrue(verdict.reason.contains("pricing"))
        XCTAssertEqual(verdict.inferredMode, .strategist)
    }

    func testDecodesNullEntryId() throws {
        let json = """
        {
          "tension_exists": false,
          "user_state": "venting",
          "should_provoke": false,
          "entry_id": null,
          "reason": "Venting — no interjection.",
          "inferred_mode": "companion"
        }
        """.data(using: .utf8)!

        let verdict = try JSONDecoder().decode(JudgeVerdict.self, from: json)
        XCTAssertNil(verdict.entryId)
        XCTAssertEqual(verdict.userState, .venting)
        XCTAssertFalse(verdict.shouldProvoke)
    }

    func testRejectsUnknownUserState() {
        let json = """
        { "tension_exists": false, "user_state": "bogus",
          "should_provoke": false, "entry_id": null, "reason": "x" }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(JudgeVerdict.self, from: json))
    }

    func testRejectsMissingInferredMode() {
        let json = """
        { "tension_exists": false, "user_state": "venting",
          "should_provoke": false, "entry_id": null, "reason": "x" }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(JudgeVerdict.self, from: json))
    }

    func testBehaviorProfileContextBlocksAreNonEmpty() {
        XCTAssertFalse(BehaviorProfile.supportive.contextBlock.isEmpty)
        XCTAssertFalse(BehaviorProfile.provocative.contextBlock.isEmpty)
        XCTAssertNotEqual(
            BehaviorProfile.supportive.contextBlock,
            BehaviorProfile.provocative.contextBlock
        )
    }

    func testProfileFromVerdictRespectsShouldProvoke() {
        let provokingVerdict = JudgeVerdict(
            tensionExists: true, userState: .deciding,
            shouldProvoke: true, entryId: "x", reason: "r", inferredMode: .companion
        )
        XCTAssertEqual(BehaviorProfile(verdict: provokingVerdict), .provocative)

        let quietVerdict = JudgeVerdict(
            tensionExists: false, userState: .venting,
            shouldProvoke: false, entryId: nil, reason: "r", inferredMode: .companion
        )
        XCTAssertEqual(BehaviorProfile(verdict: quietVerdict), .supportive)
    }
}
