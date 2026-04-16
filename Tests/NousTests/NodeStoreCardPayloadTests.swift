import XCTest
@testable import Nous

final class NodeStoreCardPayloadTests: XCTestCase {
    var nodeStore: NodeStore!
    var nodeId: UUID!

    override func setUpWithError() throws {
        try super.setUpWithError()
        nodeStore = try NodeStore(path: ":memory:")
        let node = NousNode(type: .conversation, title: "t")
        try nodeStore.insertNode(node)
        self.nodeId = node.id
    }

    func testInsertAndFetchMessageWithoutCardPayload() throws {
        let msg = Message(nodeId: nodeId, role: .assistant, content: "hi")
        try nodeStore.insertMessage(msg)
        let fetched = try nodeStore.fetchMessages(nodeId: nodeId)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertNil(fetched.first?.cardPayload)
    }

    func testInsertAndFetchMessageWithCardPayload() throws {
        let payload = CardPayload(framing: "f", options: ["a", "b"])
        let msg = Message(
            nodeId: nodeId,
            role: .assistant,
            content: "f",
            cardPayload: payload
        )
        try nodeStore.insertMessage(msg)
        let fetched = try nodeStore.fetchMessages(nodeId: nodeId)
        XCTAssertEqual(fetched.first?.cardPayload?.framing, "f")
        XCTAssertEqual(fetched.first?.cardPayload?.options, ["a", "b"])
    }
}
