import XCTest
@testable import Nous

final class EdgeFeedbackTypesTests: XCTestCase {
    func testThumbVerdictRoundTrips() throws {
        let verdicts: [ThumbVerdict] = [.up, .down, .unset]
        for verdict in verdicts {
            let data = try JSONEncoder().encode(verdict)
            let decoded = try JSONDecoder().decode(ThumbVerdict.self, from: data)
            XCTAssertEqual(verdict, decoded)
        }
    }

    func testJudgePathRoundTrips() throws {
        let paths: [JudgePath] = [.atom, .llm, .fallback, .retrieval]
        for path in paths {
            let data = try JSONEncoder().encode(path)
            let decoded = try JSONDecoder().decode(JudgePath.self, from: data)
            XCTAssertEqual(path, decoded)
        }
    }

    func testRawValuesAreStable() {
        XCTAssertEqual(ThumbVerdict.up.rawValue, "up")
        XCTAssertEqual(ThumbVerdict.down.rawValue, "down")
        XCTAssertEqual(ThumbVerdict.unset.rawValue, "unset")
        XCTAssertEqual(JudgePath.atom.rawValue, "atom")
        XCTAssertEqual(JudgePath.llm.rawValue, "llm")
        XCTAssertEqual(JudgePath.fallback.rawValue, "fallback")
        XCTAssertEqual(JudgePath.retrieval.rawValue, "retrieval")
    }
}
