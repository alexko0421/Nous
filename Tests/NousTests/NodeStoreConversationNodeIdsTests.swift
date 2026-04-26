import XCTest
@testable import Nous

final class NodeStoreConversationNodeIdsTests: XCTestCase {
    var store: NodeStore!

    override func setUpWithError() throws {
        store = try NodeStore.inMemoryForTesting()
    }

    func test_resolvesMessageIdsToOwningNodeIds() throws {
        let nodeA = UUID()
        let nodeB = UUID()
        try store.insertNodeForTest(id: nodeA)
        try store.insertNodeForTest(id: nodeB)

        let m1 = UUID()
        let m2 = UUID()
        let m3 = UUID()
        try store.insertMessageForTest(id: m1, nodeId: nodeA)
        try store.insertMessageForTest(id: m2, nodeId: nodeA)
        try store.insertMessageForTest(id: m3, nodeId: nodeB)

        let result = try store.conversationNodeIds(forMessageIds: [m1, m2, m3])
        XCTAssertEqual(result[m1], nodeA)
        XCTAssertEqual(result[m2], nodeA)
        XCTAssertEqual(result[m3], nodeB)
    }

    func test_unknownMessageIdsAreOmittedNotFailed() throws {
        let nodeA = UUID()
        try store.insertNodeForTest(id: nodeA)
        let m1 = UUID()
        try store.insertMessageForTest(id: m1, nodeId: nodeA)

        let unknown = UUID()
        let result = try store.conversationNodeIds(forMessageIds: [m1, unknown])
        XCTAssertEqual(result[m1], nodeA)
        XCTAssertNil(result[unknown])
    }

    func test_emptyInputReturnsEmpty() throws {
        let result = try store.conversationNodeIds(forMessageIds: [])
        XCTAssertEqual(result.count, 0)
    }

    func test_handlesMoreThan999Ids() throws {
        // SQLite parameter limit is 999; resolver must chunk transparently.
        let nodeA = UUID()
        try store.insertNodeForTest(id: nodeA)
        var messageIds: [UUID] = []
        for _ in 0..<1500 {
            let m = UUID()
            try store.insertMessageForTest(id: m, nodeId: nodeA)
            messageIds.append(m)
        }
        let result = try store.conversationNodeIds(forMessageIds: messageIds)
        XCTAssertEqual(result.count, 1500)
        XCTAssertTrue(result.values.allSatisfy { $0 == nodeA })
    }
}
