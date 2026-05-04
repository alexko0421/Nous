import XCTest
@testable import Nous

@MainActor
final class MessageSourcePersistenceTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var tempDBPath: String!

    override func setUp() async throws {
        try await super.setUp()
        tempDBPath = NSTemporaryDirectory() + "voice-source-test-\(UUID().uuidString).db"
        nodeStore = try NodeStore(path: tempDBPath)
    }

    override func tearDown() async throws {
        nodeStore = nil
        try? FileManager.default.removeItem(atPath: tempDBPath)
        try await super.tearDown()
    }

    func testTypedMessageRoundTrip() throws {
        let nodeId = UUID()
        let node = NousNode(id: nodeId, type: .conversation, title: "Test")
        try nodeStore.insertNode(node)

        let message = Message(
            nodeId: nodeId,
            role: .user,
            content: "hello",
            source: .typed
        )
        try nodeStore.insertMessage(message)

        let fetched = try nodeStore.fetchMessages(nodeId: nodeId)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.source, .typed)
    }

    func testVoiceMessageRoundTrip() throws {
        let nodeId = UUID()
        let node = NousNode(id: nodeId, type: .conversation, title: "Test")
        try nodeStore.insertNode(node)

        let message = Message(
            nodeId: nodeId,
            role: .user,
            content: "spoken",
            source: .voice
        )
        try nodeStore.insertMessage(message)

        let fetched = try nodeStore.fetchMessages(nodeId: nodeId)
        XCTAssertEqual(fetched.first?.source, .voice)
    }

    func testLegacyMessageRowDecodesAsTyped() throws {
        let nodeId = UUID()
        let node = NousNode(id: nodeId, type: .conversation, title: "Test")
        try nodeStore.insertNode(node)

        let message = Message(nodeId: nodeId, role: .user, content: "legacy")
        try nodeStore.insertMessage(message)

        let fetched = try nodeStore.fetchMessages(nodeId: nodeId)
        XCTAssertEqual(fetched.first?.source, .typed)
    }
}
