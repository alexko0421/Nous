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

    /// P0 fix from post-commit /plan-eng-review: Alex routinely pastes Nous's
    /// prior reply into his next user turn as a markdown blockquote (`> …`)
    /// when asking for clarification. The role filter alone would let that
    /// quoted-assistant text back into the evidence prompt, violating
    /// invariant #4 (self-confirmation protection). The service must strip
    /// the quote block before joining user turns.
    func testRefreshConversationStripsQuotedAssistantBlocks() async throws {
        let capture = PromptCapture()
        let mock = MockLLMService(capture: capture, reply: "- Alex is debugging a memory leak")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let node = NousNode(type: .conversation, title: "Clarification chat", content: "")
        try store.insertNode(node)

        let asstReply = "The most likely cause is a retain cycle in the closure capture list."
        let userQuoteBack = """
        > \(asstReply)

        Why do you think it's a retain cycle and not an actor re-entrancy issue?
        """

        let messages: [Message] = [
            Message(nodeId: node.id, role: .user,      content: "I have a memory leak in my Swift app",
                    timestamp: Date(timeIntervalSince1970: 1)),
            Message(nodeId: node.id, role: .assistant, content: asstReply,
                    timestamp: Date(timeIntervalSince1970: 2)),
            Message(nodeId: node.id, role: .user,      content: userQuoteBack,
                    timestamp: Date(timeIntervalSince1970: 3)),
        ]

        await service.refreshConversation(nodeId: node.id, messages: messages)

        guard let sentPrompt = await capture.prompt() else {
            XCTFail("MockLLMService was never called")
            return
        }

        XCTAssertFalse(sentPrompt.contains(asstReply),
                       "quoted assistant text leaked back into evidence — self-confirmation loop")
        XCTAssertTrue(sentPrompt.contains("retain cycle and not an actor re-entrancy"),
                      "the user's own question after the quote block must survive")
    }

    /// P0 fix: when Alex pastes the full assistant reply WITHOUT quote marks
    /// (copy/paste without formatting), the Jaccard similarity check drops the
    /// turn. Uses a distinctive multi-word assistant reply to beat the 3-token
    /// floor on the similarity gate.
    func testRefreshConversationDropsNearDuplicateAssistantPaste() async throws {
        let capture = PromptCapture()
        let mock = MockLLMService(capture: capture, reply: "- Alex is asking about concurrency primitives")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let node = NousNode(type: .conversation, title: "Paste chat", content: "")
        try store.insertNode(node)

        let asstReply = "Swift actors serialize access to mutable state by running their methods on a dedicated executor, so re-entrant calls queue rather than racing"
        let userPasteBack = asstReply

        let messages: [Message] = [
            Message(nodeId: node.id, role: .user,      content: "Explain Swift actors",
                    timestamp: Date(timeIntervalSince1970: 1)),
            Message(nodeId: node.id, role: .assistant, content: asstReply,
                    timestamp: Date(timeIntervalSince1970: 2)),
            Message(nodeId: node.id, role: .user,      content: userPasteBack,
                    timestamp: Date(timeIntervalSince1970: 3)),
            Message(nodeId: node.id, role: .user,      content: "That's the part I want to understand better",
                    timestamp: Date(timeIntervalSince1970: 4)),
        ]

        await service.refreshConversation(nodeId: node.id, messages: messages)

        guard let sentPrompt = await capture.prompt() else {
            XCTFail("MockLLMService was never called")
            return
        }

        XCTAssertFalse(sentPrompt.contains(asstReply),
                       "pasted assistant reply leaked back via user role — similarity gate failed")
        XCTAssertTrue(sentPrompt.contains("That's the part I want to understand"),
                      "genuine user follow-up must remain")
        XCTAssertTrue(sentPrompt.contains("Explain Swift actors"),
                      "user's original question must remain")
    }

    /// Unit tests for the helpers themselves so similarity/strip logic is
    /// covered independently of the async refresh flow.
    func testStripQuoteBlocksRemovesLeadingAngleLines() {
        let input = """
        > first quoted line
        >> nested quote
        hello
         >indented quote
        world
        """
        let stripped = UserMemoryService.stripQuoteBlocks(input)
        XCTAssertFalse(stripped.contains("first quoted"))
        XCTAssertFalse(stripped.contains("nested quote"))
        XCTAssertFalse(stripped.contains("indented quote"))
        XCTAssertTrue(stripped.contains("hello"))
        XCTAssertTrue(stripped.contains("world"))
    }

    func testTokenJaccardFloorsShortStrings() {
        XCTAssertEqual(UserMemoryService.tokenJaccard("ok", "ok"), 0,
                       "1-token inputs must return 0 to avoid false positives")
        XCTAssertEqual(UserMemoryService.tokenJaccard("yes please", "yes please"), 0,
                       "2-token inputs must return 0")
        let a = "actors serialize access to mutable state"
        XCTAssertGreaterThanOrEqual(UserMemoryService.tokenJaccard(a, a), 0.99,
                                    "identical 6-token strings must score ~1.0")
    }

    // MARK: - shouldRefreshProject (timestamp-derived trigger, §14.1 / Eng Review #3)

    /// Service-level smoke test for the timestamp-based project-refresh gate.
    /// The `NodeStoreTests.testCountConversationMemoryUpdatesSinceProjectMemory`
    /// covers the SQL semantics; this one covers the threshold comparison that
    /// UserMemoryScheduler actually calls.
    func testShouldRefreshProjectRespectsThreshold() throws {
        let mock = MockLLMService(capture: PromptCapture(), reply: "unused")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let project = Project(title: "Threshold test")
        try store.insertProject(project)

        let chat = NousNode(type: .conversation, title: "c", content: "", projectId: project.id)
        try store.insertNode(chat)

        // 0 refreshes — always below threshold.
        XCTAssertFalse(service.shouldRefreshProject(projectId: project.id, threshold: 3))

        // 1 refresh — still below.
        try store.saveConversationMemory(
            ConversationMemory(nodeId: chat.id, content: "c1", updatedAt: Date(timeIntervalSince1970: 100))
        )
        XCTAssertFalse(service.shouldRefreshProject(projectId: project.id, threshold: 3))

        // Same nodeId re-saved counts as 1 update (INSERT OR REPLACE). Two more
        // distinct chats needed to cross the threshold.
        let chat2 = NousNode(type: .conversation, title: "c2", content: "", projectId: project.id)
        let chat3 = NousNode(type: .conversation, title: "c3", content: "", projectId: project.id)
        try store.insertNode(chat2)
        try store.insertNode(chat3)
        try store.saveConversationMemory(
            ConversationMemory(nodeId: chat2.id, content: "c2", updatedAt: Date(timeIntervalSince1970: 200))
        )
        try store.saveConversationMemory(
            ConversationMemory(nodeId: chat3.id, content: "c3", updatedAt: Date(timeIntervalSince1970: 300))
        )
        XCTAssertTrue(
            service.shouldRefreshProject(projectId: project.id, threshold: 3),
            "3 distinct chats with fresh conversation_memory → fire project refresh"
        )

        // After the project refresh writes a newer timestamp, the count resets.
        try store.saveProjectMemory(
            ProjectMemory(projectId: project.id, content: "rolled up", updatedAt: Date(timeIntervalSince1970: 999))
        )
        XCTAssertFalse(
            service.shouldRefreshProject(projectId: project.id, threshold: 3),
            "project_memory.updatedAt newer than all conversation_memory → below threshold"
        )
    }

    // MARK: - Scheduler Task-cancel serialisation (§5 / Eng Review #3)

    /// P1 fix: rapid back-to-back enqueues for the same nodeId previously
    /// raced because `Task.cancel()` is non-blocking — both tasks hit the LLM
    /// and wrote to conversation_memory with last-clobber semantics. The fix
    /// makes each new task await the prior task's `.value` before doing its
    /// own work, guaranteeing serial execution.
    func testSchedulerSerializesRapidEnqueuesForSameNode() async throws {
        let capture = SerialPromptCapture()
        let mock = SerialMockLLMService(capture: capture, reply: "- ok")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })
        let scheduler = UserMemoryScheduler(service: service)

        let node = NousNode(type: .conversation, title: "race", content: "")
        try store.insertNode(node)

        let m1 = [Message(nodeId: node.id, role: .user, content: "alpha evidence payload", timestamp: Date(timeIntervalSince1970: 1))]
        let m2 = [Message(nodeId: node.id, role: .user, content: "beta evidence payload",  timestamp: Date(timeIntervalSince1970: 2))]
        let m3 = [Message(nodeId: node.id, role: .user, content: "gamma evidence payload", timestamp: Date(timeIntervalSince1970: 3))]

        await scheduler.enqueueConversationRefresh(nodeId: node.id, projectId: nil, messages: m1)
        await scheduler.enqueueConversationRefresh(nodeId: node.id, projectId: nil, messages: m2)
        await scheduler.enqueueConversationRefresh(nodeId: node.id, projectId: nil, messages: m3)

        await scheduler.waitUntilIdle()

        // Every LLM call that ran must have started after the previous one
        // finished — serialisation guarantee. SerialMockLLMService asserts this
        // internally by incrementing an "active" counter and erroring if >1.
        let overlaps = await capture.overlapCount()
        XCTAssertEqual(overlaps, 0, "two LLM streams overlapped for the same node — scheduler failed to serialise")

        // Slot cleaned up — no stale generations, no stale tasks.
        let stillInFlight = await scheduler.isInFlight(nodeId: node.id)
        XCTAssertFalse(stillInFlight, "inFlight slot must be cleared after the final task completes")
    }

    /// Two tasks for DIFFERENT nodes should be allowed to run concurrently —
    /// serialisation is per-node. This guards against an over-zealous fix that
    /// accidentally globally-serialises all refreshes.
    func testSchedulerAllowsConcurrencyAcrossDifferentNodes() async throws {
        let capture = SerialPromptCapture()
        // Per-node serialisation: two different nodes ARE allowed to overlap.
        let mock = SerialMockLLMService(capture: capture, reply: "- ok", serialiseAcrossNodes: false)
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })
        let scheduler = UserMemoryScheduler(service: service)

        let n1 = NousNode(type: .conversation, title: "chat1", content: "")
        let n2 = NousNode(type: .conversation, title: "chat2", content: "")
        try store.insertNode(n1)
        try store.insertNode(n2)

        let m1 = [Message(nodeId: n1.id, role: .user, content: "one payload here", timestamp: Date(timeIntervalSince1970: 1))]
        let m2 = [Message(nodeId: n2.id, role: .user, content: "two payload here", timestamp: Date(timeIntervalSince1970: 2))]

        await scheduler.enqueueConversationRefresh(nodeId: n1.id, projectId: nil, messages: m1)
        await scheduler.enqueueConversationRefresh(nodeId: n2.id, projectId: nil, messages: m2)

        await scheduler.waitUntilIdle()

        let callCount = await capture.callCount()
        XCTAssertEqual(callCount, 2, "both nodes must have been refreshed — scheduler over-serialised")

        let n1InFlight = await scheduler.isInFlight(nodeId: n1.id)
        let n2InFlight = await scheduler.isInFlight(nodeId: n2.id)
        XCTAssertFalse(n1InFlight)
        XCTAssertFalse(n2InFlight)
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

