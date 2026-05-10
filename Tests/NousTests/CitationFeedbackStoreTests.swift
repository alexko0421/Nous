import XCTest
@testable import Nous

final class CitationFeedbackStoreTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var store: CitationFeedbackStore!
    private let conv = UUID()
    private let turn = UUID()
    private let atom = UUID()

    override func setUpWithError() throws {
        nodeStore = try NodeStore(path: ":memory:")
        store = CitationFeedbackStore(nodeStore: nodeStore)
    }

    override func tearDown() {
        store = nil
        nodeStore = nil
        super.tearDown()
    }

    func testUpsertCreatesRow() throws {
        try store.upsert(conversationId: conv, turnId: turn, atomId: atom, verdict: .up, note: nil)
        let row = try store.fetch(conversationId: conv, turnId: turn, atomId: atom)
        XCTAssertEqual(row?.verdict, .up)
    }

    func testUpsertSecondTimeUpdates() throws {
        try store.upsert(conversationId: conv, turnId: turn, atomId: atom, verdict: .up, note: nil)
        try store.upsert(conversationId: conv, turnId: turn, atomId: atom, verdict: .down, note: "irrelevant")
        let row = try store.fetch(conversationId: conv, turnId: turn, atomId: atom)
        XCTAssertEqual(row?.verdict, .down)
        XCTAssertEqual(row?.note, "irrelevant")
    }

    func testDifferentTurnsAreSeparateRows() throws {
        let turn2 = UUID()
        try store.upsert(conversationId: conv, turnId: turn, atomId: atom, verdict: .up, note: nil)
        try store.upsert(conversationId: conv, turnId: turn2, atomId: atom, verdict: .down, note: nil)
        XCTAssertEqual(try store.fetch(conversationId: conv, turnId: turn, atomId: atom)?.verdict, .up)
        XCTAssertEqual(try store.fetch(conversationId: conv, turnId: turn2, atomId: atom)?.verdict, .down)
    }

    func testFetchMissingReturnsNil() throws {
        let row = try store.fetch(conversationId: conv, turnId: turn, atomId: atom)
        XCTAssertNil(row)
    }
}
