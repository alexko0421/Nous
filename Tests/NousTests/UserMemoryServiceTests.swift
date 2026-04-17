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

        await service.refreshConversation(nodeId: node.id, projectId: nil, messages: messages)

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

        await service.refreshConversation(nodeId: node.id, projectId: nil, messages: messages)

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

        await service.refreshConversation(nodeId: node.id, projectId: nil, messages: messages)

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

    // MARK: - shouldRefreshProject (counter-table trigger)

    /// Service-level smoke test for the counter-based project-refresh gate.
    /// `NodeStoreTests` covers the UPSERT + cascade semantics; this one covers
    /// the threshold comparison that `UserMemoryScheduler` actually calls.
    func testShouldRefreshProjectRespectsThreshold() throws {
        let mock = MockLLMService(capture: PromptCapture(), reply: "unused")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let project = Project(title: "Threshold test")
        try store.insertProject(project)

        XCTAssertFalse(service.shouldRefreshProject(projectId: project.id, threshold: 3),
                       "0 events — below threshold")

        try store.incrementProjectRefreshCounter(projectId: project.id)
        XCTAssertFalse(service.shouldRefreshProject(projectId: project.id, threshold: 3),
                       "1 event — below threshold")

        try store.incrementProjectRefreshCounter(projectId: project.id)
        try store.incrementProjectRefreshCounter(projectId: project.id)
        XCTAssertTrue(service.shouldRefreshProject(projectId: project.id, threshold: 3),
                      "3 events — threshold met")

        try store.resetProjectRefreshCounter(projectId: project.id)
        XCTAssertFalse(service.shouldRefreshProject(projectId: project.id, threshold: 3),
                       "counter reset after project rollup — below threshold again")
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

    /// Codex #3: per-project refreshProject lock mechanism. Two refreshProject
    /// calls for the same projectId must not run concurrently — they'd each
    /// feed a snapshot of conversation_memory to the LLM and clobber each
    /// other's write. Actor isolation makes tryAcquire atomic, so the second
    /// concurrent attempt sees the lock held and skips. Different projects
    /// must not block each other, and release must make the lock reusable.
    func testProjectRefreshLockSerializesSameProjectButAllowsDifferentProjects() async throws {
        let mock = MockLLMService(capture: PromptCapture(), reply: "unused")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })
        let scheduler = UserMemoryScheduler(service: service)

        let projectA = UUID()
        let projectB = UUID()

        // First acquire for A: must succeed.
        let first = await scheduler.tryAcquireProjectLock(projectId: projectA)
        XCTAssertTrue(first, "first acquire must succeed")
        let heldAfterFirst = await scheduler.isRefreshingProject(projectId: projectA)
        XCTAssertTrue(heldAfterFirst, "lock flag must be set after acquire")

        // Second acquire for same project: must fail — lock is held.
        let second = await scheduler.tryAcquireProjectLock(projectId: projectA)
        XCTAssertFalse(second, "second concurrent acquire for same project must fail")

        // Different project: must not be blocked.
        let other = await scheduler.tryAcquireProjectLock(projectId: projectB)
        XCTAssertTrue(other, "different project must not be blocked by A's lock")

        // Release A, then re-acquire: must succeed.
        await scheduler.releaseProjectLock(projectId: projectA)
        let heldAfterRelease = await scheduler.isRefreshingProject(projectId: projectA)
        XCTAssertFalse(heldAfterRelease, "release must clear the lock flag")
        let third = await scheduler.tryAcquireProjectLock(projectId: projectA)
        XCTAssertTrue(third, "after release, same project must be re-acquirable")

        await scheduler.releaseProjectLock(projectId: projectA)
        await scheduler.releaseProjectLock(projectId: projectB)
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

        await service.refreshConversation(nodeId: node.id, projectId: nil, messages: assistantOnly)

        let prompt = await capture.prompt()
        XCTAssertNil(prompt, "LLM must not be called when there are no user turns")
        XCTAssertNil(try store.fetchConversationMemory(nodeId: node.id))
    }

    /// P0 fix from Codex adversarial /ship review (finding #6): a project
    /// with a single hot chat refreshed N times must roll up. The previous
    /// row-counting trigger confused `INSERT OR REPLACE` (one row per chat)
    /// with events and stranded single-active-chat projects at COUNT=1
    /// forever. The counter now increments per successful refresh so this
    /// case reliably fires.
    func testRefreshConversationIncrementsProjectCounterForHotChat() async throws {
        let capture = PromptCapture()
        let mock = MockLLMService(capture: capture, reply: "- staying on topic")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let project = Project(title: "Single hot chat")
        try store.insertProject(project)
        let chat = NousNode(type: .conversation, title: "hot", content: "", projectId: project.id)
        try store.insertNode(chat)

        // Three refreshes of the SAME chat. Distinctive user evidence so the
        // similarity gate doesn't drop the turn.
        for i in 1...3 {
            let messages = [
                Message(nodeId: chat.id, role: .user,
                        content: "Iteration \(i) of the same hot chat with distinctive evidence payload",
                        timestamp: Date(timeIntervalSince1970: Double(i)))
            ]
            await service.refreshConversation(nodeId: chat.id, projectId: project.id, messages: messages)
        }

        XCTAssertEqual(
            try store.readProjectRefreshCounter(projectId: project.id), 3,
            "counter must track EVENTS, not rows — single hot chat refreshed 3x must be 3"
        )
        XCTAssertTrue(
            service.shouldRefreshProject(projectId: project.id, threshold: 3),
            "threshold met — refreshProject should be allowed to fire"
        )
    }

    // MARK: - v2.2b dual-write parity

    /// v2.2b invariant: after `refreshConversation`, the saved blob and the
    /// active memory_entry must have identical content. That property is what
    /// makes v2.2c's read-path cutover a non-semantic change — we can flip
    /// consumers from blob to entry and the user-visible memory does not move.
    func testRefreshConversationDualWritesBlobAndEntry() async throws {
        let capture = PromptCapture()
        let reply = "- Alex is debugging a retain cycle in an async sequence"
        let mock = MockLLMService(capture: capture, reply: reply)
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let node = NousNode(type: .conversation, title: "Parity chat", content: "")
        try store.insertNode(node)

        let messages: [Message] = [
            Message(nodeId: node.id, role: .user,
                    content: "I have a retain cycle in my AsyncStream onTermination closure",
                    timestamp: Date(timeIntervalSince1970: 1))
        ]

        await service.refreshConversation(nodeId: node.id, projectId: nil, messages: messages)

        let blob = try store.fetchConversationMemory(nodeId: node.id)
        XCTAssertNotNil(blob, "conversation blob must be written")

        let entry = try store.fetchActiveMemoryEntry(scope: .conversation, scopeRefId: node.id)
        XCTAssertNotNil(entry, "active memory_entry must be written (dual-write)")

        XCTAssertEqual(
            entry?.content, blob?.content,
            "blob/entry content parity — v2.2c read-path cutover relies on this"
        )
        XCTAssertEqual(entry?.scope, .conversation)
        XCTAssertEqual(entry?.scopeRefId, node.id)
        XCTAssertEqual(entry?.stability, .temporary,
                       "conversation-scope entries are temporary (wipe with chat)")
        XCTAssertEqual(entry?.sourceNodeIds, [node.id],
                       "conversation entry must cite its own node as source")
    }

    /// v2.2b parity for project scope. `refreshProject` aggregates its child
    /// chats into a blob; the mirrored entry must carry that same aggregated
    /// content.
    func testRefreshProjectDualWritesBlobAndEntry() async throws {
        let capture = PromptCapture()
        let mock = MockLLMService(capture: capture, reply: "- Project-level rollup line")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let project = Project(title: "Parity project")
        try store.insertProject(project)
        let chat = NousNode(type: .conversation, title: "child", content: "", projectId: project.id)
        try store.insertNode(chat)

        // Seed a conversation blob so refreshProject has something to roll up.
        try store.saveConversationMemory(
            ConversationMemory(
                nodeId: chat.id,
                content: "- child-chat insight",
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        )

        await service.refreshProject(projectId: project.id)

        let blob = try store.fetchProjectMemory(projectId: project.id)
        XCTAssertNotNil(blob, "project blob must be written")

        let entry = try store.fetchActiveMemoryEntry(scope: .project, scopeRefId: project.id)
        XCTAssertNotNil(entry, "active project memory_entry must be written")

        XCTAssertEqual(
            entry?.content, blob?.content,
            "project blob/entry content parity"
        )
        XCTAssertEqual(entry?.stability, .stable,
                       "project-scope entries persist across chats")
    }

    /// v2.2b supersede invariant: a second refresh marks the first active
    /// entry as `superseded` with `supersededBy` pointing to the new row, and
    /// leaves exactly one active entry for the scope+ref.
    func testRefreshConversationSecondCallSupersedesFirstEntry() async throws {
        let capture1 = PromptCapture()
        let service1 = UserMemoryService(
            nodeStore: store,
            llmServiceProvider: { MockLLMService(capture: capture1, reply: "- first summary line") }
        )

        let node = NousNode(type: .conversation, title: "Supersede chat", content: "")
        try store.insertNode(node)

        let firstMessages: [Message] = [
            Message(nodeId: node.id, role: .user,
                    content: "First distinctive evidence payload about Alex's shipping cadence",
                    timestamp: Date(timeIntervalSince1970: 1))
        ]
        await service1.refreshConversation(nodeId: node.id, projectId: nil, messages: firstMessages)

        let firstEntry = try store.fetchActiveMemoryEntry(scope: .conversation, scopeRefId: node.id)
        XCTAssertNotNil(firstEntry, "first refresh must write an entry")
        let firstId = firstEntry!.id

        let capture2 = PromptCapture()
        let service2 = UserMemoryService(
            nodeStore: store,
            llmServiceProvider: { MockLLMService(capture: capture2, reply: "- second summary line") }
        )
        let secondMessages: [Message] = [
            Message(nodeId: node.id, role: .user,
                    content: "Second distinctive evidence payload covering different territory",
                    timestamp: Date(timeIntervalSince1970: 2))
        ]
        await service2.refreshConversation(nodeId: node.id, projectId: nil, messages: secondMessages)

        let secondEntry = try store.fetchActiveMemoryEntry(scope: .conversation, scopeRefId: node.id)
        XCTAssertNotNil(secondEntry, "second refresh must write a new entry")
        XCTAssertNotEqual(secondEntry?.id, firstId, "second entry must be a new row")

        let all = try store.fetchMemoryEntries()
            .filter { $0.scope == .conversation && $0.scopeRefId == node.id }
        XCTAssertEqual(all.count, 2, "supersede preserves history — both rows kept")

        let active = all.filter { $0.status == .active }
        XCTAssertEqual(active.count, 1, "exactly one active entry per scope+ref at any moment")
        XCTAssertEqual(active.first?.id, secondEntry?.id)

        let superseded = all.first { $0.id == firstId }
        XCTAssertEqual(superseded?.status, .superseded,
                       "old entry must be marked superseded, not deleted")
        XCTAssertEqual(superseded?.supersededBy, secondEntry?.id,
                       "supersededBy must point at the replacement — history chain intact")
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
