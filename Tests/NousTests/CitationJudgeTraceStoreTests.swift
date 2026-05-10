import XCTest
@testable import Nous

final class CitationJudgeTraceStoreTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var store: CitationJudgeTraceStore!
    private let conv = UUID()
    private let turn = UUID()
    private let atom1 = UUID()
    private let atom2 = UUID()

    override func setUpWithError() throws {
        nodeStore = try NodeStore(path: ":memory:")
        store = CitationJudgeTraceStore(nodeStore: nodeStore)
    }

    override func tearDown() {
        store = nil
        nodeStore = nil
        super.tearDown()
    }

    func testAppendDisplayedRow() throws {
        try store.append(conversationId: conv, turnId: turn, atomId: atom1, confidence: 0.84, wasDisplayed: true)
        let rows = try store.byTurn(turnId: turn)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].wasDisplayed)
    }

    func testAppendFilteredRow() throws {
        try store.append(conversationId: conv, turnId: turn, atomId: atom1, confidence: 0.55, wasDisplayed: false)
        let rows = try store.byTurn(turnId: turn)
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].wasDisplayed)
    }

    func testByTurnReturnsAllAtomsForTurn() throws {
        try store.append(conversationId: conv, turnId: turn, atomId: atom1, confidence: 0.84, wasDisplayed: true)
        try store.append(conversationId: conv, turnId: turn, atomId: atom2, confidence: 0.55, wasDisplayed: false)
        let rows = try store.byTurn(turnId: turn)
        XCTAssertEqual(rows.count, 2)
    }

    func testByTurnExcludesOtherTurns() throws {
        let otherTurn = UUID()
        try store.append(conversationId: conv, turnId: turn, atomId: atom1, confidence: 0.84, wasDisplayed: true)
        try store.append(conversationId: conv, turnId: otherTurn, atomId: atom2, confidence: 0.55, wasDisplayed: false)
        let rows = try store.byTurn(turnId: turn)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].atomId, atom1)
    }
}
