import XCTest
@testable import Nous

final class RAGPipelineTests: XCTestCase {
    var nodeStore: NodeStore!
    var vectorStore: VectorStore!

    override func setUp() {
        super.setUp()
        nodeStore = try! NodeStore(path: ":memory:")
        vectorStore = VectorStore(nodeStore: nodeStore)
    }

    // MARK: - Test 1: RAG search returns the most relevant node

    func testBuildContextIncludesRelevantNodes() throws {
        // Insert a node with embedding close to query
        var matchNode = NousNode(type: .note, title: "Swift concurrency guide")
        matchNode.embedding = [1.0, 0.0, 0.0]
        try nodeStore.insertNode(matchNode)

        // Insert a node with embedding far from query
        var otherNode = NousNode(type: .note, title: "Recipe for banana bread")
        otherNode.embedding = [0.0, 0.0, 1.0]
        try nodeStore.insertNode(otherNode)

        // Query embedding similar to matchNode
        let queryEmbedding: [Float] = [0.99, 0.01, 0.0]
        let results = try vectorStore.search(query: queryEmbedding, topK: 5)

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results[0].node.title, "Swift concurrency guide")
    }

    // MARK: - Test 2: assembleContext includes expected content

    func testContextAssembly() {
        let node1 = NousNode(
            type: .note,
            title: "Actor isolation notes",
            content: "Actors protect mutable state by serializing access."
        )
        let node2 = NousNode(
            type: .note,
            title: "Async/Await overview",
            content: "Async/await simplifies asynchronous code in Swift."
        )

        let citations = [
            SearchResult(node: node1, similarity: 0.92),
            SearchResult(node: node2, similarity: 0.78)
        ]
        let recentConversation = (
            title: "Funding worries",
            memory: "Alex said cash runway is tight and school is only for visa status."
        )

        let projectGoal = "Build a Swift concurrency learning app"
        let userMemory = """
        ## Identity
        - Alex is a solo founder.
        """
        let essentialStory = """
        - Stable backdrop: Alex is shipping under real financial pressure.
        - Recent thread (Funding worries): Cash runway is tight.
        """
        let memoryEvidence = [
            MemoryEvidenceSnippet(
                label: "Project context",
                sourceNodeId: UUID(),
                sourceTitle: "Architecture tradeoffs",
                snippet: "Project context should stay grounded in a real Alex quote."
            )
        ]
        let userModel = UserModel(
            identity: [],
            goals: ["Ship cross-chat continuity this week"],
            workStyle: ["Prefers direct, first-principles answers."],
            memoryBoundary: ["Ask before storing unusually sensitive material."]
        )

        let context = ChatViewModel.assembleContext(
            globalMemory: userMemory,
            essentialStory: essentialStory,
            userModel: userModel,
            memoryEvidence: memoryEvidence,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [recentConversation],
            citations: citations,
            projectGoal: projectGoal
        ).combined

        // Verify anchor prompt is present without depending on one exact language variant
        XCTAssertTrue(context.contains("Nous"))

        // Verify long-term user memory is included
        XCTAssertTrue(context.contains("Alex is a solo founder"))

        // Verify essential story is included between identity and deeper recall
        XCTAssertTrue(context.contains("BROADER SITUATION RIGHT NOW"))
        XCTAssertTrue(context.contains("Cash runway is tight"))

        // Verify project goal is included
        XCTAssertTrue(context.contains(projectGoal))

        // Verify bounded source evidence is included
        XCTAssertTrue(context.contains("SHORT SOURCE EVIDENCE FOR THE ABOVE MEMORY"))
        XCTAssertTrue(context.contains("Architecture tradeoffs"))

        // Verify derived user model is included without duplicating identity when global memory already exists
        XCTAssertTrue(context.contains("DERIVED USER MODEL"))
        XCTAssertTrue(context.contains("Ship cross-chat continuity this week"))
        XCTAssertTrue(context.contains("Prefers direct, first-principles answers."))
        XCTAssertFalse(context.contains("Identity:\n-"))

        // Verify hypothesis-confirm policy is present
        XCTAssertTrue(context.contains("I might be wrong, but"))
        XCTAssertTrue(context.contains("One hypothesis is"))
        XCTAssertTrue(context.contains("Does this fit, or is something else more true?"))

        // Verify recent conversation is included
        XCTAssertTrue(context.contains("Funding worries"))
        XCTAssertTrue(context.contains("cash runway is tight"))

        // Verify citation titles are present
        XCTAssertTrue(context.contains("Actor isolation notes"))
        XCTAssertTrue(context.contains("Async/Await overview"))

        // Verify content snippets are present
        XCTAssertTrue(context.contains("Actors protect mutable state"))
        XCTAssertTrue(context.contains("Async/await simplifies"))

        // Verify relevance percentages
        XCTAssertTrue(context.contains("92%"))
        XCTAssertTrue(context.contains("78%"))
        XCTAssertLessThan(
            context.range(of: "MEMORY INTERPRETATION POLICY")!.lowerBound,
            context.range(of: "LONG-TERM MEMORY ABOUT ALEX")!.lowerBound
        )
        // Chat mode moved into the volatile slice (judge flips it per turn), so it
        // now lands after the stable memory layers in combined form. Verify the new
        // invariant: memory comes before the chat-mode directive.
        XCTAssertLessThan(
            context.range(of: "BROADER SITUATION RIGHT NOW")!.lowerBound,
            context.range(of: "ACTIVE CHAT MODE: Companion")!.lowerBound
        )
    }

    func testAssembleContextDefaultsToCompanionMode() {
        let context = ChatViewModel.assembleContext(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined

        XCTAssertTrue(context.contains("ACTIVE CHAT MODE: Companion"))
        XCTAssertTrue(context.contains("Stay conversational, warm, and direct."))
        XCTAssertFalse(context.contains("Alex explicitly wants deeper reasoning"))
    }

    func testAssembleContextStrategistModeChangesPromptBehaviorWithoutDroppingContinuity() {
        let context = ChatViewModel.assembleContext(
            chatMode: .strategist,
            globalMemory: "- Alex is a solo founder.",
            essentialStory: "- Stable backdrop: Alex is shipping under pressure.",
            projectMemory: "- Cross-chat continuity is the top requirement.",
            conversationMemory: "- This chat is about memory architecture.",
            recentConversations: [("Funding worries", "Cash runway is tight.")],
            citations: [],
            projectGoal: "Ship memory improvements"
        ).combined

        XCTAssertTrue(context.contains("ACTIVE CHAT MODE: Strategist"))
        XCTAssertTrue(context.contains("Alex explicitly wants deeper reasoning"))
        XCTAssertTrue(context.contains("Make assumptions explicit"))
        XCTAssertTrue(context.contains("BROADER SITUATION RIGHT NOW"))
        XCTAssertTrue(context.contains("RECENT CONVERSATIONS WITH ALEX"))
    }

    func testAssembleContextAddsStrategistLongGapBridgeGuidanceForStrongOldHit() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let oldNode = NousNode(
            type: .note,
            title: "Fear of failure",
            content: "I keep hesitating because I am scared of failing in public.",
            createdAt: now.addingTimeInterval(-60 * 86_400),
            updatedAt: now.addingTimeInterval(-60 * 86_400)
        )

        let context = ChatViewModel.assembleContext(
            chatMode: .strategist,
            currentUserInput: "I am thinking about applying to YC now.",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [SearchResult(node: oldNode, similarity: 0.72, lane: .longGap)],
            projectGoal: nil,
            now: now
        ).combined

        XCTAssertTrue(context.contains("older cross-time connection"))
        XCTAssertTrue(context.contains("LONG-GAP CONNECTION CUE"))
        XCTAssertTrue(context.contains("Name the line directly and clearly"))
        XCTAssertTrue(context.contains("Do not mention retrieval, citations"))
    }

    func testAssembleContextUsesGentlerLongGapGuidanceInCompanionMode() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let oldNode = NousNode(
            type: .note,
            title: "Fear of failure",
            content: "I keep hesitating because I am scared of failing in public.",
            createdAt: now.addingTimeInterval(-60 * 86_400),
            updatedAt: now.addingTimeInterval(-60 * 86_400)
        )

        let context = ChatViewModel.assembleContext(
            chatMode: .companion,
            currentUserInput: "I think I might finally do it.",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [SearchResult(node: oldNode, similarity: 0.72, lane: .longGap)],
            projectGoal: nil,
            now: now
        ).combined

        XCTAssertTrue(context.contains("LONG-GAP CONNECTION CUE"))
        XCTAssertTrue(context.contains("Keep it gentle and hypothesis-led"))
        XCTAssertFalse(context.contains("Name the line directly and clearly"))
    }

    /// Codex #4: the recent-conversations layer must be fed from
    /// conversation_memory (Alex-only, evidence-filtered), NOT the raw
    /// transcript. The type signature itself is the strongest guarantee
    /// (`[(title, memory)]` — no way to pass a NousNode through). This test
    /// verifies the positive side: whatever string the caller supplies as
    /// `memory` shows up in the context under the right heading, untouched.
    /// The anchor contains literal "Nous:" formatting examples, so we avoid
    /// over-broad assertions that would false-positive on the anchor.
    func testAssembleContextUsesEvidenceFilteredRecents() {
        let distinctive = "F-1 visa constraints shape investing approach"
        let recent = (title: "Old chat", memory: distinctive)

        let context = ChatViewModel.assembleContext(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [recent],
            citations: [],
            projectGoal: nil
        ).combined

        XCTAssertTrue(context.contains("RECENT CONVERSATIONS WITH ALEX:"),
                      "recent-conversations heading should appear")
        XCTAssertTrue(context.contains(distinctive),
                      "evidence-filtered memory must survive into context")
        XCTAssertTrue(context.contains("\"Old chat\": \(distinctive)"),
                      "recent entry must use the (title, memory) tuple verbatim")
    }

    func testAssembleContextOmitsEvidenceSectionWhenNoSnippetsExist() {
        let context = ChatViewModel.assembleContext(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined

        XCTAssertFalse(context.contains("SHORT SOURCE EVIDENCE FOR THE ABOVE MEMORY"))
    }

    func testAssembleContextOmitsLongGapGuidanceForWeakOldHit() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let oldNode = NousNode(
            type: .note,
            title: "Weak old thread",
            content: "This should stay silent because relevance is too low.",
            createdAt: now.addingTimeInterval(-80 * 86_400),
            updatedAt: now.addingTimeInterval(-80 * 86_400)
        )

        let context = ChatViewModel.assembleContext(
            chatMode: .strategist,
            currentUserInput: "I am thinking out loud.",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [SearchResult(node: oldNode, similarity: 0.58, lane: .longGap)],
            projectGoal: nil,
            now: now
        ).combined

        XCTAssertFalse(context.contains("LONG-GAP CONNECTION CUE"))
    }

    func testAssembleContextUsesCitationPreviewSnippetWhenAvailable() {
        let node = NousNode(
            type: .conversation,
            title: "YC fear thread",
            content: "Alex: Coffee chat.\n\nNous: Also coffee chat."
        )

        let context = ChatViewModel.assembleContext(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [
                SearchResult(
                    node: node,
                    similarity: 0.74,
                    previewSnippet: "Alex: I am scared of failing if I apply to YC.\n\nNous: The fear is underneath the decision."
                )
            ],
            projectGoal: nil
        ).combined

        XCTAssertTrue(context.contains("I am scared of failing if I apply to YC"))
        XCTAssertFalse(context.contains("Coffee chat"))
    }

    func testAssembleContextUsesPreviewSnippetForLongGapCue() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let oldNode = NousNode(
            type: .conversation,
            title: "YC fear thread",
            content: "Alex: Coffee chat.\n\nNous: Also coffee chat.",
            createdAt: now.addingTimeInterval(-60 * 86_400),
            updatedAt: now.addingTimeInterval(-60 * 86_400)
        )

        let context = ChatViewModel.assembleContext(
            chatMode: .strategist,
            currentUserInput: "I am thinking about applying to YC now.",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [
                SearchResult(
                    node: oldNode,
                    similarity: 0.72,
                    lane: .longGap,
                    previewSnippet: "Alex: I am scared of failing if I apply to YC.\n\nNous: The fear is underneath the decision."
                )
            ],
            projectGoal: nil,
            now: now
        ).combined

        XCTAssertTrue(context.contains("I am scared of failing if I apply to YC"))
        XCTAssertFalse(context.contains("Coffee chat"))
    }

    func testAssembleContextIncludesHypothesisLanguagePolicy() {
        let context = ChatViewModel.assembleContext(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined

        XCTAssertTrue(context.contains("MEMORY INTERPRETATION POLICY"))
        XCTAssertTrue(context.contains("I might be wrong, but"))
        XCTAssertTrue(context.contains("Do not present diagnoses or identity labels as certainty"))
    }

    func testAssembleContextInvokesHighRiskSafetyModeWhenQueryIsDangerous() {
        let context = ChatViewModel.assembleContext(
            currentUserInput: "I want to kill myself tonight.",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined

        XCTAssertTrue(context.contains("HIGH-RISK SAFETY MODE"))
        XCTAssertTrue(context.contains("Prioritize immediate safety"))
        XCTAssertTrue(context.contains("Do not romanticize self-destruction"))
    }

    func testGovernanceTraceMarksSafetyInvocationAndPromptLayers() {
        let trace = ChatViewModel.governanceTrace(
            chatMode: .strategist,
            currentUserInput: "I want to die.",
            globalMemory: "- Alex is a solo founder.",
            essentialStory: "- Stable backdrop: pressure is high.",
            userModel: UserModel(
                identity: [],
                goals: ["Ship memory upgrades"],
                workStyle: [],
                memoryBoundary: []
            ),
            memoryEvidence: [
                MemoryEvidenceSnippet(
                    label: "Project context",
                    sourceNodeId: UUID(),
                    sourceTitle: "Old thread",
                    snippet: "Cross-chat continuity matters."
                )
            ],
            projectMemory: "- Current work is on memory governance.",
            conversationMemory: "- This thread is about safety policy.",
            recentConversations: [("Old chat", "He said pressure is very high.")],
            citations: [],
            projectGoal: "Ship trustworthy memory"
        )

        XCTAssertTrue(trace.safetyPolicyInvoked)
        XCTAssertTrue(trace.highRiskQueryDetected)
        XCTAssertTrue(trace.evidenceAttached)
        XCTAssertTrue(trace.promptLayers.contains("high_risk_safety_mode"))
        XCTAssertTrue(trace.promptLayers.contains("strategist_mode"))
        XCTAssertTrue(trace.promptLayers.contains("essential_story"))
        XCTAssertTrue(trace.promptLayers.contains("memory_evidence"))
    }

    func testGovernanceTraceMarksLongGapBridgeGuidanceWhenEligible() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let oldNode = NousNode(
            type: .note,
            title: "Fear of failure",
            content: "I keep hesitating because I am scared of failing in public.",
            createdAt: now.addingTimeInterval(-60 * 86_400),
            updatedAt: now.addingTimeInterval(-60 * 86_400)
        )

        let trace = ChatViewModel.governanceTrace(
            chatMode: .strategist,
            currentUserInput: "I am thinking about applying to YC now.",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [SearchResult(node: oldNode, similarity: 0.72, lane: .longGap)],
            projectGoal: nil,
            now: now
        )

        XCTAssertTrue(trace.promptLayers.contains("citations"))
        XCTAssertTrue(trace.promptLayers.contains("long_gap_bridge_guidance"))
    }

    func testAssembleContextIncludesIdentityFacetWhenGlobalMemoryIsEmpty() {
        let context = ChatViewModel.assembleContext(
            globalMemory: nil,
            userModel: UserModel(
                identity: ["Alex is a solo founder."],
                goals: [],
                workStyle: [],
                memoryBoundary: []
            ),
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined

        XCTAssertTrue(context.contains("DERIVED USER MODEL"))
        XCTAssertTrue(context.contains("Identity:\n- Alex is a solo founder."))
    }

    func testInteractiveClarificationInstructionsAppearOnlyWhenEnabled() {
        let enabled = ChatViewModel.assembleContext(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            activeQuickActionMode: .direction,
            allowInteractiveClarification: true
        ).combined
        let disabled = ChatViewModel.assembleContext(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            activeQuickActionMode: .direction,
            allowInteractiveClarification: false
        ).combined

        XCTAssertTrue(enabled.contains("INTERACTIVE CLARIFICATION UI"))
        XCTAssertTrue(enabled.contains("understanding phase"))
        XCTAssertTrue(enabled.contains("at most one clarification follow-up"))
        XCTAssertTrue(enabled.contains("stop clarifying and give the best real guidance"))
        XCTAssertFalse(disabled.contains("INTERACTIVE CLARIFICATION UI"))
        XCTAssertTrue(disabled.contains("ACTIVE QUICK MODE: Direction"))
    }

    func testInteractiveClarificationStopsAfterFirstUserReply() {
        let firstReply = [
            Message(nodeId: UUID(), role: .user, content: "I'm stuck between two paths.")
        ]
        let secondReply = [
            Message(nodeId: UUID(), role: .user, content: "I'm stuck between two paths."),
            Message(nodeId: UUID(), role: .assistant, content: "Which two paths?"),
            Message(nodeId: UUID(), role: .user, content: "Staying in school or going all in.")
        ]

        XCTAssertTrue(
            ChatViewModel.shouldAllowInteractiveClarification(
                activeQuickActionMode: .direction,
                messages: firstReply
            )
        )
        XCTAssertFalse(
            ChatViewModel.shouldAllowInteractiveClarification(
                activeQuickActionMode: .direction,
                messages: secondReply
            )
        )
        XCTAssertFalse(
            ChatViewModel.shouldAllowInteractiveClarification(
                activeQuickActionMode: nil,
                messages: firstReply
            )
        )
    }

    func testQuickActionModeStaysActiveOnlyWhenAssistantStillClarifies() {
        let clarificationReply = """
        I need one more distinction before I answer.
        <clarify>
        <question>What kind of situation is this?</question>
        <option>Work</option>
        <option>School</option>
        <option>Relationship</option>
        </clarify>
        """
        let normalReply = "Based on what you've shared, the clearest next step is to talk to him directly."
        let understandingQuestion = """
        <phase>understanding</phase>
        Before I jump in, what feels most stuck right now?
        """

        XCTAssertEqual(
            ChatViewModel.updatedQuickActionMode(
                currentMode: .direction,
                assistantContent: clarificationReply
            ),
            .direction
        )
        XCTAssertEqual(
            ChatViewModel.updatedQuickActionMode(
                currentMode: .direction,
                assistantContent: understandingQuestion
            ),
            .direction
        )
        XCTAssertNil(
            ChatViewModel.updatedQuickActionMode(
                currentMode: .direction,
                assistantContent: normalReply
            )
        )
    }

    func testQuickActionOpeningPromptStartsWithAssistantQuestioning() {
        let prompt = ChatViewModel.quickActionOpeningPrompt(for: .mentalHealth)

        XCTAssertTrue(prompt.contains("Start the conversation yourself"))
        XCTAssertTrue(prompt.contains("Ask one short, warm opening question"))
        XCTAssertTrue(prompt.contains("Mental Health"))
        XCTAssertTrue(prompt.contains("do not use the clarification card yet"))
        XCTAssertTrue(prompt.contains("<phase>understanding</phase>"))
    }
}
