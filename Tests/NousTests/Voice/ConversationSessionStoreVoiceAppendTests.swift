import XCTest
@testable import Nous

@MainActor
final class ConversationSessionStoreVoiceAppendTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var store: ConversationSessionStore!
    private var tempDBPath: String!

    override func setUp() async throws {
        try await super.setUp()
        tempDBPath = NSTemporaryDirectory() + "voice-append-test-\(UUID().uuidString).db"
        nodeStore = try NodeStore(path: tempDBPath)
        store = ConversationSessionStore(nodeStore: nodeStore)
    }

    override func tearDown() async throws {
        store = nil
        nodeStore = nil
        try? FileManager.default.removeItem(atPath: tempDBPath)
        try await super.tearDown()
    }

    func testAppendVoiceUserMessageInsertsAndUpdatesNodeContent() throws {
        let conversation = try store.startConversation(title: "Test")
        let timestamp = Date()

        let result = try store.appendVoiceUserMessage(
            nodeId: conversation.id,
            text: "hello world",
            timestamp: timestamp
        )

        XCTAssertEqual(result.userMessage.content, "hello world")
        XCTAssertEqual(result.userMessage.source, .voice)
        XCTAssertEqual(result.userMessage.role, .user)
        XCTAssertEqual(result.messagesAfterAppend.count, 1)
        XCTAssertFalse(
            result.node.content.isEmpty,
            "persistTranscript should populate nodes.content"
        )
        XCTAssertTrue(
            result.node.content.contains("hello world"),
            "nodes.content should contain the voice utterance text"
        )
    }

    func testAppendVoiceUserMessageThrowsForMissingNode() throws {
        let bogusId = UUID()
        XCTAssertThrowsError(
            try store.appendVoiceUserMessage(
                nodeId: bogusId,
                text: "lost",
                timestamp: Date()
            )
        ) { error in
            guard case ConversationSessionStoreError.missingNode(let id) = error else {
                XCTFail("expected missingNode, got \(error)")
                return
            }
            XCTAssertEqual(id, bogusId)
        }
    }

    func testAppendVoiceUserMessagePreservesPriorMessages() throws {
        let conversation = try store.startConversation(title: "Test")
        let typed = Message(
            nodeId: conversation.id,
            role: .user,
            content: "earlier",
            source: .typed
        )
        try nodeStore.insertMessage(typed)

        let result = try store.appendVoiceUserMessage(
            nodeId: conversation.id,
            text: "later",
            timestamp: Date()
        )

        XCTAssertEqual(result.messagesAfterAppend.count, 2)
        XCTAssertEqual(result.messagesAfterAppend.map(\.source), [.typed, .voice])
    }
}
