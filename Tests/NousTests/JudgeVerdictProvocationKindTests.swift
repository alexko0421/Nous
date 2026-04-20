import XCTest
@testable import Nous

final class JudgeVerdictProvocationKindTests: XCTestCase {

    func testDefaultProvocationKindIsNeutralWhenConstructedWithoutField() {
        let verdict = JudgeVerdict(
            tensionExists: false,
            userState: .exploring,
            shouldProvoke: false,
            entryId: nil,
            reason: "no tension",
            inferredMode: .companion
        )
        XCTAssertEqual(verdict.provocationKind, .neutral)
    }

    func testEncodeIncludesProvocationKindKey() throws {
        var verdict = JudgeVerdict(
            tensionExists: true,
            userState: .deciding,
            shouldProvoke: true,
            entryId: "E1",
            reason: "pricing conflict",
            inferredMode: .strategist
        )
        verdict.provocationKind = .contradiction

        let data = try JSONEncoder().encode(verdict)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"provocation_kind\":\"contradiction\""),
                      "encoded verdict must carry provocation_kind under snake_case key, got: \(json)")
    }

    func testDecodeOldVerdictWithoutProvocationKindFallsBackToNeutral() throws {
        // verdictJSON shape from before this field existed.
        let legacyJSON = """
        {"tension_exists":true,"user_state":"deciding","should_provoke":true,
         "entry_id":"E1","reason":"old row","inferred_mode":"strategist"}
        """
        let data = legacyJSON.data(using: .utf8)!
        let verdict = try JSONDecoder().decode(JudgeVerdict.self, from: data)
        XCTAssertEqual(verdict.provocationKind, .neutral,
                       "old judge_events rows missing provocation_kind must decode safely as neutral")
    }

    func testDecodeRoundTripPreservesProvocationKind() throws {
        var original = JudgeVerdict(
            tensionExists: true,
            userState: .deciding,
            shouldProvoke: true,
            entryId: "E1",
            reason: "spark",
            inferredMode: .companion
        )
        original.provocationKind = .spark

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JudgeVerdict.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
