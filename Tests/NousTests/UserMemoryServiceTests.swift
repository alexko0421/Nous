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

    func testCurrentEssentialStoryBlendsBackdropProjectAndRecentThreads() throws {
        let mock = MockLLMService(capture: PromptCapture(), reply: "unused")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let project = Project(title: "Nous")
        try store.insertProject(project)

        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .global,
                kind: .identity,
                stability: .stable,
                content: "## Identity\n- Alex is a solo founder building his second brain.",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10),
                lastConfirmedAt: Date(timeIntervalSince1970: 10)
            )
        )
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .project,
                scopeRefId: project.id,
                kind: .thread,
                stability: .stable,
                content: "## Constraints\n- Cross-chat continuity is the top requirement.\n- Keep the architecture simple.",
                createdAt: Date(timeIntervalSince1970: 20),
                updatedAt: Date(timeIntervalSince1970: 20),
                lastConfirmedAt: Date(timeIntervalSince1970: 20)
            )
        )

        let current = NousNode(type: .conversation, title: "Current chat", projectId: project.id)
        try store.insertNode(current)

        let recent = NousNode(type: .conversation, title: "Funding worries")
        try store.insertNode(recent)
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .conversation,
                scopeRefId: recent.id,
                kind: .thread,
                stability: .temporary,
                content: "- Cash runway is tight right now.",
                sourceNodeIds: [recent.id],
                createdAt: Date(timeIntervalSince1970: 30),
                updatedAt: Date(timeIntervalSince1970: 30),
                lastConfirmedAt: Date(timeIntervalSince1970: 30)
            )
        )

        let story = service.currentEssentialStory(
            projectId: project.id,
            excludingConversationId: current.id
        )

        XCTAssertTrue(story?.contains("Stable backdrop: Alex is a solo founder") == true)
        XCTAssertTrue(story?.contains("Current project (Nous): Cross-chat continuity is the top requirement.") == true)
        XCTAssertTrue(story?.contains("Recent thread (Funding worries): Cash runway is tight right now.") == true)
    }

    func testCurrentEssentialStoryReturnsNilWithoutDynamicContext() throws {
        let mock = MockLLMService(capture: PromptCapture(), reply: "unused")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .global,
                kind: .identity,
                stability: .stable,
                content: "## Identity\n- Alex is a solo founder.",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10),
                lastConfirmedAt: Date(timeIntervalSince1970: 10)
            )
        )

        XCTAssertNil(
            service.currentEssentialStory(projectId: nil, excludingConversationId: nil),
            "global identity alone should not create a redundant essential-story block"
        )
    }

    func testCurrentBoundedEvidenceReturnsCompactSupportSnippets() throws {
        let mock = MockLLMService(capture: PromptCapture(), reply: "unused")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let project = Project(title: "Nous")
        try store.insertProject(project)

        let current = NousNode(type: .conversation, title: "Current chat", projectId: project.id)
        let projectSupport = NousNode(
            type: .conversation,
            title: "Architecture tradeoffs",
            projectId: project.id,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let recent = NousNode(
            type: .conversation,
            title: "Funding worries",
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        try store.insertNode(current)
        try store.insertNode(projectSupport)
        try store.insertNode(recent)

        try store.insertMessage(Message(
            nodeId: projectSupport.id,
            role: .user,
            content: String(repeating: "Project context should stay grounded in a real Alex quote. ", count: 6)
        ))
        try store.insertMessage(Message(
            nodeId: recent.id,
            role: .user,
            content: "Cash runway is tight, so continuity and trust matter more than flashy features."
        ))

        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .project,
                scopeRefId: project.id,
                kind: .thread,
                stability: .stable,
                content: "- Cross-chat continuity is the priority.",
                sourceNodeIds: [projectSupport.id],
                createdAt: Date(timeIntervalSince1970: 40),
                updatedAt: Date(timeIntervalSince1970: 40),
                lastConfirmedAt: Date(timeIntervalSince1970: 40)
            )
        )
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .conversation,
                scopeRefId: recent.id,
                kind: .thread,
                stability: .temporary,
                content: "- Cash runway is tight right now.",
                sourceNodeIds: [recent.id],
                createdAt: Date(timeIntervalSince1970: 50),
                updatedAt: Date(timeIntervalSince1970: 50),
                lastConfirmedAt: Date(timeIntervalSince1970: 50)
            )
        )

        let evidence = service.currentBoundedEvidence(
            projectId: project.id,
            excludingConversationId: current.id
        )

        XCTAssertEqual(evidence.count, 2, "project + recent thread should each contribute one bounded snippet")
        XCTAssertEqual(Set(evidence.map(\.label)), ["Project context", "Recent thread"])
        XCTAssertEqual(Set(evidence.map(\.sourceNodeId)), [projectSupport.id, recent.id])
        XCTAssertTrue(evidence.allSatisfy { $0.snippet.count <= UserMemoryService.evidenceSnippetBudget })
        XCTAssertTrue(evidence.contains { $0.snippet.contains("Cash runway is tight") })
    }

    func testCurrentBoundedEvidenceReturnsEmptyWithoutValidSources() throws {
        let mock = MockLLMService(capture: PromptCapture(), reply: "unused")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let project = Project(title: "No sources")
        try store.insertProject(project)
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .project,
                scopeRefId: project.id,
                kind: .thread,
                stability: .stable,
                content: "- This should not surface proof without a real source.",
                sourceNodeIds: [UUID()],
                createdAt: Date(),
                updatedAt: Date(),
                lastConfirmedAt: Date()
            )
        )

        XCTAssertTrue(
            service.currentBoundedEvidence(projectId: project.id).isEmpty,
            "missing source nodes should produce no evidence block"
        )
    }

    func testPromoteToGlobalSkipsUnconfirmedInference() async throws {
        let capture = PromptCapture()
        let service = UserMemoryService(
            nodeStore: store,
            llmServiceProvider: { MockLLMService(capture: capture, reply: "- Alex prefers direct feedback") }
        )

        let didPromote = await service.promoteToGlobal(
            candidate: "Alex prefers direct feedback",
            sourceNodeIds: [UUID()],
            confirmation: .unconfirmed
        )

        XCTAssertFalse(didPromote, "unconfirmed personal inference must not be saved as stable identity memory")
        XCTAssertNil(try store.fetchActiveMemoryEntry(scope: .global, scopeRefId: nil))
        let capturedPrompt = await capture.prompt()
        XCTAssertNil(capturedPrompt, "LLM should not run when the inference is still unconfirmed")
    }

    func testPromoteToGlobalPersistsConfirmedInference() async throws {
        let capture = PromptCapture()
        let reply = "- Alex prefers direct feedback"
        let service = UserMemoryService(
            nodeStore: store,
            llmServiceProvider: { MockLLMService(capture: capture, reply: reply) }
        )

        let source = NousNode(type: .conversation, title: "Feedback chat")
        try store.insertNode(source)

        let didPromote = await service.promoteToGlobal(
            candidate: reply,
            sourceNodeIds: [source.id],
            confirmation: .confirmed
        )

        XCTAssertTrue(didPromote, "explicit confirmation should allow stable identity memory")
        let entry = try store.fetchActiveMemoryEntry(scope: .global, scopeRefId: nil)
        XCTAssertEqual(entry?.content, reply)
        XCTAssertEqual(entry?.sourceNodeIds, [source.id])
        XCTAssertEqual(entry?.confidence ?? 0, 0.95, accuracy: 0.001)
        XCTAssertNotNil(entry?.lastConfirmedAt)
        let capturedPrompt = await capture.prompt()
        XCTAssertTrue(capturedPrompt?.contains(reply) == true)
    }

    func testPromoteToGlobalRejectedInferenceLeavesNoActiveStableMemory() async throws {
        let capture = PromptCapture()
        let service = UserMemoryService(
            nodeStore: store,
            llmServiceProvider: { MockLLMService(capture: capture, reply: "- unused") }
        )

        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .global,
                kind: .identity,
                stability: .stable,
                content: "- Alex prefers direct feedback",
                confidence: 0.95,
                sourceNodeIds: [UUID()],
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10),
                lastConfirmedAt: Date(timeIntervalSince1970: 10)
            )
        )

        let didPromote = await service.promoteToGlobal(
            candidate: "Alex prefers direct feedback",
            confirmation: .rejected
        )

        XCTAssertFalse(didPromote, "rejected inference must not remain an active stable identity memory")
        XCTAssertNil(try store.fetchActiveMemoryEntry(scope: .global, scopeRefId: nil))
        let rejected = try store.fetchMemoryEntries().first { $0.scope == .global }
        XCTAssertEqual(rejected?.status, .conflicted)
        XCTAssertLessThanOrEqual(rejected?.confidence ?? 1, 0.2)
        let capturedPrompt = await capture.prompt()
        XCTAssertNil(capturedPrompt, "LLM should not run for an explicit rejection")
    }

    func testCurrentGoalModelIncludesProjectGoalAndConfirmedGoalMemory() throws {
        let service = UserMemoryService(
            nodeStore: store,
            llmServiceProvider: { MockLLMService(capture: PromptCapture(), reply: "unused") }
        )

        let project = Project(title: "Nous", goal: "Ship cross-chat continuity this week")
        try store.insertProject(project)
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .project,
                scopeRefId: project.id,
                kind: .thread,
                stability: .stable,
                content: "- The top priority is shipping the memory upgrade.\n- Keep the architecture simple.",
                confidence: 0.9,
                createdAt: Date(),
                updatedAt: Date(),
                lastConfirmedAt: Date()
            )
        )

        let goals = service.currentGoalModel(projectId: project.id)

        XCTAssertTrue(goals.contains("Ship cross-chat continuity this week"))
        XCTAssertTrue(goals.contains { $0.contains("top priority is shipping the memory upgrade") })
    }

    func testCurrentUserModelIgnoresArchivedOrConflictedEntries() throws {
        let service = UserMemoryService(
            nodeStore: store,
            llmServiceProvider: { MockLLMService(capture: PromptCapture(), reply: "unused") }
        )

        let archived = MemoryEntry(
            scope: .conversation,
            scopeRefId: UUID(),
            kind: .thread,
            stability: .temporary,
            status: .archived,
            content: "- Remember everything about private family conflict forever.",
            confidence: 0.95,
            createdAt: Date(),
            updatedAt: Date(),
            lastConfirmedAt: Date()
        )
        let conflicted = MemoryEntry(
            scope: .global,
            kind: .identity,
            stability: .stable,
            status: .conflicted,
            content: "- Alex prefers aggressive confrontation.",
            confidence: 0.95,
            createdAt: Date(),
            updatedAt: Date(),
            lastConfirmedAt: Date()
        )
        try store.insertMemoryEntry(archived)
        try store.insertMemoryEntry(conflicted)

        let model = service.currentUserModel(projectId: nil, conversationId: nil)

        XCTAssertNil(model, "archived/conflicted rows should not pollute the derived current user model")
    }

    func testCurrentWorkStyleModelPrefersConfirmedOrHighConfidenceEntries() throws {
        let service = UserMemoryService(
            nodeStore: store,
            llmServiceProvider: { MockLLMService(capture: PromptCapture(), reply: "unused") }
        )

        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .global,
                kind: .identity,
                stability: .stable,
                content: "- Alex prefers direct, first-principles answers.",
                confidence: 0.95,
                createdAt: Date(),
                updatedAt: Date(),
                lastConfirmedAt: Date()
            )
        )

        let project = Project(title: "Low confidence project")
        try store.insertProject(project)
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .project,
                scopeRefId: project.id,
                kind: .thread,
                stability: .stable,
                content: "- Alex prefers lots of hand-holding and padded language.",
                confidence: 0.6,
                createdAt: Date(),
                updatedAt: Date(),
                lastConfirmedAt: nil
            )
        )

        let workStyle = service.currentWorkStyleModel(projectId: project.id)

        XCTAssertTrue(workStyle.contains("Alex prefers direct, first-principles answers."))
        XCTAssertFalse(workStyle.contains { $0.contains("hand-holding") })
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
        XCTAssertEqual(callCount, 4,
                       "each node should run one summary call plus one fact-extraction call — scheduler over-serialised or skipped work")

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

    // MARK: - v2.2d entry-only write

    /// v2.2d: `refreshConversation` writes ONLY to memory_entries. The v2.1
    /// conversation_memory blob is frozen at its migration snapshot and must
    /// not be updated. If this test ever sees a blob row after a fresh
    /// refresh, v2.2d's single-write invariant broke.
    func testRefreshConversationWritesEntryOnly() async throws {
        let capture = PromptCapture()
        let reply = "- Alex is debugging a retain cycle in an async sequence"
        let mock = MockLLMService(capture: capture, reply: reply)
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let node = NousNode(type: .conversation, title: "Entry-only chat", content: "")
        try store.insertNode(node)

        let messages: [Message] = [
            Message(nodeId: node.id, role: .user,
                    content: "I have a retain cycle in my AsyncStream onTermination closure",
                    timestamp: Date(timeIntervalSince1970: 1))
        ]

        await service.refreshConversation(nodeId: node.id, projectId: nil, messages: messages)

        let blob = try store.fetchConversationMemory(nodeId: node.id)
        XCTAssertNil(blob, "v2.2d: conversation_memory blob must NOT be written — entries only")

        let entry = try store.fetchActiveMemoryEntry(scope: .conversation, scopeRefId: node.id)
        XCTAssertNotNil(entry, "active memory_entry must be written")
        XCTAssertEqual(entry?.content, reply)
        XCTAssertEqual(entry?.scope, .conversation)
        XCTAssertEqual(entry?.scopeRefId, node.id)
        XCTAssertEqual(entry?.stability, .temporary)
        XCTAssertEqual(entry?.sourceNodeIds, [node.id])
    }

    func testRefreshConversationExtractsContradictionFactsIntoSidecarTable() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- Alex is aligning retrieval work to contradiction recall",
                """
                [
                  {"kind":"decision","content":"Do not turn this into a full retrieval rewrite.","confidence":0.91},
                  {"kind":"boundary","content":"Do not auto-commit code without approval.","confidence":0.88},
                  {"kind":"constraint","content":"Cash runway is tight.","confidence":0.77},
                  {"kind":"identity","content":"Alex is a solo founder.","confidence":0.99}
                ]
                """
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let node = NousNode(type: .conversation, title: "Fact extraction chat", content: "")
        try store.insertNode(node)

        let assistantTurn = "You should just rewrite the whole retrieval stack."
        let userTurn = "No. Do not turn this into a full retrieval rewrite. Cash runway is tight, and do not auto-commit code without approval."
        let messages: [Message] = [
            Message(nodeId: node.id, role: .assistant, content: assistantTurn,
                    timestamp: Date(timeIntervalSince1970: 1)),
            Message(nodeId: node.id, role: .user, content: userTurn,
                    timestamp: Date(timeIntervalSince1970: 2))
        ]

        await service.refreshConversation(nodeId: node.id, projectId: nil, messages: messages)

        let facts = try store.fetchActiveMemoryFactEntries(
            scope: .conversation,
            scopeRefId: node.id,
            kinds: [.decision, .boundary, .constraint]
        ).sorted { $0.kind.rawValue < $1.kind.rawValue }

        XCTAssertEqual(facts.count, 3, "only contradiction-oriented fact kinds should be persisted")
        XCTAssertEqual(facts.map(\.kind), [.boundary, .constraint, .decision])
        XCTAssertEqual(Set(facts.map(\.content)), Set([
            "Do not turn this into a full retrieval rewrite.",
            "Do not auto-commit code without approval.",
            "Cash runway is tight."
        ]))
        XCTAssertTrue(facts.allSatisfy { $0.scope == .conversation && $0.scopeRefId == node.id })
        XCTAssertTrue(facts.allSatisfy { $0.stability == .stable })
        XCTAssertTrue(facts.allSatisfy { $0.sourceNodeIds == [node.id] })

        let prompts = await capture.prompts()
        XCTAssertEqual(prompts.count, 2, "conversation refresh should make one summary call and one fact-extraction call")
        XCTAssertFalse(prompts[1].contains(assistantTurn),
                       "fact extraction must keep using Alex-only evidence")
        XCTAssertTrue(prompts[1].contains("ALEX ONLY"))
        XCTAssertTrue(prompts[1].contains(userTurn))
    }

    func testRefreshConversationInvalidFactJSONFailsClosed() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- Alex is narrowing scope to contradiction substrate",
                "```json\nnot actually valid json\n```"
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let node = NousNode(type: .conversation, title: "Invalid fact JSON", content: "")
        try store.insertNode(node)

        let messages: [Message] = [
            Message(nodeId: node.id, role: .user,
                    content: "Keep this tight and contradiction-oriented.",
                    timestamp: Date(timeIntervalSince1970: 1))
        ]

        await service.refreshConversation(nodeId: node.id, projectId: nil, messages: messages)

        let entry = try store.fetchActiveMemoryEntry(scope: .conversation, scopeRefId: node.id)
        XCTAssertEqual(entry?.content, "- Alex is narrowing scope to contradiction substrate",
                       "canonical thread memory must still write even if fact extraction fails")
        XCTAssertTrue(try store.fetchMemoryFactEntries().isEmpty,
                      "invalid fact JSON must fail closed and leave sidecar facts untouched")
    }

    func testRefreshConversationSecondFactExtractionArchivesPriorActiveFacts() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- first thread summary",
                """
                [
                  {"kind":"decision","content":"Do not compete on price.","confidence":0.80}
                ]
                """,
                "- second thread summary",
                """
                [
                  {"kind":"boundary","content":"Do not auto-commit code without approval.","confidence":0.92}
                ]
                """
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let node = NousNode(type: .conversation, title: "Archive old facts", content: "")
        try store.insertNode(node)

        await service.refreshConversation(
            nodeId: node.id,
            projectId: nil,
            messages: [
                Message(nodeId: node.id, role: .user,
                        content: "We should not compete on price.",
                        timestamp: Date(timeIntervalSince1970: 1))
            ]
        )

        await service.refreshConversation(
            nodeId: node.id,
            projectId: nil,
            messages: [
                Message(nodeId: node.id, role: .user,
                        content: "Also, do not auto-commit code without approval.",
                        timestamp: Date(timeIntervalSince1970: 2))
            ]
        )

        let allFacts = try store.fetchMemoryFactEntries()
            .filter { $0.scope == .conversation && $0.scopeRefId == node.id }
        XCTAssertEqual(allFacts.count, 2, "history should keep old fact rows instead of mutating in place")

        let active = allFacts.filter { $0.status == .active }
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.kind, .boundary)

        let archived = allFacts.filter { $0.status == .archived }
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(archived.first?.kind, .decision)
    }

    /// v2.2d: `refreshProject` aggregates child conversation ENTRIES (not the
    /// frozen v2.1 blobs) and writes the rollup ONLY to memory_entries. Seed
    /// a conversation entry so the aggregator has something to roll up.
    func testRefreshProjectAggregatesChildEntriesAndWritesEntryOnly() async throws {
        let capture = PromptCapture()
        let mock = MockLLMService(capture: capture, reply: "- Project-level rollup line")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let project = Project(title: "Entry-only project")
        try store.insertProject(project)
        let chat = NousNode(type: .conversation, title: "child", content: "", projectId: project.id)
        try store.insertNode(chat)

        // Seed a conversation ENTRY (not a blob) so the v2.2d aggregator
        // has something to find. If the aggregator still reads blobs, the
        // refresh becomes a no-op and entry writes won't happen.
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .conversation, scopeRefId: chat.id,
                kind: .thread, stability: .temporary,
                content: "- child-chat insight",
                sourceNodeIds: [chat.id],
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10),
                lastConfirmedAt: Date(timeIntervalSince1970: 10)
            )
        )

        await service.refreshProject(projectId: project.id)

        let blob = try store.fetchProjectMemory(projectId: project.id)
        XCTAssertNil(blob, "v2.2d: project_memory blob must NOT be written")

        let entry = try store.fetchActiveMemoryEntry(scope: .project, scopeRefId: project.id)
        XCTAssertNotNil(entry, "active project memory_entry must be written")
        XCTAssertEqual(entry?.content, "- Project-level rollup line")
        XCTAssertEqual(entry?.stability, .stable)
        XCTAssertEqual(entry?.sourceNodeIds, [chat.id], "project rollup should keep source chat ids for evidence recall")
    }

    func testRefreshProjectRollsUpConversationFactsIntoProjectFacts() async throws {
        let mock = MockLLMService(capture: PromptCapture(), reply: "- Project-level summary")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let project = Project(title: "Project fact roll-up")
        try store.insertProject(project)
        let chatA = NousNode(type: .conversation, title: "chat-a", content: "", projectId: project.id)
        let chatB = NousNode(type: .conversation, title: "chat-b", content: "", projectId: project.id)
        try store.insertNode(chatA)
        try store.insertNode(chatB)

        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .conversation,
                scopeRefId: chatA.id,
                kind: .thread,
                stability: .temporary,
                content: "- chat a summary",
                sourceNodeIds: [chatA.id],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1),
                lastConfirmedAt: Date(timeIntervalSince1970: 1)
            )
        )
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .conversation,
                scopeRefId: chatB.id,
                kind: .thread,
                stability: .temporary,
                content: "- chat b summary",
                sourceNodeIds: [chatB.id],
                createdAt: Date(timeIntervalSince1970: 2),
                updatedAt: Date(timeIntervalSince1970: 2),
                lastConfirmedAt: Date(timeIntervalSince1970: 2)
            )
        )

        try store.insertMemoryFactEntry(
            MemoryFactEntry(
                scope: .conversation,
                scopeRefId: chatA.id,
                kind: .decision,
                content: "Do not compete on price.",
                confidence: 0.6,
                status: .active,
                stability: .stable,
                sourceNodeIds: [chatA.id],
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        )
        try store.insertMemoryFactEntry(
            MemoryFactEntry(
                scope: .conversation,
                scopeRefId: chatB.id,
                kind: .decision,
                content: "Do not compete on price.",
                confidence: 0.9,
                status: .active,
                stability: .stable,
                sourceNodeIds: [chatB.id],
                createdAt: Date(timeIntervalSince1970: 11),
                updatedAt: Date(timeIntervalSince1970: 11)
            )
        )
        try store.insertMemoryFactEntry(
            MemoryFactEntry(
                scope: .conversation,
                scopeRefId: chatB.id,
                kind: .boundary,
                content: "Do not auto-commit code without approval.",
                confidence: 0.8,
                status: .active,
                stability: .stable,
                sourceNodeIds: [chatB.id],
                createdAt: Date(timeIntervalSince1970: 12),
                updatedAt: Date(timeIntervalSince1970: 12)
            )
        )

        await service.refreshProject(projectId: project.id)

        let projectFacts = try store.fetchActiveMemoryFactEntries(
            scope: .project,
            scopeRefId: project.id,
            kinds: [.decision, .boundary, .constraint]
        )
        XCTAssertEqual(projectFacts.count, 2, "project roll-up should dedupe identical conversation facts")

        let decision = try XCTUnwrap(projectFacts.first(where: { $0.kind == .decision }))
        XCTAssertEqual(decision.content, "Do not compete on price.")
        XCTAssertEqual(decision.confidence, 0.9, accuracy: 0.0001)
        XCTAssertEqual(Set(decision.sourceNodeIds), Set([chatA.id, chatB.id]))

        let boundary = try XCTUnwrap(projectFacts.first(where: { $0.kind == .boundary }))
        XCTAssertEqual(boundary.content, "Do not auto-commit code without approval.")
        XCTAssertEqual(boundary.sourceNodeIds, [chatB.id])
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

    // MARK: - v2.2c read-path cutover

    /// v2.2c: reads must come from the active memory_entries row, not the v2.1
    /// blob. Seeds DIVERGENT blob vs entry content — if the reader returns the
    /// blob value, this test catches it. (Production writes keep content
    /// parity; the divergence here is a test probe only.)
    func testCurrentGlobalReadsEntryNotBlob() throws {
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: {
            MockLLMService(capture: PromptCapture(), reply: "")
        })

        try store.saveGlobalMemory(GlobalMemory(content: "OLD BLOB CONTENT", updatedAt: Date()))
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .global, scopeRefId: nil,
                kind: .identity, stability: .stable,
                content: "NEW ENTRY CONTENT",
                sourceNodeIds: [],
                createdAt: Date(), updatedAt: Date(), lastConfirmedAt: Date()
            )
        )

        let read = service.currentGlobal()
        XCTAssertEqual(read, "NEW ENTRY CONTENT",
                       "v2.2c: reads must come from memory_entries, not the blob")
    }

    func testCurrentProjectReadsEntryNotBlob() throws {
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: {
            MockLLMService(capture: PromptCapture(), reply: "")
        })
        let project = Project(title: "P")
        try store.insertProject(project)

        try store.saveProjectMemory(ProjectMemory(
            projectId: project.id, content: "OLD PROJECT BLOB", updatedAt: Date()
        ))
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .project, scopeRefId: project.id,
                kind: .thread, stability: .stable,
                content: "NEW PROJECT ENTRY",
                sourceNodeIds: [],
                createdAt: Date(), updatedAt: Date(), lastConfirmedAt: Date()
            )
        )

        XCTAssertEqual(service.currentProject(projectId: project.id), "NEW PROJECT ENTRY")
    }

    func testCurrentConversationReadsEntryNotBlob() throws {
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: {
            MockLLMService(capture: PromptCapture(), reply: "")
        })
        let node = NousNode(type: .conversation, title: "C", content: "")
        try store.insertNode(node)

        try store.saveConversationMemory(ConversationMemory(
            nodeId: node.id, content: "OLD CONVO BLOB", updatedAt: Date()
        ))
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .conversation, scopeRefId: node.id,
                kind: .thread, stability: .temporary,
                content: "NEW CONVO ENTRY",
                sourceNodeIds: [node.id],
                createdAt: Date(), updatedAt: Date(), lastConfirmedAt: Date()
            )
        )

        XCTAssertEqual(service.currentConversation(nodeId: node.id), "NEW CONVO ENTRY")
    }

    /// v2.2d: fallback removed. If the entry is missing, reads return nil
    /// (not a stale blob). This test is the inverse of the v2.2c fallback
    /// test it replaces — guards against re-introducing the fallback.
    func testCurrentGlobalReturnsNilWhenEntryMissingEvenIfBlobExists() throws {
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: {
            MockLLMService(capture: PromptCapture(), reply: "")
        })

        try store.saveGlobalMemory(GlobalMemory(content: "STALE BLOB", updatedAt: Date()))
        // deliberately do NOT insert an entry

        XCTAssertNil(service.currentGlobal(),
                     "v2.2d: no entry → read returns nil, even if a stale blob exists")
    }

    /// End-to-end: after `refreshConversation` completes, `currentConversation`
    /// must surface the freshly-written memory. Guards against the dual-write
    /// and read-path drifting apart.
    func testRefreshConversationThenCurrentConversationRoundTrips() async throws {
        let capture = PromptCapture()
        let reply = "- Alex shipped v2.2c read cutover"
        let mock = MockLLMService(capture: capture, reply: reply)
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let node = NousNode(type: .conversation, title: "Round-trip", content: "")
        try store.insertNode(node)

        let messages: [Message] = [
            Message(nodeId: node.id, role: .user,
                    content: "Ship v2.2c so entry reads and blob reads stop diverging",
                    timestamp: Date(timeIntervalSince1970: 1))
        ]
        await service.refreshConversation(nodeId: node.id, projectId: nil, messages: messages)

        let read = service.currentConversation(nodeId: node.id)
        XCTAssertEqual(read, reply,
                       "write → read must round-trip — refreshConversation's content surfaces via currentConversation")
    }

    func testConfirmMemoryEntryBoostsConfidenceAndLastConfirmedAt() throws {
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: {
            MockLLMService(capture: PromptCapture(), reply: "")
        })
        let originalDate = Date(timeIntervalSince1970: 10)
        let entry = MemoryEntry(
            scope: .global,
            kind: .identity,
            stability: .stable,
            content: "Alex prefers direct answers.",
            confidence: 0.62,
            createdAt: originalDate,
            updatedAt: originalDate,
            lastConfirmedAt: originalDate
        )
        try store.insertMemoryEntry(entry)

        XCTAssertTrue(service.confirmMemoryEntry(id: entry.id))

        let updated = try store.fetchMemoryEntry(id: entry.id)
        XCTAssertNotNil(updated?.lastConfirmedAt)
        XCTAssertGreaterThanOrEqual(updated?.confidence ?? 0, 0.95)
        XCTAssertGreaterThan(updated?.updatedAt ?? originalDate, originalDate)
    }

    func testArchiveMemoryEntryRemovesEntryFromReadPath() throws {
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: {
            MockLLMService(capture: PromptCapture(), reply: "")
        })
        let project = Project(title: "Inspector")
        try store.insertProject(project)

        let entry = MemoryEntry(
            scope: .project,
            scopeRefId: project.id,
            kind: .thread,
            stability: .stable,
            content: "Cross-window continuity is a hard requirement.",
            createdAt: Date(),
            updatedAt: Date(),
            lastConfirmedAt: Date()
        )
        try store.insertMemoryEntry(entry)

        XCTAssertEqual(service.currentProject(projectId: project.id), entry.content)
        XCTAssertTrue(service.archiveMemoryEntry(id: entry.id))
        XCTAssertNil(service.currentProject(projectId: project.id))

        let updated = try store.fetchMemoryEntry(id: entry.id)
        XCTAssertEqual(updated?.status, .archived)
    }

    func testDeleteMemoryEntryRemovesEntryFromReadPath() throws {
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: {
            MockLLMService(capture: PromptCapture(), reply: "")
        })
        let entry = MemoryEntry(
            scope: .global,
            kind: .identity,
            stability: .stable,
            content: "Alex is building Nous as a second brain.",
            createdAt: Date(),
            updatedAt: Date(),
            lastConfirmedAt: Date()
        )
        try store.insertMemoryEntry(entry)

        XCTAssertEqual(service.currentGlobal(), entry.content)
        XCTAssertTrue(service.deleteMemoryEntry(id: entry.id))
        XCTAssertNil(service.currentGlobal())
        XCTAssertNil(try store.fetchMemoryEntry(id: entry.id))
    }

    func testSourceSnippetsUseLinkedSourceNodes() throws {
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: {
            MockLLMService(capture: PromptCapture(), reply: "")
        })
        let node = NousNode(
            type: .note,
            title: "Memory policy",
            content: "We should keep raw history but archive stale interpretations."
        )
        try store.insertNode(node)

        let entry = MemoryEntry(
            scope: .global,
            kind: .constraint,
            stability: .stable,
            content: "Keep raw history intact.",
            sourceNodeIds: [node.id],
            createdAt: Date(),
            updatedAt: Date(),
            lastConfirmedAt: Date()
        )
        try store.insertMemoryEntry(entry)

        let snippets = service.sourceSnippets(for: entry.id, limit: 2)
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets.first?.sourceNodeId, node.id)
        XCTAssertTrue(snippets.first?.snippet.contains("raw history") == true)
    }

    func testShouldPersistMemoryReturnsFalseWhenUserOptsOut() throws {
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: {
            MockLLMService(capture: PromptCapture(), reply: "")
        })
        let node = NousNode(type: .conversation, title: "Boundary chat", content: "")
        let messages = [
            Message(
                nodeId: node.id,
                role: .user,
                content: "This is off the record. Don't store this in memory.",
                timestamp: Date()
            )
        ]

        XCTAssertFalse(service.shouldPersistMemory(messages: messages, projectId: nil))
    }

    func testShouldPersistMemoryReturnsFalseForSensitiveContentWhenBoundaryRequiresConsent() throws {
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: {
            MockLLMService(capture: PromptCapture(), reply: "")
        })

        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .global,
                kind: .constraint,
                stability: .stable,
                content: "- Ask before storing unusually sensitive material.",
                confidence: 0.95,
                createdAt: Date(),
                updatedAt: Date(),
                lastConfirmedAt: Date()
            )
        )

        let node = NousNode(type: .conversation, title: "Sensitive chat", content: "")
        let messages = [
            Message(
                nodeId: node.id,
                role: .user,
                content: "I had a panic attack today and I do not want you to over-store this.",
                timestamp: Date()
            )
        ]

        XCTAssertFalse(service.shouldPersistMemory(messages: messages, projectId: nil))
    }

    func testRejectedInferenceIncrementsOverInferenceCounter() async throws {
        let suiteName = "UserMemoryServiceTests.overInference.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let telemetry = GovernanceTelemetryStore(defaults: defaults)
        let capture = PromptCapture()
        let mock = MockLLMService(capture: capture, reply: "- Alex is naturally conflict avoidant")
        let service = UserMemoryService(
            nodeStore: store,
            llmServiceProvider: { mock },
            governanceTelemetry: telemetry
        )

        _ = await service.promoteToGlobal(
            candidate: "Alex is conflict avoidant",
            sourceNodeIds: [UUID()],
            confirmation: .confirmed
        )
        _ = await service.promoteToGlobal(
            candidate: "Alex is conflict avoidant",
            sourceNodeIds: [UUID()],
            confirmation: .rejected
        )

        XCTAssertEqual(telemetry.value(for: .overInferenceRate), 1)
    }

    func testConfirmMemoryEntryIncrementsMemoryPrecisionCounter() throws {
        let suiteName = "UserMemoryServiceTests.memoryPrecision.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let telemetry = GovernanceTelemetryStore(defaults: defaults)
        let service = UserMemoryService(
            nodeStore: store,
            llmServiceProvider: { MockLLMService(capture: PromptCapture(), reply: "") },
            governanceTelemetry: telemetry
        )
        let entry = MemoryEntry(
            scope: .global,
            kind: .identity,
            stability: .stable,
            content: "Alex prefers first-principles reasoning.",
            createdAt: Date(),
            updatedAt: Date(),
            lastConfirmedAt: Date()
        )
        try store.insertMemoryEntry(entry)

        XCTAssertTrue(service.confirmMemoryEntry(id: entry.id))
        XCTAssertEqual(telemetry.value(for: .memoryPrecision), 1)
    }
}

// MARK: - Test doubles

private actor PromptCapture {
    private var captured: String?

    func record(_ prompt: String) { captured = prompt }
    func prompt() -> String? { captured }
}

private actor PromptSequenceCapture {
    private var captured: [String] = []

    func record(_ prompt: String) { captured.append(prompt) }
    func prompts() -> [String] { captured }
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

private actor ReplyQueue {
    private var replies: [String]

    init(replies: [String]) {
        self.replies = replies
    }

    func next() -> String {
        guard !replies.isEmpty else { return "" }
        return replies.removeFirst()
    }
}

private struct QueueMockLLMService: LLMService {
    let capture: PromptSequenceCapture
    let replies: ReplyQueue

    init(capture: PromptSequenceCapture, replies: [String]) {
        self.capture = capture
        self.replies = ReplyQueue(replies: replies)
    }

    func generate(
        messages: [LLMMessage],
        system: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        let userPrompt = messages.first(where: { $0.role == "user" })?.content ?? ""
        await capture.record(userPrompt)

        let reply = await replies.next()
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
