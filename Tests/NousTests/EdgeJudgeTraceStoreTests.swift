import XCTest
@testable import Nous

final class EdgeJudgeTraceStoreTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var store: EdgeJudgeTraceStore!
    private let nodeA = UUID()
    private let nodeB = UUID()

    override func setUpWithError() throws {
        nodeStore = try NodeStore(path: ":memory:")
        store = EdgeJudgeTraceStore(nodeStore: nodeStore)
    }

    override func tearDown() {
        store = nil
        nodeStore = nil
        super.tearDown()
    }

    func testAppendOneRow() throws {
        try store.append(
            sourceId: nodeA,
            targetId: nodeB,
            relationKind: "supports",
            judgePath: .atom,
            similarity: 0.82,
            confidence: 0.78
        )
        let history = try store.history(sourceId: nodeA, targetId: nodeB, limit: 10)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].relationKind, "supports")
        XCTAssertEqual(history[0].judgePath, .atom)
    }

    func testAppendNullKindForRejection() throws {
        try store.append(
            sourceId: nodeA,
            targetId: nodeB,
            relationKind: nil,
            judgePath: .fallback,
            similarity: 0.71,
            confidence: nil
        )
        let history = try store.history(sourceId: nodeA, targetId: nodeB, limit: 10)
        XCTAssertEqual(history.count, 1)
        XCTAssertNil(history[0].relationKind, "Nil relation kind = judge said no connection")
    }

    func testHistoryReturnsDescendingByTime() throws {
        try store.append(sourceId: nodeA, targetId: nodeB, relationKind: "supports", judgePath: .atom, similarity: 0.8, confidence: 0.7)
        Thread.sleep(forTimeInterval: 0.01)
        try store.append(sourceId: nodeA, targetId: nodeB, relationKind: "contradicts", judgePath: .llm, similarity: 0.85, confidence: 0.82)
        let history = try store.history(sourceId: nodeA, targetId: nodeB, limit: 10)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].relationKind, "contradicts", "Most recent first")
        XCTAssertEqual(history[1].relationKind, "supports")
    }

    func testHistoryNormalizedByPair() throws {
        try store.append(sourceId: nodeA, targetId: nodeB, relationKind: "supports", judgePath: .atom, similarity: 0.8, confidence: 0.7)
        let reversed = try store.history(sourceId: nodeB, targetId: nodeA, limit: 10)
        XCTAssertEqual(reversed.count, 1)
    }

    func testLatestReturnsOnlyMostRecent() throws {
        try store.append(sourceId: nodeA, targetId: nodeB, relationKind: "supports", judgePath: .atom, similarity: 0.8, confidence: 0.7)
        Thread.sleep(forTimeInterval: 0.01)
        try store.append(sourceId: nodeA, targetId: nodeB, relationKind: nil, judgePath: .fallback, similarity: 0.65, confidence: nil)
        let latest = try store.latest(sourceId: nodeA, targetId: nodeB)
        XCTAssertNil(latest?.relationKind)
        XCTAssertEqual(latest?.judgePath, .fallback)
    }
}
