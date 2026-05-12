import XCTest
@testable import Nous

final class EdgeFeedbackStoreTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var store: EdgeFeedbackStore!
    private let nodeA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let nodeB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    override func setUpWithError() throws {
        nodeStore = try NodeStore(path: ":memory:")
        store = EdgeFeedbackStore(nodeStore: nodeStore)
    }

    override func tearDown() {
        store = nil
        nodeStore = nil
        super.tearDown()
    }

    func testUpsertCreatesRow() throws {
        try store.upsert(sourceId: nodeA, targetId: nodeB, relationKind: "supports", verdict: .up, note: nil)
        let row = try store.fetch(sourceId: nodeA, targetId: nodeB, relationKind: "supports")
        XCTAssertEqual(row?.verdict, .up)
        XCTAssertEqual(row?.verdictCount, 1)
    }

    func testUpsertSecondTimeUpdatesAndBumpsCount() throws {
        try store.upsert(sourceId: nodeA, targetId: nodeB, relationKind: "supports", verdict: .up, note: nil)
        try store.upsert(sourceId: nodeA, targetId: nodeB, relationKind: "supports", verdict: .down, note: "唔啱")
        let row = try store.fetch(sourceId: nodeA, targetId: nodeB, relationKind: "supports")
        XCTAssertEqual(row?.verdict, .down)
        XCTAssertEqual(row?.note, "唔啱")
        XCTAssertEqual(row?.verdictCount, 2)
    }

    func testNodePairOrderIsNormalized() throws {
        try store.upsert(sourceId: nodeA, targetId: nodeB, relationKind: "supports", verdict: .up, note: nil)
        let rowReversed = try store.fetch(sourceId: nodeB, targetId: nodeA, relationKind: "supports")
        XCTAssertEqual(rowReversed?.verdict, .up)
    }

    func testDifferentRelationKindsAreSeparateRows() throws {
        try store.upsert(sourceId: nodeA, targetId: nodeB, relationKind: "supports", verdict: .up, note: nil)
        try store.upsert(sourceId: nodeA, targetId: nodeB, relationKind: "contradicts", verdict: .down, note: nil)
        XCTAssertEqual(try store.fetch(sourceId: nodeA, targetId: nodeB, relationKind: "supports")?.verdict, .up)
        XCTAssertEqual(try store.fetch(sourceId: nodeA, targetId: nodeB, relationKind: "contradicts")?.verdict, .down)
    }

    func testFetchMissingReturnsNil() throws {
        let row = try store.fetch(sourceId: nodeA, targetId: nodeB, relationKind: "supports")
        XCTAssertNil(row)
    }

    func testRegenCarryOverInvariant() throws {
        try store.upsert(sourceId: nodeA, targetId: nodeB, relationKind: "supports", verdict: .up, note: nil)
        let row = try store.fetch(sourceId: nodeA, targetId: nodeB, relationKind: "supports")
        XCTAssertEqual(row?.verdict, .up, "Feedback survives across regen of same kind")

        let differentKindRow = try store.fetch(sourceId: nodeA, targetId: nodeB, relationKind: "contradicts")
        XCTAssertNil(differentKindRow, "Different kind starts fresh — prior thumb does not apply")

        let originalRow = try store.fetch(sourceId: nodeA, targetId: nodeB, relationKind: "supports")
        XCTAssertEqual(originalRow?.verdict, .up)
    }
}
