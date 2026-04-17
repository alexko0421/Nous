import XCTest
@testable import Nous

final class UserMemoryServiceTests: XCTestCase {

    var store: NodeStore!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    // MARK: - T2: evidence-only (user turns only)

    /// Plan §9 T2 — the prompt sent to the LLM during refreshConversation must
    /// include Alex's user-role content and must NOT include any assistant-role
    /// content. Also asserts the literal "ALEX ONLY" marker survives future
    /// prompt edits, so prompt-drift regressions trip this test.
    func testRefreshConversationSendsOnlyUserTurns() async throws {
        let capture = PromptCapture()
        let mock = MockLLMService(capture: capture, reply: "- Alex is shipping the memory refactor")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let node = NousNode(type: .conversation, title: "Planning chat", content: "")
        try store.insertNode(node)

        let userTurn1 = "I'm rewriting how cross-chat memory works"
        let userTurn2 = "The old blob summariser is lossy"
        let userTurn3 = "Let's scope memory to global/project/chat"
        let asstTurn1 = "That sounds like a reasonable architecture"
        let asstTurn2 = "I can help plan the migration"
        let asstTurn3 = "Do you want me to draft it?"

        let messages: [Message] = [
            Message(nodeId: node.id, role: .user,      content: userTurn1, timestamp: Date(timeIntervalSince1970: 1)),
            Message(nodeId: node.id, role: .assistant, content: asstTurn1, timestamp: Date(timeIntervalSince1970: 2)),
            Message(nodeId: node.id, role: .user,      content: userTurn2, timestamp: Date(timeIntervalSince1970: 3)),
            Message(nodeId: node.id, role: .assistant, content: asstTurn2, timestamp: Date(timeIntervalSince1970: 4)),
            Message(nodeId: node.id, role: .user,      content: userTurn3, timestamp: Date(timeIntervalSince1970: 5)),
            Message(nodeId: node.id, role: .assistant, content: asstTurn3, timestamp: Date(timeIntervalSince1970: 6)),
        ]

        await service.refreshConversation(nodeId: node.id, messages: messages)

        guard let sentPrompt = await capture.prompt() else {
            XCTFail("MockLLMService was never called")
            return
        }

        // Each of Alex's turns must be present in the prompt.
        XCTAssertTrue(sentPrompt.contains(userTurn1), "user turn 1 missing from prompt")
        XCTAssertTrue(sentPrompt.contains(userTurn2), "user turn 2 missing from prompt")
        XCTAssertTrue(sentPrompt.contains(userTurn3), "user turn 3 missing from prompt")

        // No assistant turn content may appear in the prompt.
        XCTAssertFalse(sentPrompt.contains(asstTurn1),
                       "assistant turn 1 leaked into evidence — self-confirmation loop risk")
        XCTAssertFalse(sentPrompt.contains(asstTurn2),
                       "assistant turn 2 leaked into evidence — self-confirmation loop risk")
        XCTAssertFalse(sentPrompt.contains(asstTurn3),
                       "assistant turn 3 leaked into evidence — self-confirmation loop risk")

        // Literal marker guards against future prompt-design drift silently
        // dropping the user-only framing.
        XCTAssertTrue(sentPrompt.contains("ALEX ONLY"),
                      "prompt must carry the literal 'ALEX ONLY' marker so evidence framing is explicit")
    }

    /// With no user-role messages the refresh must be a no-op: LLM is never
    /// invoked and no conversation_memory row is written.
    func testRefreshConversationIsNoOpWithoutUserTurns() async throws {
        let capture = PromptCapture()
        let mock = MockLLMService(capture: capture, reply: "should not be called")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let node = NousNode(type: .conversation, title: "Empty-from-user", content: "")
        try store.insertNode(node)

        let assistantOnly: [Message] = [
            Message(nodeId: node.id, role: .assistant, content: "hello",   timestamp: Date(timeIntervalSince1970: 1)),
            Message(nodeId: node.id, role: .assistant, content: "anyone?", timestamp: Date(timeIntervalSince1970: 2)),
        ]

        await service.refreshConversation(nodeId: node.id, messages: assistantOnly)

        let prompt = await capture.prompt()
        XCTAssertNil(prompt, "LLM must not be called when there are no user turns")
        XCTAssertNil(try store.fetchConversationMemory(nodeId: node.id))
    }
}

// MARK: - Test doubles

private actor PromptCapture {
    private var captured: String?

    func record(_ prompt: String) { captured = prompt }
    func prompt() -> String? { captured }
}

private struct MockLLMService: LLMService {
    let capture: PromptCapture
    let reply: String

    func generate(
        messages: [LLMMessage],
        system: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        // Capture the first user-role message content — that's the prompt
        // the service under test constructed.
        let userPrompt = messages.first(where: { $0.role == "user" })?.content ?? ""
        await capture.record(userPrompt)

        let reply = self.reply
        return AsyncThrowingStream { continuation in
            continuation.yield(reply)
            continuation.finish()
        }
    }
}