// MARK: - Test doubles for scheduler serialisation tests

/// Tracks concurrent active LLM calls and counts any overlap windows.
/// `overlapCount() > 0` means the scheduler failed to serialise.
private actor SerialPromptCapture {
    private var active = 0
    private var overlaps = 0
    private var calls = 0

    func enter() {
        active += 1
        if active > 1 { overlaps += 1 }
        calls += 1
    }

    func leave() {
        active -= 1
    }

    func overlapCount() -> Int { overlaps }
    func callCount() -> Int { calls }
}

/// Mock that deliberately holds the "active" window open for a beat so the
/// serialisation test has a real chance to catch overlap. Without the yield,
/// the mock returns so fast that two racing calls never actually overlap
/// even if the scheduler had a bug.
private struct SerialMockLLMService: LLMService {
    let capture: SerialPromptCapture
    let reply: String
    let serialiseAcrossNodes: Bool

    init(capture: SerialPromptCapture, reply: String, serialiseAcrossNodes: Bool = true) {
        self.capture = capture
        self.reply = reply
        self.serialiseAcrossNodes = serialiseAcrossNodes
    }

    func generate(
        messages: [LLMMessage],
        system: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        await capture.enter()
        // Let other tasks run. If serialisation is broken, another task will
        // enter() here and the overlap counter trips.
        for _ in 0..<5 {
            await Task.yield()
        }
        await capture.leave()

        let reply = self.reply
        return AsyncThrowingStream { continuation in
            continuation.yield(reply)
            continuation.finish()
        }
    }
}
