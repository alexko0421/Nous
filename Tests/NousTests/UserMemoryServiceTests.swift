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

    func testRefreshConversationPromptGuardsTemporalStateAndCorrections() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- Alex is waiting to send a 4am update",
                #"{"facts":[],"decision_chains":[],"semantic_atoms":[]}"#
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let node = NousNode(type: .conversation, title: "Future plan chat", content: "")
        try store.insertNode(node)

        let messages: [Message] = [
            Message(
                nodeId: node.id,
                role: .user,
                content: "I plan to sleep, wake up at 4am, then send her an update.",
                timestamp: Date(timeIntervalSince1970: 1)
            ),
            Message(
                nodeId: node.id,
                role: .user,
                content: "No, I have not sent it yet. I will only know tomorrow.",
                timestamp: Date(timeIntervalSince1970: 2)
            )
        ]

        await service.refreshConversation(nodeId: node.id, projectId: nil, messages: messages)

        let prompts = await capture.prompts()
        guard let sentPrompt = prompts.first else {
            XCTFail("QueueMockLLMService was never called")
            return
        }

        XCTAssertTrue(sentPrompt.contains("planned/future/waiting"),
                      "prompt must explicitly protect future plans from being rewritten as completed events")
        XCTAssertTrue(sentPrompt.contains("latest correction"),
                      "prompt must explicitly make Alex's latest correction override older memory")
    }

    func testRefreshConversationAddsPreviousQuestionContextForShortReplies() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- Alex confirmed the Evo SL is buyable where he is",
                #"{"facts":[],"decision_chains":[],"semantic_atoms":[]}"#
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let node = NousNode(type: .conversation, title: "Shoe decision", content: "")
        try store.insertNode(node)

        let assistantQuestion = "你而家系话 EVO SL 喺美国买唔买到㗎？\n\n买唔买到先？"
        let userReply = "咁梗系买到啦"
        let messages: [Message] = [
            Message(
                nodeId: node.id,
                role: .assistant,
                content: assistantQuestion,
                timestamp: Date(timeIntervalSince1970: 1)
            ),
            Message(
                nodeId: node.id,
                role: .user,
                content: userReply,
                timestamp: Date(timeIntervalSince1970: 2)
            )
        ]

        await service.refreshConversation(nodeId: node.id, projectId: nil, messages: messages)

        let prompts = await capture.prompts()
        XCTAssertGreaterThanOrEqual(prompts.count, 2)
        for prompt in prompts.prefix(2) {
            XCTAssertTrue(prompt.contains("previous_nous_question_context_only"))
            XCTAssertTrue(prompt.contains("EVO SL 喺美国买唔买到"))
            XCTAssertTrue(prompt.contains(userReply))
            XCTAssertTrue(prompt.contains("Do not treat Nous context as source evidence"))
        }
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

        let atoms = try store.fetchMemoryAtoms()
            .filter { $0.scope == .conversation && $0.scopeRefId == node.id }
            .sorted { $0.type.rawValue < $1.type.rawValue }
        XCTAssertEqual(atoms.count, 3, "fact extraction should mirror active facts into graph atoms")
        XCTAssertEqual(atoms.map(\.type), [.boundary, .constraint, .decision])
        XCTAssertEqual(Set(atoms.map(\.statement)), Set([
            "Do not turn this into a full retrieval rewrite.",
            "Do not auto-commit code without approval.",
            "Cash runway is tight."
        ]))
        XCTAssertTrue(atoms.allSatisfy { $0.status == .active && $0.sourceNodeId == node.id })
        XCTAssertTrue(atoms.allSatisfy { $0.normalizedKey != nil })

        let prompts = await capture.prompts()
        XCTAssertEqual(prompts.count, 2, "conversation refresh should make one summary call and one fact-extraction call")
        XCTAssertFalse(prompts[1].contains(assistantTurn),
                       "fact extraction must keep using Alex-only evidence")
        XCTAssertTrue(prompts[1].contains("ALEX ONLY"))
        XCTAssertTrue(prompts[1].contains(userTurn))
    }

    func testRefreshConversationRedactsHardOptOutEvidenceBeforeSynthesis() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                """
                - Alex is testing whether Nous will remember 蓝色火车.
                - If Alex explicitly says not to remember something, Nous should respect that boundary.
                """,
                """
                {
                  "facts": [
                    {"kind":"boundary","content":"Do not store 'blue train' (蓝色火车) toy name as durable memory.","confidence":0.98},
                    {"kind":"boundary","content":"When Alex explicitly says not to remember something, respect that instruction and do not retain the specific content beyond the conversation.","confidence":0.97}
                  ],
                  "decision_chains": [],
                  "semantic_atoms": [
                    {
                      "type":"rule",
                      "statement":"Do not store 蓝色火车 as durable memory.",
                      "evidence_message_id":"00000000-0000-0000-0000-000000000000",
                      "evidence_quote":"蓝色火车",
                      "confidence":0.9
                    }
                  ]
                }
                """
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let node = NousNode(type: .conversation, title: "Boundary redaction chat", content: "")
        try store.insertNode(node)

        let forbiddenTurn = Message(
            nodeId: node.id,
            role: .user,
            content: "我今晚放一个测试细节：我小时候给一个玩具起名叫蓝色火车。这件事不要记住，只在这个 conversation 里处理。",
            timestamp: Date(timeIntervalSince1970: 1)
        )
        let allowedBoundaryTurn = Message(
            nodeId: node.id,
            role: .user,
            content: "可以记住的是这条边界：如果我明确说不要记，你要尊重，不要保留具体内容。",
            timestamp: Date(timeIntervalSince1970: 2)
        )

        await service.refreshConversation(
            nodeId: node.id,
            projectId: nil,
            messages: [forbiddenTurn, allowedBoundaryTurn]
        )

        let prompts = await capture.prompts()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertFalse(prompts[0].contains("蓝色火车"), "thread synthesis prompt must not expose forbidden content")
        XCTAssertFalse(prompts[1].contains("蓝色火车"), "fact extraction prompt must not expose forbidden content")
        XCTAssertTrue(prompts[0].contains("intentionally redacted"))
        XCTAssertTrue(prompts[1].contains("intentionally redacted"))

        let entry = try XCTUnwrap(store.fetchActiveMemoryEntry(scope: .conversation, scopeRefId: node.id))
        XCTAssertFalse(entry.content.contains("蓝色火车"), "thread memory must redact forbidden content even if the model echoes it")

        let facts = try store.fetchActiveMemoryFactEntries(
            scope: .conversation,
            scopeRefId: node.id,
            kinds: [.boundary]
        )
        XCTAssertEqual(facts.count, 1)
        XCTAssertFalse(facts.contains { $0.content.contains("蓝色火车") })
        XCTAssertTrue(facts.first?.content.contains("explicitly says not to remember") == true)

        let atoms = try store.fetchMemoryAtoms()
        XCTAssertFalse(atoms.contains { $0.statement.contains("蓝色火车") })
    }

    func testRefreshConversationKeepsUnchangedFactActiveWithoutArchivedDuplicates() async throws {
        let capture = PromptSequenceCapture()
        let factPayload = """
        {
          "facts": [
            {"kind":"boundary","content":"When Alex explicitly says not to remember something, respect that instruction and do not retain the specific content beyond the conversation.","confidence":0.97}
          ],
          "decision_chains": [],
          "semantic_atoms": []
        }
        """
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- first summary",
                factPayload,
                "- second summary",
                factPayload
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let node = NousNode(type: .conversation, title: "Fact duplicate chat", content: "")
        try store.insertNode(node)

        let message = Message(
            nodeId: node.id,
            role: .user,
            content: "If I explicitly say not to remember something, respect that boundary and do not keep the specific content.",
            timestamp: Date(timeIntervalSince1970: 1)
        )

        await service.refreshConversation(nodeId: node.id, projectId: nil, messages: [message])
        await service.refreshConversation(nodeId: node.id, projectId: nil, messages: [message])

        let allFacts = try store.fetchMemoryFactEntries()
            .filter { $0.scope == .conversation && $0.scopeRefId == node.id }
        XCTAssertEqual(allFacts.count, 1, "unchanged facts should update in place, not create archived duplicate rows")
        XCTAssertEqual(allFacts.first?.status, .active)

        let atoms = try store.fetchMemoryAtoms()
            .filter { $0.scope == .conversation && $0.scopeRefId == node.id }
        XCTAssertEqual(atoms.count, 1, "unchanged fact atoms should upsert in place")
        XCTAssertEqual(atoms.first?.status, .active)
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
        XCTAssertTrue(try store.fetchMemoryAtoms().isEmpty,
                      "invalid fact JSON must fail closed and leave graph atoms untouched")
    }

    func testRefreshConversationExtractsDecisionChainsIntoGraphRecall() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- Alex rejected solving emotions as the product frame",
                """
                {
                  "facts": [
                    {"kind":"decision","content":"Do not frame the product as solving emotions.","confidence":0.91}
                  ],
                  "decision_chains": [
                    {
                      "rejected_proposal":"Build Nous around solving emotions.",
                      "rejection":"Alex rejected solving emotions as unrealistic.",
                      "reasons":["Emotions cannot be solved like a mechanical problem."],
                      "replacement":"Observe and coexist with emotions.",
                      "evidence_quote":"We should not build this as solving emotions. It is unrealistic.",
                      "confidence":0.89
                    }
                  ]
                }
                """
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let oldChat = NousNode(type: .conversation, title: "Emotion product framing", content: "")
        try store.insertNode(oldChat)
        let userMessage = Message(
            nodeId: oldChat.id,
            role: .user,
            content: "We should not build this as solving emotions. It is unrealistic. The better frame is observing and coexisting with emotions.",
            timestamp: Date(timeIntervalSince1970: 1)
        )
        try store.insertMessage(userMessage)

        await service.refreshConversation(
            nodeId: oldChat.id,
            projectId: nil,
            messages: [userMessage]
        )

        let graphStore = MemoryGraphStore(nodeStore: store)
        let rejection = try XCTUnwrap(
            try store.fetchMemoryAtoms()
                .first { $0.type == .rejection && $0.status == .active }
        )
        let chain = try XCTUnwrap(graphStore.decisionChain(for: rejection.id))
        XCTAssertEqual(chain.rejectedProposal?.statement, "Build Nous around solving emotions.")
        XCTAssertEqual(chain.reasons.map(\.statement), ["Emotions cannot be solved like a mechanical problem."])
        XCTAssertEqual(chain.replacement?.statement, "Observe and coexist with emotions.")
        XCTAssertEqual(rejection.sourceNodeId, oldChat.id)
        XCTAssertEqual(rejection.eventTime, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(rejection.sourceMessageId, userMessage.id)

        let newChatId = UUID()
        let recall = service.currentDecisionGraphRecall(
            currentMessage: "我哋三周前否決過邊個方案，點解？",
            projectId: nil,
            conversationId: newChatId,
            now: Date(timeIntervalSince1970: 1 + 21 * 24 * 60 * 60)
        )

        XCTAssertEqual(recall.count, 1)
        XCTAssertTrue(recall[0].contains("Build Nous around solving emotions."))
        XCTAssertTrue(recall[0].contains("Emotions cannot be solved like a mechanical problem."))
        XCTAssertTrue(recall[0].contains("Observe and coexist with emotions."))
        XCTAssertTrue(recall[0].contains("status=active"))
        XCTAssertTrue(recall[0].contains("source_message_id="))
        XCTAssertTrue(recall[0].contains("event_time=1970-01-01T00:00:01Z"))
    }

    /// Live-path integration: a prior `currentPosition` Alex held in this chat
    /// must end up `superseded` (with a `supersedes` edge) once
    /// `refreshConversation` extracts a decision chain rejecting the same
    /// position. Without this, the audit's exact "fake memory" failure
    /// reappears at the integration layer: pre-existing position stays as
    /// just `archived` next to the new rejection, and recall has no way to
    /// answer "when did I change my mind?".
    func testRefreshConversationSupersedesPriorMatchingCurrentPositionInGraph() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- Alex changed his framing of emotions",
                """
                {
                  "facts": [],
                  "decision_chains": [
                    {
                      "rejected_proposal":"Solve emotions",
                      "rejection":"Alex now rejects solving emotions as a frame.",
                      "reasons":["Emotions are not solvable like a mechanical problem."],
                      "replacement":"Observe and coexist with emotions.",
                      "evidence_quote":"I no longer want to frame this as solving emotions.",
                      "confidence":0.9
                    }
                  ]
                }
                """
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let chat = NousNode(type: .conversation, title: "Emotion frame shift", content: "")
        try store.insertNode(chat)
        let message = Message(
            nodeId: chat.id,
            role: .user,
            content: "I no longer want to frame this as solving emotions. Observing and coexisting fits better.",
            timestamp: Date(timeIntervalSince1970: 1)
        )
        try store.insertMessage(message)

        // Pre-existing currentPosition that the new chain will reject.
        let priorPosition = MemoryAtom(
            type: .currentPosition,
            statement: "Solve emotions",
            normalizedKey: "current_position|solve emotions",
            scope: .conversation,
            scopeRefId: chat.id,
            status: .active,
            confidence: 0.85,
            eventTime: Date(timeIntervalSince1970: 0),
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            sourceNodeId: chat.id
        )
        try store.insertMemoryAtom(priorPosition)

        await service.refreshConversation(
            nodeId: chat.id,
            projectId: nil,
            messages: [message]
        )

        let updatedPrior = try XCTUnwrap(store.fetchMemoryAtom(id: priorPosition.id))
        XCTAssertEqual(
            updatedPrior.status,
            .superseded,
            "Prior currentPosition must be flagged superseded after the live extractor produces a chain that rejects it."
        )

        let supersedesEdges = try store.fetchMemoryEdges()
            .filter { $0.type == .supersedes && $0.toAtomId == priorPosition.id }
        XCTAssertEqual(
            supersedesEdges.count,
            1,
            "Exactly one supersedes edge must point at the prior atom."
        )
        let edge = try XCTUnwrap(supersedesEdges.first)
        let fromAtom = try XCTUnwrap(store.fetchMemoryAtom(id: edge.fromAtomId))
        XCTAssertEqual(fromAtom.type, .rejection)
        XCTAssertTrue(
            fromAtom.statement.contains("solving emotions"),
            "Edge source should be the new rejection atom from the chain."
        )
    }

    /// Live extractor must produce `preference` / `belief` / `correction`
    /// atoms with full provenance so the planner's preferenceRecall /
    /// ruleRecall / contradictionReview intents finally have data to return.
    /// Each atom requires `evidence_quote` matching the source message — same
    /// hallucination guard as decision chains. Without these, planner intents
    /// covering the 3 most common recall surfaces stay forever empty.
    func testRefreshConversationExtractsSemanticAtomsWithProvenance() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- Alex stated three durable preferences/beliefs.",
                """
                {
                  "facts": [],
                  "decision_chains": [],
                  "semantic_atoms": [
                    {
                      "type": "preference",
                      "statement": "Alex never wants em dashes in final copy.",
                      "evidence_quote": "Remember that I never want em dashes in final copy.",
                      "confidence": 0.92
                    },
                    {
                      "type": "belief",
                      "statement": "Alex believes naming products precisely is more important than naming them quickly.",
                      "evidence_quote": "I think naming products precisely matters more than shipping a name fast.",
                      "confidence": 0.84
                    },
                    {
                      "type": "correction",
                      "statement": "Alex no longer trusts the original wow-curve framing of onboarding.",
                      "evidence_quote": "I was wrong earlier; the wow-curve framing of onboarding does not hold up for me anymore.",
                      "confidence": 0.78
                    }
                  ]
                }
                """
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let chat = NousNode(type: .conversation, title: "Stable preferences", content: "")
        try store.insertNode(chat)
        let userMessage = Message(
            nodeId: chat.id,
            role: .user,
            content: """
            Remember that I never want em dashes in final copy. \
            I think naming products precisely matters more than shipping a name fast. \
            I was wrong earlier; the wow-curve framing of onboarding does not hold up for me anymore.
            """,
            timestamp: Date(timeIntervalSince1970: 5)
        )
        try store.insertMessage(userMessage)

        await service.refreshConversation(nodeId: chat.id, projectId: nil, messages: [userMessage])

        let atoms = try store.fetchMemoryAtoms()
        let preference = try XCTUnwrap(atoms.first(where: { $0.type == .preference }))
        XCTAssertEqual(preference.statement, "Alex never wants em dashes in final copy.")
        XCTAssertEqual(preference.sourceMessageId, userMessage.id)
        XCTAssertEqual(preference.eventTime, userMessage.timestamp)
        XCTAssertEqual(preference.status, .active)

        let belief = try XCTUnwrap(atoms.first(where: { $0.type == .belief }))
        XCTAssertEqual(belief.statement, "Alex believes naming products precisely is more important than naming them quickly.")
        XCTAssertEqual(belief.sourceMessageId, userMessage.id)

        let correction = try XCTUnwrap(atoms.first(where: { $0.type == .correction }))
        XCTAssertEqual(correction.statement, "Alex no longer trusts the original wow-curve framing of onboarding.")
        XCTAssertEqual(correction.sourceMessageId, userMessage.id)
    }

    /// Semantic atoms (preference/belief/correction) must NOT use the
    /// burn-and-replace lifecycle that decision chains use. If they did, a
    /// stable preference Alex stated in turn N would be archived in turn N+1
    /// just because that turn's extraction didn't re-mention it. This test
    /// pins the survival contract: a prior preference atom stays `.active`
    /// across an unrelated refresh cycle.
    func testSemanticAtomsSurviveLaterUnrelatedRefresh() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- Different topic entirely",
                """
                {
                  "facts": [],
                  "decision_chains": [],
                  "semantic_atoms": []
                }
                """
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let chat = NousNode(type: .conversation, title: "Survival test", content: "")
        try store.insertNode(chat)
        let userMessage = Message(
            nodeId: chat.id,
            role: .user,
            content: "Today's chat is about something else entirely.",
            timestamp: Date(timeIntervalSince1970: 10)
        )
        try store.insertMessage(userMessage)

        let priorPreference = MemoryAtom(
            type: .preference,
            statement: "Alex never wants em dashes in final copy.",
            normalizedKey: "preference|alex never wants em dashes in final copy.",
            scope: .conversation,
            scopeRefId: chat.id,
            status: .active,
            confidence: 0.92,
            eventTime: Date(timeIntervalSince1970: 1),
            sourceNodeId: chat.id
        )
        try store.insertMemoryAtom(priorPreference)

        await service.refreshConversation(nodeId: chat.id, projectId: nil, messages: [userMessage])

        let updated = try XCTUnwrap(store.fetchMemoryAtom(id: priorPreference.id))
        XCTAssertEqual(
            updated.status,
            .active,
            "Stable semantic atoms must survive refresh cycles that don't re-extract them."
        )
    }

    /// Semantic atom upsert: re-extracting the same preference must update
    /// the existing atom (bump lastSeenAt) instead of inserting a duplicate.
    /// Same normalized-key contract as decision chain atoms — without it,
    /// stable preferences would multiply across turns.
    func testSemanticAtomsAreUpsertedByNormalizedKey() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- Alex restates a known preference.",
                """
                {
                  "facts": [],
                  "decision_chains": [],
                  "semantic_atoms": [
                    {
                      "type": "preference",
                      "statement": "Alex never wants em dashes in final copy.",
                      "evidence_quote": "Again — never em dashes in final copy.",
                      "confidence": 0.95
                    }
                  ]
                }
                """
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let chat = NousNode(type: .conversation, title: "Upsert test", content: "")
        try store.insertNode(chat)
        let userMessage = Message(
            nodeId: chat.id,
            role: .user,
            content: "Again — never em dashes in final copy.",
            timestamp: Date(timeIntervalSince1970: 50)
        )
        try store.insertMessage(userMessage)

        let priorPreference = MemoryAtom(
            type: .preference,
            statement: "Alex never wants em dashes in final copy.",
            normalizedKey: "preference|alex never wants em dashes in final copy.",
            scope: .conversation,
            scopeRefId: chat.id,
            status: .active,
            confidence: 0.7,
            eventTime: Date(timeIntervalSince1970: 1),
            sourceNodeId: chat.id
        )
        try store.insertMemoryAtom(priorPreference)

        await service.refreshConversation(nodeId: chat.id, projectId: nil, messages: [userMessage])

        let preferenceAtoms = try store.fetchMemoryAtoms().filter {
            $0.type == .preference && $0.scopeRefId == chat.id
        }
        XCTAssertEqual(preferenceAtoms.count, 1, "Re-extracted preference must upsert in place.")
        let merged = preferenceAtoms[0]
        XCTAssertEqual(merged.id, priorPreference.id, "Upsert must reuse the existing atom id.")
        XCTAssertGreaterThanOrEqual(merged.confidence, 0.92, "Upsert must take max confidence between old and new.")
    }

    /// Live-path integration: when the extractor produces a `correction`
    /// semantic atom that names a `corrects` target text, a prior `belief`
    /// (or `preference`) atom in the same scope whose normalized statement
    /// matches must end up `superseded` with a `supersedes` edge from the
    /// new correction to it. Without this, "I no longer think X" coexists
    /// as just another active atom alongside the original X — recall has
    /// no way to answer "when did Alex change his mind about X?".
    func testRefreshConversationCorrectionSupersedesPriorMatchingBelief() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- Alex retracted a prior belief.",
                """
                {
                  "facts": [],
                  "decision_chains": [],
                  "semantic_atoms": [
                    {
                      "type": "correction",
                      "statement": "Alex no longer trusts the wow-curve framing of onboarding.",
                      "corrects": "Wow-curve framing of onboarding holds up.",
                      "evidence_quote": "I was wrong about the wow-curve framing.",
                      "confidence": 0.86
                    }
                  ]
                }
                """
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let chat = NousNode(type: .conversation, title: "Belief shift", content: "")
        try store.insertNode(chat)
        let userMessage = Message(
            nodeId: chat.id,
            role: .user,
            content: "I was wrong about the wow-curve framing. It does not actually hold up.",
            timestamp: Date(timeIntervalSince1970: 50)
        )
        try store.insertMessage(userMessage)

        let priorBelief = MemoryAtom(
            type: .belief,
            statement: "Wow-curve framing of onboarding holds up.",
            normalizedKey: "belief|wow-curve framing of onboarding holds up.",
            scope: .conversation,
            scopeRefId: chat.id,
            status: .active,
            confidence: 0.8,
            eventTime: Date(timeIntervalSince1970: 1),
            sourceNodeId: chat.id
        )
        try store.insertMemoryAtom(priorBelief)

        await service.refreshConversation(nodeId: chat.id, projectId: nil, messages: [userMessage])

        let updated = try XCTUnwrap(store.fetchMemoryAtom(id: priorBelief.id))
        XCTAssertEqual(
            updated.status,
            .superseded,
            "Prior belief must be flagged superseded after the live extractor produces a correction targeting it."
        )

        let supersedesEdges = try store.fetchMemoryEdges()
            .filter { $0.type == .supersedes && $0.toAtomId == priorBelief.id }
        XCTAssertEqual(supersedesEdges.count, 1)
        let edge = try XCTUnwrap(supersedesEdges.first)
        let fromAtom = try XCTUnwrap(store.fetchMemoryAtom(id: edge.fromAtomId))
        XCTAssertEqual(fromAtom.type, .correction)
    }

    /// Without a `corrects` target text, a `correction` atom must NOT silently
    /// supersede unrelated active beliefs in the same scope just because they
    /// share keywords. The supersede flow is opt-in via the `corrects` field;
    /// otherwise the correction is just a freestanding claim.
    func testRefreshConversationCorrectionWithoutCorrectsTargetLeavesPriorBeliefAlone() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- Generic correction without a target.",
                """
                {
                  "facts": [],
                  "decision_chains": [],
                  "semantic_atoms": [
                    {
                      "type": "correction",
                      "statement": "Alex revised his thinking on framing in general.",
                      "evidence_quote": "I have been revising my thinking on framing in general.",
                      "confidence": 0.65
                    }
                  ]
                }
                """
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let chat = NousNode(type: .conversation, title: "Generic correction", content: "")
        try store.insertNode(chat)
        let userMessage = Message(
            nodeId: chat.id,
            role: .user,
            content: "I have been revising my thinking on framing in general.",
            timestamp: Date(timeIntervalSince1970: 50)
        )
        try store.insertMessage(userMessage)

        let priorBelief = MemoryAtom(
            type: .belief,
            statement: "Wow-curve framing of onboarding holds up.",
            normalizedKey: "belief|wow-curve framing of onboarding holds up.",
            scope: .conversation,
            scopeRefId: chat.id,
            status: .active,
            confidence: 0.8,
            eventTime: Date(timeIntervalSince1970: 1),
            sourceNodeId: chat.id
        )
        try store.insertMemoryAtom(priorBelief)

        await service.refreshConversation(nodeId: chat.id, projectId: nil, messages: [userMessage])

        let untouched = try XCTUnwrap(store.fetchMemoryAtom(id: priorBelief.id))
        XCTAssertEqual(untouched.status, .active)
        let supersedesEdges = try store.fetchMemoryEdges().filter { $0.type == .supersedes }
        XCTAssertTrue(supersedesEdges.isEmpty)
    }

    /// Live extractor must also produce `goal` / `plan` / `rule` / `pattern`
    /// atoms (same upsert-only lifecycle as preference/belief/correction).
    /// Without these, planner intents `goalPlanRecall` and `ruleRecall` stay
    /// permanently empty even though they're already wired through the
    /// retrieval path. Pattern atoms specifically unlock "what do I keep
    /// catching myself doing?" recall — a different surface from beliefs.
    func testRefreshConversationExtractsGoalPlanRuleAndPatternAtoms() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- Alex stated four durable artefacts.",
                """
                {
                  "facts": [],
                  "decision_chains": [],
                  "semantic_atoms": [
                    {
                      "type": "goal",
                      "statement": "Alex wants Nous to feel like a real second brain by Q3.",
                      "evidence_quote": "I want Nous to feel like a real second brain by Q3.",
                      "confidence": 0.9
                    },
                    {
                      "type": "plan",
                      "statement": "Alex plans to ship the Memory Center before adding new agents.",
                      "evidence_quote": "I plan to ship the Memory Center before adding any new agents.",
                      "confidence": 0.85
                    },
                    {
                      "type": "rule",
                      "statement": "Alex writes failing tests before implementation.",
                      "evidence_quote": "Always write the failing test before implementation.",
                      "confidence": 0.88
                    },
                    {
                      "type": "pattern",
                      "statement": "Alex repeatedly underestimates the cost of cross-team coordination.",
                      "evidence_quote": "I keep underestimating how much cross-team coordination costs.",
                      "confidence": 0.78
                    }
                  ]
                }
                """
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let chat = NousNode(type: .conversation, title: "Goals and patterns", content: "")
        try store.insertNode(chat)
        let userMessage = Message(
            nodeId: chat.id,
            role: .user,
            content: """
            I want Nous to feel like a real second brain by Q3. \
            I plan to ship the Memory Center before adding any new agents. \
            Always write the failing test before implementation. \
            I keep underestimating how much cross-team coordination costs.
            """,
            timestamp: Date(timeIntervalSince1970: 12)
        )
        try store.insertMessage(userMessage)

        await service.refreshConversation(nodeId: chat.id, projectId: nil, messages: [userMessage])

        let atoms = try store.fetchMemoryAtoms()
        let goal = try XCTUnwrap(atoms.first(where: { $0.type == .goal }))
        XCTAssertEqual(goal.sourceMessageId, userMessage.id)
        XCTAssertEqual(goal.eventTime, userMessage.timestamp)
        XCTAssertEqual(goal.status, .active)

        let plan = try XCTUnwrap(atoms.first(where: { $0.type == .plan }))
        XCTAssertTrue(plan.statement.contains("Memory Center"))
        XCTAssertEqual(plan.sourceMessageId, userMessage.id)

        let rule = try XCTUnwrap(atoms.first(where: { $0.type == .rule }))
        XCTAssertTrue(rule.statement.contains("failing tests"))
        XCTAssertEqual(rule.sourceMessageId, userMessage.id)

        let pattern = try XCTUnwrap(atoms.first(where: { $0.type == .pattern }))
        XCTAssertTrue(pattern.statement.contains("cross-team coordination"))
        XCTAssertEqual(pattern.sourceMessageId, userMessage.id)
    }

    /// Corrections must be able to retract a prior goal / plan / rule the
    /// same way they can retract a belief or preference. Otherwise Alex's
    /// abandoned plans remain "active" forever and recall still surfaces
    /// them as live commitments. Pattern atoms are intentionally NOT
    /// supersedable — patterns describe self-observation, not commitment;
    /// they fade by absence, not by retraction.
    func testRefreshConversationCorrectionCanSupersedePriorPlan() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- Alex retracted a prior plan.",
                """
                {
                  "facts": [],
                  "decision_chains": [],
                  "semantic_atoms": [
                    {
                      "type": "correction",
                      "statement": "Alex no longer plans to ship the Memory Center first.",
                      "corrects": "Alex plans to ship the Memory Center before adding new agents.",
                      "evidence_quote": "I am dropping the Memory Center first plan.",
                      "confidence": 0.84
                    }
                  ]
                }
                """
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let chat = NousNode(type: .conversation, title: "Plan shift", content: "")
        try store.insertNode(chat)
        let userMessage = Message(
            nodeId: chat.id,
            role: .user,
            content: "I am dropping the Memory Center first plan.",
            timestamp: Date(timeIntervalSince1970: 60)
        )
        try store.insertMessage(userMessage)

        let priorPlan = MemoryAtom(
            type: .plan,
            statement: "Alex plans to ship the Memory Center before adding new agents.",
            normalizedKey: "plan|alex plans to ship the memory center before adding new agents.",
            scope: .conversation,
            scopeRefId: chat.id,
            status: .active,
            confidence: 0.85,
            eventTime: Date(timeIntervalSince1970: 1),
            sourceNodeId: chat.id
        )
        try store.insertMemoryAtom(priorPlan)

        await service.refreshConversation(nodeId: chat.id, projectId: nil, messages: [userMessage])

        let updated = try XCTUnwrap(store.fetchMemoryAtom(id: priorPlan.id))
        XCTAssertEqual(
            updated.status,
            .superseded,
            "Prior plan must be flagged superseded by a correction whose `corrects` matches it."
        )
        let supersedesEdges = try store.fetchMemoryEdges()
            .filter { $0.type == .supersedes && $0.toAtomId == priorPlan.id }
        XCTAssertEqual(supersedesEdges.count, 1)
    }

    /// Atoms produced by the live extractor must carry a populated embedding
    /// when an embedding function is supplied. Without this, the planner's
    /// vector entry-point can never fire — every recall has to start from
    /// keyword cues, which means paraphrased queries with no cue word miss
    /// even when the underlying memory exists. This is the prerequisite for
    /// the plan's "vector finds the entry → graph traverses" pattern.
    func testRefreshConversationPopulatesAtomEmbeddings() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- Alex stated a preference.",
                """
                {
                  "facts": [],
                  "decision_chains": [],
                  "semantic_atoms": [
                    {
                      "type": "preference",
                      "statement": "Alex prefers concise outputs.",
                      "evidence_quote": "Be concise.",
                      "confidence": 0.9
                    }
                  ]
                }
                """
            ]
        )
        let stubEmbedding: [Float] = [0.1, 0.2, 0.3, 0.4]
        let service = UserMemoryService(
            nodeStore: store,
            llmServiceProvider: { mock },
            embedFunction: { _ in stubEmbedding }
        )

        let chat = NousNode(type: .conversation, title: "Embed test", content: "")
        try store.insertNode(chat)
        let userMessage = Message(
            nodeId: chat.id,
            role: .user,
            content: "Be concise.",
            timestamp: Date(timeIntervalSince1970: 5)
        )
        try store.insertMessage(userMessage)

        await service.refreshConversation(nodeId: chat.id, projectId: nil, messages: [userMessage])

        let preference = try XCTUnwrap(
            try store.fetchMemoryAtoms().first(where: { $0.type == .preference })
        )
        XCTAssertEqual(
            preference.embedding,
            stubEmbedding,
            "Atom must persist the embedding produced by the embed function."
        )
    }

    /// When no embed function is provided, atoms must still be written —
    /// just without embeddings. This preserves the current default behavior
    /// for tests / call-sites that don't wire the embedding service.
    func testRefreshConversationLeavesEmbeddingNilWhenEmbedFunctionAbsent() async throws {
        let capture = PromptSequenceCapture()
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- Alex stated a preference.",
                """
                {
                  "facts": [],
                  "decision_chains": [],
                  "semantic_atoms": [
                    {
                      "type": "preference",
                      "statement": "Alex prefers concise outputs.",
                      "evidence_quote": "Be concise.",
                      "confidence": 0.9
                    }
                  ]
                }
                """
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let chat = NousNode(type: .conversation, title: "No embed test", content: "")
        try store.insertNode(chat)
        let userMessage = Message(
            nodeId: chat.id,
            role: .user,
            content: "Be concise.",
            timestamp: Date(timeIntervalSince1970: 5)
        )
        try store.insertMessage(userMessage)

        await service.refreshConversation(nodeId: chat.id, projectId: nil, messages: [userMessage])

        let preference = try XCTUnwrap(
            try store.fetchMemoryAtoms().first(where: { $0.type == .preference })
        )
        XCTAssertNil(preference.embedding)
    }

    func testCurrentGraphMemoryRecallReturnsPreferenceAtomsAndLogsRecallEvent() throws {
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { nil })
        let sourceChat = NousNode(type: .conversation, title: "Writing preferences", content: "")
        try store.insertNode(sourceChat)
        let sourceMessage = Message(
            nodeId: sourceChat.id,
            role: .user,
            content: "Remember that I never want em dashes in final copy.",
            timestamp: Date(timeIntervalSince1970: 30)
        )
        try store.insertMessage(sourceMessage)

        let atom = MemoryAtom(
            type: .preference,
            statement: "Alex never wants em dashes in final copy.",
            scope: .conversation,
            scopeRefId: sourceChat.id,
            confidence: 0.93,
            eventTime: sourceMessage.timestamp,
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 31),
            sourceNodeId: sourceChat.id,
            sourceMessageId: sourceMessage.id
        )
        try store.insertMemoryAtom(atom)

        let recall = service.currentGraphMemoryRecall(
            currentMessage: "你記唔記得我對 em dash 有咩偏好？",
            projectId: nil,
            conversationId: UUID()
        )

        XCTAssertEqual(recall.count, 1)
        XCTAssertTrue(recall[0].contains("MEMORY_ATOM"))
        XCTAssertTrue(recall[0].contains("type=preference"))
        XCTAssertTrue(recall[0].contains("Alex never wants em dashes"))
        XCTAssertTrue(recall[0].contains("source_quote: Remember that I never want em dashes"))

        let events = try store.fetchMemoryRecallEvents(limit: 10)
        XCTAssertEqual(events.first?.intent, MemoryQueryIntent.preferenceRecall.rawValue)
        XCTAssertEqual(events.first?.retrievedAtomIds, [atom.id])
    }

    func testCurrentGraphMemoryRecallDoesNotPolluteOrdinaryTurns() throws {
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { nil })
        try store.insertMemoryAtom(MemoryAtom(
            type: .preference,
            statement: "Alex never wants em dashes in final copy.",
            scope: .global,
            confidence: 0.93
        ))

        let recall = service.currentGraphMemoryRecall(
            currentMessage: "Help me rewrite this paragraph.",
            projectId: nil,
            conversationId: UUID()
        )

        XCTAssertTrue(recall.isEmpty)
        XCTAssertTrue(try store.fetchMemoryRecallEvents(limit: 10).isEmpty)
    }

    func testRefreshConversationDedupesRepeatedDecisionChainAtoms() async throws {
        let capture = PromptSequenceCapture()
        let decisionJSON = """
        {
          "facts": [],
          "decision_chains": [
            {
              "rejected_proposal":"Build a broad second brain rewrite.",
              "rejection":"Alex rejected doing a broad rewrite first.",
              "reasons":["The first slice must stay small."],
              "replacement":"Ship the graph writer fix first.",
              "evidence_quote":"Do not do a broad rewrite first. The first slice must stay small.",
              "confidence":0.88
            }
          ]
        }
        """
        let mock = QueueMockLLMService(
            capture: capture,
            replies: [
                "- first summary",
                decisionJSON,
                "- second summary",
                decisionJSON
            ]
        )
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { mock })

        let node = NousNode(type: .conversation, title: "Dedup decision chain", content: "")
        try store.insertNode(node)
        let message = Message(
            nodeId: node.id,
            role: .user,
            content: "Do not do a broad rewrite first. The first slice must stay small. Ship the graph writer fix first.",
            timestamp: Date(timeIntervalSince1970: 12)
        )
        try store.insertMessage(message)

        await service.refreshConversation(nodeId: node.id, projectId: nil, messages: [message])
        await service.refreshConversation(nodeId: node.id, projectId: nil, messages: [message])

        let atoms = try store.fetchMemoryAtoms()
            .filter { $0.scope == .conversation && $0.scopeRefId == node.id }
        XCTAssertEqual(atoms.count, 4)
        XCTAssertEqual(atoms.filter { $0.status == .active }.count, 4)
        XCTAssertEqual(atoms.filter { $0.type == .rejection }.first?.sourceMessageId, message.id)
        XCTAssertEqual(atoms.filter { $0.type == .rejection }.first?.eventTime, Date(timeIntervalSince1970: 12))
        XCTAssertEqual(try store.fetchMemoryEdges().count, 3)
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

        let allAtoms = try store.fetchMemoryAtoms()
            .filter { $0.scope == .conversation && $0.scopeRefId == node.id }
        XCTAssertEqual(allAtoms.count, 2, "graph atom history should mirror fact history")
        XCTAssertEqual(allAtoms.filter { $0.status == .active }.first?.type, .boundary)
        XCTAssertEqual(allAtoms.filter { $0.status == .archived }.first?.type, .decision)
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

    func testMemoryProjectionServiceOwnsEntryReadProjectionWithoutUserMemoryCore() throws {
        let projection = MemoryProjectionService(nodeStore: store)

        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .global,
                scopeRefId: nil,
                kind: .identity,
                stability: .stable,
                content: "Projection service reads canonical entries directly",
                sourceNodeIds: [],
                createdAt: Date(),
                updatedAt: Date(),
                lastConfirmedAt: Date()
            )
        )

        XCTAssertEqual(
            projection.currentGlobal(),
            "Projection service reads canonical entries directly"
        )
    }

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

    func testMemoryFactTrustActionsMutateFactRows() throws {
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: {
            MockLLMService(capture: PromptCapture(), reply: "")
        })
        let originalDate = Date(timeIntervalSince1970: 10)
        let confirmedFact = MemoryFactEntry(
            scope: .global,
            kind: .boundary,
            content: "Do not store hard opt-out turns.",
            confidence: 0.52,
            status: .active,
            stability: .stable,
            createdAt: originalDate,
            updatedAt: originalDate
        )
        let rejectedFact = MemoryFactEntry(
            scope: .global,
            kind: .decision,
            content: "Old decision.",
            confidence: 0.88,
            status: .active,
            stability: .temporary,
            createdAt: originalDate,
            updatedAt: originalDate
        )
        let forgottenFact = MemoryFactEntry(
            scope: .conversation,
            scopeRefId: UUID(),
            kind: .constraint,
            content: "Throwaway constraint.",
            confidence: 0.7,
            status: .active,
            stability: .temporary,
            createdAt: originalDate,
            updatedAt: originalDate
        )
        try store.insertMemoryFactEntry(confirmedFact)
        try store.insertMemoryFactEntry(rejectedFact)
        try store.insertMemoryFactEntry(forgottenFact)

        XCTAssertTrue(service.confirmMemoryFactEntry(id: confirmedFact.id))
        XCTAssertTrue(service.archiveMemoryFactEntry(id: rejectedFact.id))
        XCTAssertTrue(service.deleteMemoryFactEntry(id: forgottenFact.id))

        let updatedConfirmed = try store.fetchMemoryFactEntry(id: confirmedFact.id)
        XCTAssertEqual(updatedConfirmed?.status, .active)
        XCTAssertGreaterThanOrEqual(updatedConfirmed?.confidence ?? 0, 0.95)
        XCTAssertGreaterThan(updatedConfirmed?.updatedAt ?? originalDate, originalDate)
        XCTAssertEqual(try store.fetchMemoryFactEntry(id: rejectedFact.id)?.status, .archived)
        XCTAssertNil(try store.fetchMemoryFactEntry(id: forgottenFact.id))
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

    func testFactSourceSnippetsUseLinkedSourceNodes() throws {
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: {
            MockLLMService(capture: PromptCapture(), reply: "")
        })
        let node = NousNode(
            type: .conversation,
            title: "Memory boundary",
            content: "Alex: 不要记住具体内容，只记住这个边界。\n\nNous: 我会尊重呢个边界。"
        )
        try store.insertNode(node)

        let fact = MemoryFactEntry(
            scope: .conversation,
            scopeRefId: node.id,
            kind: .boundary,
            content: "Alex set a memory boundary.",
            confidence: 0.91,
            status: .active,
            stability: .stable,
            sourceNodeIds: [node.id],
            createdAt: Date(),
            updatedAt: Date()
        )
        try store.insertMemoryFactEntry(fact)

        let snippets = service.factSourceSnippets(for: fact.id, limit: 2)
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets.first?.sourceNodeId, node.id)
        XCTAssertEqual(snippets.first?.sourceTitle, "Memory boundary")
        XCTAssertTrue(snippets.first?.snippet.contains("不要记住具体内容") == true)
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
        XCTAssertEqual(
            service.memoryPersistenceDecision(messages: messages, projectId: nil),
            .suppress(.hardOptOut)
        )
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
        XCTAssertEqual(
            service.memoryPersistenceDecision(messages: messages, projectId: nil),
            .suppress(.sensitiveConsentRequired)
        )
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
