import XCTest
@testable import Nous

final class EdgeFeedbackSchemaTests: XCTestCase {
    private var store: NodeStore!

    override func setUpWithError() throws {
        store = try NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func tableExists(_ name: String) throws -> Bool {
        let stmt = try store.rawDatabase.prepare(
            "SELECT name FROM sqlite_master WHERE type='table' AND name = ?;"
        )
        try stmt.bind(name, at: 1)
        return try stmt.step()
    }

    private func indexCount(forTable name: String) throws -> Int {
        let stmt = try store.rawDatabase.prepare(
            "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name = ?;"
        )
        try stmt.bind(name, at: 1)
        var count = 0
        while try stmt.step() { count += 1 }
        return count
    }

    func testEdgeFeedbackTableExists() throws {
        XCTAssertTrue(try tableExists("edge_feedback"))
    }

    func testCitationFeedbackTableExists() throws {
        XCTAssertTrue(try tableExists("citation_feedback"))
    }

    func testEdgeJudgeTraceTableExists() throws {
        XCTAssertTrue(try tableExists("edge_judge_trace"))
    }

    func testCitationJudgeTraceTableExists() throws {
        XCTAssertTrue(try tableExists("citation_judge_trace"))
    }

    func testEdgeJudgeTraceHasIndex() throws {
        XCTAssertGreaterThanOrEqual(
            try indexCount(forTable: "edge_judge_trace"), 1,
            "edge_judge_trace should have at least one index"
        )
    }
}
