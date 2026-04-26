import XCTest
@testable import Nous

final class EdgeDecodeStaleRowGuardTests: XCTestCase {
    var store: NodeStore!

    override func setUpWithError() throws {
        store = try NodeStore.inMemoryForTesting()
    }

    func test_unknownEdgeTypeRaw_isFilteredOutByFetchAllEdges() throws {
        let edgeId = UUID()
        let srcId = UUID()
        let tgtId = UUID()
        try store.insertNodeForTest(id: srcId)
        try store.insertNodeForTest(id: tgtId)

        try store.executeRawForTest("""
            INSERT INTO edges (id, sourceId, targetId, strength, type)
            VALUES ('\(edgeId.uuidString)', '\(srcId.uuidString)', '\(tgtId.uuidString)', 0.3, 'shared');
        """)

        let edges = try store.fetchAllEdges()
        XCTAssertEqual(edges.count, 0, "Stale 'shared' rows must not appear as any EdgeType")
    }
}
