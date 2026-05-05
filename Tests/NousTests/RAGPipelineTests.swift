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

    func testTurnSystemSliceCombinedStringConcatenatesNonEmptyBlocks() {
        let blocks = [
            SystemPromptBlock(id: .anchorAndPolicies, content: "anchor", cacheControl: .ephemeral),
            SystemPromptBlock(id: .slowMemory, content: "", cacheControl: .ephemeral),
            SystemPromptBlock(id: .activeSkills, content: "active", cacheControl: .ephemeral),
            SystemPromptBlock(id: .skillIndex, content: "", cacheControl: .ephemeral),
            SystemPromptBlock(id: .volatile, content: "vol", cacheControl: nil)
        ]
        let slice = TurnSystemSlice(blocks: blocks)

        XCTAssertEqual(slice.combinedString, "anchor\n\nactive\n\nvol")
    }

    func testTurnSystemSliceStableAndVolatileAccessorsStayBackwardCompatible() {
        let slice = TurnSystemSlice(blocks: [
            SystemPromptBlock(id: .anchorAndPolicies, content: "anchor", cacheControl: .ephemeral),
            SystemPromptBlock(id: .slowMemory, content: "memory", cacheControl: .ephemeral),
            SystemPromptBlock(id: .volatile, content: "turn", cacheControl: nil)
        ])

        XCTAssertEqual(slice.stable, "anchor\n\nmemory")
        XCTAssertEqual(slice.volatile, "turn")
        XCTAssertEqual(slice.combined, "anchor\n\nmemory\n\nturn")
    }

    func testTurnSystemSliceLegacyInitializerCreatesBlockBackedSlice() {
        let slice = TurnSystemSlice(stable: "stable", volatile: "volatile")

        XCTAssertEqual(slice.blocks.map(\.id), [.anchorAndPolicies, .volatile])
        XCTAssertEqual(slice.combinedString, "stable\n\nvolatile")
    }

    func testPromptContextAssemblerSkipsActiveSkillSectionWhenNoLoadedSkills() {
        let slice = assembleLazyLoadSlice(loadedSkills: [], matchedSkills: [], activeMode: .direction)

        XCTAssertFalse(slice.combinedString.contains("ACTIVE SKILLS"))
        XCTAssertFalse(slice.blocks.map(\.id).contains(.activeSkills))
    }

    func testPromptContextAssemblerRendersActiveSkillSnapshots() {
        let skillID = UUID()
        let loaded = [
            LoadedSkill(
                skillID: skillID,
                nameSnapshot: "direction-skeleton",
                contentSnapshot: "Direction skeleton content.",
                stateAtLoad: .active,
                loadedAt: Date(timeIntervalSince1970: 10)
            )
        ]

        let slice = assembleLazyLoadSlice(loadedSkills: loaded, matchedSkills: [], activeMode: .direction)

        XCTAssertTrue(slice.combinedString.contains("ACTIVE SKILLS"))
        XCTAssertTrue(slice.combinedString.contains("Direction skeleton content."))
        XCTAssertTrue(slice.combinedString.contains("<<skill source=user id=\(skillID.uuidString) name=direction-skeleton>>"))
        XCTAssertTrue(slice.blocks.map(\.id).contains(.activeSkills))
    }

    func testPromptContextAssemblerSkipsSkillIndexWhenQuickModeIsNil() {
        let slice = assembleLazyLoadSlice(
            loadedSkills: [],
            matchedSkills: [makePromptSkill(name: "direction-skeleton")],
            activeMode: nil
        )

        XCTAssertFalse(slice.combinedString.contains("SKILL INDEX"))
        XCTAssertFalse(slice.blocks.map(\.id).contains(.skillIndex))
    }

    func testPromptContextAssemblerRendersSkillIndexWhenModeIsPresent() {
        let skill = makePromptSkill(
            name: "direction-skeleton",
            useWhen: "Use when Alex asks for tradeoffs."
        )

        let slice = assembleLazyLoadSlice(loadedSkills: [], matchedSkills: [skill], activeMode: .direction)

        XCTAssertTrue(slice.combinedString.contains("SKILL INDEX"))
        XCTAssertTrue(slice.combinedString.contains("Use when Alex asks for tradeoffs."))
        XCTAssertTrue(slice.combinedString.contains("call loadSkill"))
        XCTAssertTrue(slice.blocks.map(\.id).contains(.skillIndex))
    }

    func testPromptContextAssemblerSkillIndexExcludesAlreadyLoadedSkills() {
        let loadedID = UUID()
        let otherID = UUID()
        let loaded = [
            LoadedSkill(
                skillID: loadedID,
                nameSnapshot: "already-loaded",
                contentSnapshot: "Loaded content.",
                stateAtLoad: .active,
                loadedAt: Date()
            )
        ]
        let matched = [
            makePromptSkill(id: loadedID, name: "already-loaded"),
            makePromptSkill(id: otherID, name: "still-visible")
        ]

        let slice = assembleLazyLoadSlice(loadedSkills: loaded, matchedSkills: matched, activeMode: .direction)
        let index = sliceSection(slice.combinedString, header: "SKILL INDEX")

        XCTAssertFalse(index.contains("already-loaded"))
        XCTAssertTrue(index.contains("still-visible"))
    }

    func testPromptContextAssemblerSkillIndexFallsBackToDescriptionWhenUseWhenIsNil() {
        let skill = makePromptSkill(
            name: "description-skill",
            description: "Use this description.",
            useWhen: nil
        )

        let slice = assembleLazyLoadSlice(loadedSkills: [], matchedSkills: [skill], activeMode: .direction)

        XCTAssertTrue(slice.combinedString.contains("Use this description."))
    }

    func testPromptContextAssemblerBlockOrderPutsActiveBeforeIndex() throws {
        let loaded = [
            LoadedSkill(
                skillID: UUID(),
                nameSnapshot: "loaded",
                contentSnapshot: "Loaded content.",
                stateAtLoad: .active,
                loadedAt: Date()
            )
        ]
        let matched = [makePromptSkill(name: "matched")]

        let slice = assembleLazyLoadSlice(loadedSkills: loaded, matchedSkills: matched, activeMode: .direction)
        let ids = slice.blocks.map(\.id)

        XCTAssertLessThan(
            try XCTUnwrap(ids.firstIndex(of: .activeSkills)),
            try XCTUnwrap(ids.firstIndex(of: .skillIndex))
        )
    }

    func testPromptContextAssemblerCacheMarkedBlockSequenceWhenAllPresent() {
        let loaded = [
            LoadedSkill(
                skillID: UUID(),
                nameSnapshot: "loaded",
                contentSnapshot: "Loaded content.",
                stateAtLoad: .active,
                loadedAt: Date()
            )
        ]
        let matched = [makePromptSkill(name: "matched")]

        let slice = assembleLazyLoadSlice(loadedSkills: loaded, matchedSkills: matched, activeMode: .direction)

        XCTAssertEqual(
            slice.blocks.filter { $0.cacheControl != nil }.map(\.id),
            [.anchorAndPolicies, .slowMemory, .activeSkills, .skillIndex]
        )
    }

    // MARK: - Test 1: RAG search returns the most relevant node

    func testPromptContextAssemblerOwnsContextAssemblyWithoutChatViewModel() {
        let context = PromptContextAssembler.assembleContext(
            globalMemory: "- Alex owns the data layer.",
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: "Clean the memory architecture"
        ).combined

        XCTAssertTrue(context.contains("LONG-TERM MEMORY ABOUT ALEX"))
        XCTAssertTrue(context.contains("Clean the memory architecture"))
    }

    func testAssembleContextIncludesRealWorldDecisionPolicy() {
        let context = PromptContextAssembler.assembleContext(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined

        XCTAssertTrue(context.contains("REAL-WORLD DECISION POLICY"))
        XCTAssertTrue(context.contains("does not have live web or shop search"))
        XCTAssertTrue(context.contains("If OpenRouter web search is available"))
        XCTAssertTrue(context.contains("Do not infer that something is unavailable"))
    }

    func testMemoryPromptPacketOwnsStableMemoryBlockOrdering() {
        let evidence = MemoryEvidenceSnippet(
            label: "Project context",
            sourceNodeId: UUID(),
            sourceTitle: "Memory architecture",
            snippet: "Jurisdiction should prevent duplicate memory claims."
        )
        let userModel = UserModel(
            identity: ["Alex is a solo founder."],
            goals: ["Ship memory jurisdiction"],
            workStyle: ["Prefers direct, evidence-grounded answers."],
            memoryBoundary: []
        )

        let packet = MemoryPromptPacket(
            globalMemory: "- Alex owns the data layer.",
            essentialStory: "- Stable backdrop: memory trust is the current bottleneck.",
            userModel: userModel,
            memoryEvidence: [evidence],
            projectMemory: "- Project memory stays scoped.",
            conversationMemory: "- This chat is about memory jurisdiction.",
            recentConversations: [("Prior memory audit", "Current memory is mostly conversation-scoped.")],
            projectGoal: "Make memory layers explicit"
        )

        let context = packet.stableBlocks.joined(separator: "\n\n")

        XCTAssertLessThan(
            context.range(of: "LONG-TERM MEMORY ABOUT ALEX")!.lowerBound,
            context.range(of: "BROADER SITUATION RIGHT NOW")!.lowerBound
        )
        XCTAssertLessThan(
            context.range(of: "THIS PROJECT'S CONTEXT")!.lowerBound,
            context.range(of: "THIS CHAT'S THREAD SO FAR")!.lowerBound
        )
        XCTAssertLessThan(
            context.range(of: "SHORT SOURCE EVIDENCE FOR THE ABOVE MEMORY")!.lowerBound,
            context.range(of: "DERIVED USER MODEL")!.lowerBound
        )
        XCTAssertTrue(context.contains("CURRENT PROJECT GOAL: Make memory layers explicit"))
        XCTAssertTrue(context.contains("\"Prior memory audit\": Current memory is mostly conversation-scoped."))
        XCTAssertFalse(context.contains("Identity:\n- Alex is a solo founder."),
                       "identity facet should not duplicate when global memory is already present")
    }

    func testMemoryPromptPacketPlacesOperatingContextBeforeDerivedMemory() {
        let packet = MemoryPromptPacket(
            operatingContext: OperatingContext(
                identity: "Alex is a solo founder.",
                currentWork: "Ship Operating Context V1.",
                communicationStyle: "Be direct and warm.",
                boundaries: "Do not store sensitive facts without explicit consent."
            ),
            globalMemory: "- Learned memory should stay separate.",
            essentialStory: nil,
            userModel: UserModel(
                identity: ["Derived identity"],
                goals: ["Derived goal"],
                workStyle: ["Derived style"],
                memoryBoundary: ["Derived boundary"]
            ),
            memoryEvidence: [],
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            projectGoal: nil
        )

        let context = packet.stableBlocks.joined(separator: "\n\n")

        XCTAssertTrue(context.contains("USER-AUTHORED OPERATING CONTEXT"))
        XCTAssertTrue(context.contains("Identity:\n- Alex is a solo founder."))
        XCTAssertTrue(context.contains("Current Work / Goals:\n- Ship Operating Context V1."))
        XCTAssertTrue(context.contains("Communication Style:\n- Be direct and warm."))
        XCTAssertTrue(context.contains("Hard Boundaries:\n- Do not store sensitive facts without explicit consent."))
        let operatingContextIndex = context.distance(
            from: context.startIndex,
            to: context.range(of: "USER-AUTHORED OPERATING CONTEXT")!.lowerBound
        )
        let globalMemoryIndex = context.distance(
            from: context.startIndex,
            to: context.range(of: "LONG-TERM MEMORY ABOUT ALEX")!.lowerBound
        )
        let userModelIndex = context.distance(
            from: context.startIndex,
            to: context.range(of: "DERIVED USER MODEL")!.lowerBound
        )
        XCTAssertLessThan(
            operatingContextIndex,
            globalMemoryIndex
        )
        XCTAssertLessThan(
            operatingContextIndex,
            userModelIndex
        )
    }

    func testEmptyOperatingContextIsOmittedFromPrompt() {
        let context = PromptContextAssembler.assembleContext(
            operatingContext: OperatingContext(),
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined

        XCTAssertFalse(context.contains("USER-AUTHORED OPERATING CONTEXT"))
    }

    func testMemoryPromptPacketDoesNotDuplicateProjectGoalInsideUserModelGoals() {
        let packet = MemoryPromptPacket(
            globalMemory: nil,
            essentialStory: nil,
            userModel: UserModel(
                identity: [],
                goals: [
                    "Ship memory jurisdiction",
                    "Keep memory evidence grounded"
                ],
                workStyle: [],
                memoryBoundary: []
            ),
            memoryEvidence: [],
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            projectGoal: "Ship memory jurisdiction"
        )

        let context = packet.stableBlocks.joined(separator: "\n\n")

        XCTAssertTrue(context.contains("CURRENT PROJECT GOAL: Ship memory jurisdiction"))
        XCTAssertFalse(context.contains("Goals:\n- Ship memory jurisdiction"),
                       "project goal should be owned by the project-goal block, not repeated in user model")
        XCTAssertTrue(context.contains("Goals:\n- Keep memory evidence grounded"))
    }

    func testMemoryPromptPacketFiltersRecentConversationAlreadyOwnedByCurrentThreadMemory() {
        let packet = MemoryPromptPacket(
            globalMemory: nil,
            essentialStory: nil,
            userModel: nil,
            memoryEvidence: [],
            projectMemory: nil,
            conversationMemory: "- Current chat is about memory jurisdiction.",
            recentConversations: [
                ("Duplicate current chat", "- Current chat is about memory jurisdiction."),
                ("Separate thread", "- Alex compared memory layers to project lanes.")
            ],
            projectGoal: nil
        )

        let context = packet.stableBlocks.joined(separator: "\n\n")

        XCTAssertTrue(context.contains("THIS CHAT'S THREAD SO FAR"))
        XCTAssertTrue(context.contains("Current chat is about memory jurisdiction."))
        XCTAssertTrue(context.contains("RECENT CONVERSATIONS WITH ALEX"))
        XCTAssertFalse(context.contains("Duplicate current chat"),
                       "recent-conversation memory should not repeat the current thread summary")
        XCTAssertTrue(context.contains("Separate thread"))
    }

    func testMemoryPromptPacketFiltersEvidenceSnippetAlreadyOwnedByScopedMemory() {
        let packet = MemoryPromptPacket(
            globalMemory: nil,
            essentialStory: nil,
            userModel: nil,
            memoryEvidence: [
                MemoryEvidenceSnippet(
                    label: "Project context",
                    sourceNodeId: UUID(),
                    sourceTitle: "Memory architecture",
                    snippet: "Jurisdiction should prevent duplicate memory claims."
                )
            ],
            projectMemory: "- Jurisdiction should prevent duplicate memory claims.",
            conversationMemory: nil,
            recentConversations: [],
            projectGoal: nil
        )

        let context = packet.stableBlocks.joined(separator: "\n\n")

        XCTAssertTrue(context.contains("THIS PROJECT'S CONTEXT"))
        XCTAssertTrue(context.contains("Jurisdiction should prevent duplicate memory claims."))
        XCTAssertFalse(context.contains("SHORT SOURCE EVIDENCE FOR THE ABOVE MEMORY"),
                       "exact evidence already represented by a scoped summary should not be repeated")
        XCTAssertFalse(context.contains("Memory architecture"))
    }

    func testAssembleContextFiltersCitationWhenMemoryEvidenceAlreadyUsesSameSourceNode() {
        let duplicatedSource = NousNode(
            type: .note,
            title: "Memory architecture source",
            content: "Raw duplicate citation content should not be repeated."
        )
        let separateSource = NousNode(
            type: .note,
            title: "Runway source",
            content: "Cash runway still matters."
        )
        let evidence = MemoryEvidenceSnippet(
            label: "Project context",
            sourceNodeId: duplicatedSource.id,
            sourceTitle: duplicatedSource.title,
            snippet: "Memory evidence already carries this source."
        )

        let context = PromptContextAssembler.assembleContext(
            globalMemory: nil,
            memoryEvidence: [evidence],
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [
                SearchResult(node: duplicatedSource, similarity: 0.91),
                SearchResult(node: separateSource, similarity: 0.87)
            ],
            projectGoal: nil
        ).combined

        XCTAssertTrue(context.contains("SHORT SOURCE EVIDENCE FOR THE ABOVE MEMORY"))
        XCTAssertTrue(context.contains("Memory evidence already carries this source."))
        XCTAssertFalse(context.contains("[1] \"Memory architecture source\""),
                       "citation from a source already represented as memory evidence should be filtered")
        XCTAssertFalse(context.contains("Raw duplicate citation content should not be repeated."))
        XCTAssertTrue(context.contains("[1] \"Runway source\""),
                      "remaining citations should be renumbered after filtering")
    }

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

        let context = PromptContextAssembler.assembleContext(
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

        // Verify stoic grounding policy is present
        XCTAssertTrue(context.contains("STOIC GROUNDING POLICY"))
        XCTAssertTrue(context.contains("separate what is in his control from what is not"))
        XCTAssertTrue(context.contains("Do not sound like a philosophy book"))

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
        let context = PromptContextAssembler.assembleContext(
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

    func testCompanionModePrioritizesLivedConversationBeforeAnalysisRegister() {
        let companionContext = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined
        let strategistContext = PromptContextAssembler.assembleContext(
            chatMode: .strategist,
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined

        XCTAssertTrue(companionContext.contains("Lead with lived texture before interpretation"))
        XCTAssertTrue(companionContext.contains("For ordinary life, taste, music, status, and chitchat"))
        XCTAssertTrue(companionContext.contains("friend noticing something"))
        XCTAssertFalse(companionContext.contains("push-back triggers"))
        XCTAssertFalse(strategistContext.contains("Lead with lived texture before interpretation"))
    }

    func testAssembleContextIncludesGraphMemoryRecall() {
        let recall = """
        - Rejected proposal: Build Nous around solving emotions.
          Rejection: Alex rejected solving emotions as unrealistic.
          Reason: Emotions cannot be solved like a mechanical problem.
          Replacement/current direction: Observe and coexist with emotions.
        """

        let context = PromptContextAssembler.assembleContext(
            currentUserInput: "我哋之前否決過邊個方案，點解？",
            globalMemory: nil,
            memoryGraphRecall: [recall],
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            activeQuickActionMode: .plan
        ).combined
        let trace = PromptContextAssembler.governanceTrace(
            currentUserInput: "我哋之前否決過邊個方案，點解？",
            globalMemory: nil,
            memoryGraphRecall: [recall],
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            activeQuickActionMode: .plan
        )

        XCTAssertTrue(context.contains("GRAPH MEMORY RECALL"))
        XCTAssertTrue(context.contains("Build Nous around solving emotions."))
        XCTAssertTrue(context.contains("atoms are claims, chains are decision paths"))
        XCTAssertTrue(trace.promptLayers.contains("memory_graph_recall"))
    }

    func testAssembleContextOmitsGraphMemoryRecallInNormalChat() {
        let recall = "- Rejected proposal: Build Nous around solving emotions."
        let context = PromptContextAssembler.assembleContext(
            currentUserInput: "我哋之前否決過邊個方案，點解？",
            globalMemory: nil,
            memoryGraphRecall: [recall],
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined

        XCTAssertFalse(context.contains("GRAPH MEMORY RECALL"),
                       "normal chat (no activeQuickActionMode) must not surface graph memory recall")
    }

    func testAssembleContextStrategistModeChangesPromptBehaviorWithoutDroppingContinuity() {
        let context = PromptContextAssembler.assembleContext(
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

        let context = PromptContextAssembler.assembleContext(
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
        XCTAssertTrue(context.contains("Temporal memory trigger"))
        XCTAssertTrue(context.contains("not emotional calibration"))
        XCTAssertTrue(context.contains("tension, repetition, drift, decision, or pattern"))
        XCTAssertTrue(context.contains("Do not use old memory as pressure"))
        XCTAssertTrue(context.contains("End with one usable rule, judgment test, or next action"))
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

        let context = PromptContextAssembler.assembleContext(
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
        XCTAssertTrue(context.contains("Temporal memory trigger"))
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

        let context = PromptContextAssembler.assembleContext(
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
        let context = PromptContextAssembler.assembleContext(
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

        let context = PromptContextAssembler.assembleContext(
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

        let context = PromptContextAssembler.assembleContext(
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

        let context = PromptContextAssembler.assembleContext(
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
        let context = PromptContextAssembler.assembleContext(
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
        XCTAssertTrue(context.contains("STOIC GROUNDING POLICY"))
        XCTAssertTrue(context.contains("focus on the next right move"))
    }

    func testAssembleContextIncludesVisibleResponseLanguagePolicy() {
        let context = PromptContextAssembler.assembleContext(
            currentUserInput: "Can you explain this agent harness change in plain English?",
            globalMemory: "- Alex thinks naturally across Cantonese and English.",
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined

        XCTAssertTrue(context.contains("VISIBLE RESPONSE LANGUAGE POLICY"))
        XCTAssertTrue(context.contains("If the current user message is mostly English, answer in English"))
        XCTAssertTrue(context.contains("Do not force Cantonese or Mandarin"))
        XCTAssertFalse(context.contains("or Chinese just because"))
        XCTAssertTrue(context.contains("Keep technical terms in English when they are already English"))
    }

    func testGovernanceTraceIncludesVisibleResponseLanguagePolicyLayer() {
        let trace = PromptContextAssembler.governanceTrace(
            currentUserInput: "Can you explain this agent harness change in plain English?",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(trace.promptLayers.contains("visible_response_language_policy"))
    }

    func testAssembleContextIncludesCurrentVisibleResponseLanguageTargetForEnglish() {
        let context = PromptContextAssembler.assembleContext(
            currentUserInput: "Can you explain this agent harness change in plain English?",
            globalMemory: "- Alex thinks naturally across Cantonese and English.",
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined

        XCTAssertTrue(context.contains("CURRENT VISIBLE RESPONSE LANGUAGE TARGET"))
        XCTAssertTrue(context.contains("Target: English"))
        XCTAssertTrue(context.contains("Do not let internal memory, source labels, or older conversation language override this target."))
    }

    func testGovernanceTraceRecordsMixedVisibleResponseLanguageTarget() {
        let trace = PromptContextAssembler.governanceTrace(
            currentUserInput: "咁开始 V9 language telemetry 啦",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertEqual(trace.visibleResponseLanguageTarget, .mixed)
        XCTAssertEqual(trace.visibleResponseLanguageSource, .currentTurnMixed)
        XCTAssertTrue(trace.promptLayers.contains("visible_response_language_target"))
    }

    func testVisibleResponseLanguageTargetHonorsExplicitEnglishRequest() {
        let trace = PromptContextAssembler.governanceTrace(
            currentUserInput: "呢段帮我用英文解释",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertEqual(trace.visibleResponseLanguageTarget, .english)
        XCTAssertEqual(trace.visibleResponseLanguageSource, .explicitLanguageRequest)
    }

    func testVisibleResponseLanguageTargetHonorsExplicitRequestOverCurrentSurface() {
        let context = PromptContextAssembler.assembleContext(
            currentUserInput: "用英文讲下呢个 language harness",
            globalMemory: "- Alex usually writes to Nous in Cantonese.",
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined
        let trace = PromptContextAssembler.governanceTrace(
            currentUserInput: "用英文讲下呢个 language harness",
            globalMemory: "- Alex usually writes to Nous in Cantonese.",
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertEqual(trace.visibleResponseLanguageTarget, .english)
        XCTAssertEqual(trace.visibleResponseLanguageSource, .explicitLanguageRequest)
        XCTAssertTrue(context.contains("Target: English"))
        XCTAssertTrue(context.contains("Reason: explicit language request"))
    }

    func testVisibleResponseLanguageTargetUsesCurrentCantoneseOverMemory() {
        let context = PromptContextAssembler.assembleContext(
            currentUserInput: "咁呢个语言层系咪会跟住我哋讲嘢",
            globalMemory: "- Alex wants polished English for international users.",
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined
        let trace = PromptContextAssembler.governanceTrace(
            currentUserInput: "咁呢个语言层系咪会跟住我哋讲嘢",
            globalMemory: "- Alex wants polished English for international users.",
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertEqual(trace.visibleResponseLanguageTarget, .cantonese)
        XCTAssertEqual(trace.visibleResponseLanguageSource, .currentTurnCantonese)
        XCTAssertTrue(context.contains("Target: Cantonese"))
        XCTAssertTrue(context.contains("Reason: current message uses Cantonese"))
    }

    func testVisibleResponseLanguageTargetUsesCurrentMandarinOverMemory() {
        let context = PromptContextAssembler.assembleContext(
            currentUserInput: "我们现在继续升级这个语言层",
            globalMemory: "- Alex usually chats in Cantonese and English.",
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined
        let trace = PromptContextAssembler.governanceTrace(
            currentUserInput: "我们现在继续升级这个语言层",
            globalMemory: "- Alex usually chats in Cantonese and English.",
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertEqual(trace.visibleResponseLanguageTarget, .mandarin)
        XCTAssertEqual(trace.visibleResponseLanguageSource, .currentTurnMandarin)
        XCTAssertTrue(context.contains("Target: Mandarin"))
        XCTAssertTrue(context.contains("Reason: current message uses Mandarin"))
    }

    func testVisibleResponseLanguageTargetUsesMandarinInsteadOfGenericChinese() {
        let context = PromptContextAssembler.assembleContext(
            currentUserInput: "请用普通话解释这个 agent harness 升级",
            globalMemory: "- Alex thinks naturally across Cantonese and English.",
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined
        let trace = PromptContextAssembler.governanceTrace(
            currentUserInput: "请用普通话解释这个 agent harness 升级",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertEqual(trace.visibleResponseLanguageTarget, .mandarin)
        XCTAssertEqual(trace.visibleResponseLanguageSource, .explicitLanguageRequest)
        XCTAssertTrue(context.contains("Target: Mandarin"))
        XCTAssertFalse(context.contains("Target: Chinese"))
    }

    func testAssembleContextInvokesHighRiskSafetyModeWhenQueryIsDangerous() {
        let context = PromptContextAssembler.assembleContext(
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
        let trace = PromptContextAssembler.governanceTrace(
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

        let trace = PromptContextAssembler.governanceTrace(
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
        XCTAssertEqual(
            trace.citationTrace,
            CitationTrace(citationCount: 1, longGapCount: 1, minSimilarity: 0.72, maxSimilarity: 0.72)
        )
    }

    func testGovernanceTraceUsesFilteredCitationsAfterMemoryEvidenceCoversSource() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let oldNode = NousNode(
            type: .note,
            title: "Memory source already covered",
            content: "This source is already represented by memory evidence.",
            createdAt: now.addingTimeInterval(-80 * 86_400),
            updatedAt: now.addingTimeInterval(-80 * 86_400)
        )

        let trace = PromptContextAssembler.governanceTrace(
            currentUserInput: "Does this connect to what I said before?",
            globalMemory: nil,
            memoryEvidence: [
                MemoryEvidenceSnippet(
                    label: "Project context",
                    sourceNodeId: oldNode.id,
                    sourceTitle: oldNode.title,
                    snippet: "The evidence already carries this source."
                )
            ],
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [SearchResult(node: oldNode, similarity: 0.75, lane: .longGap)],
            projectGoal: nil,
            now: now
        )

        XCTAssertTrue(trace.promptLayers.contains("memory_evidence"))
        XCTAssertFalse(trace.promptLayers.contains("citations"))
        XCTAssertFalse(trace.promptLayers.contains("long_gap_bridge_guidance"))
        XCTAssertNil(trace.citationTrace)
    }

    func testGovernanceTraceSummarizesFilteredCitationQuality() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let coveredNode = NousNode(
            type: .note,
            title: "Covered source",
            content: "This source is already carried by memory evidence.",
            createdAt: now.addingTimeInterval(-80 * 86_400),
            updatedAt: now.addingTimeInterval(-80 * 86_400)
        )
        let semanticNode = NousNode(
            type: .note,
            title: "Current YC plan",
            content: "Alex is weighing whether to apply to YC this batch.",
            createdAt: now.addingTimeInterval(-10 * 86_400),
            updatedAt: now.addingTimeInterval(-10 * 86_400)
        )
        let longGapNode = NousNode(
            type: .note,
            title: "Old fear pattern",
            content: "Alex hesitated before because public failure felt expensive.",
            createdAt: now.addingTimeInterval(-90 * 86_400),
            updatedAt: now.addingTimeInterval(-90 * 86_400)
        )

        let trace = PromptContextAssembler.governanceTrace(
            currentUserInput: "Should I apply now?",
            globalMemory: nil,
            memoryEvidence: [
                MemoryEvidenceSnippet(
                    label: "Project context",
                    sourceNodeId: coveredNode.id,
                    sourceTitle: coveredNode.title,
                    snippet: "The covered source is already represented."
                )
            ],
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [
                SearchResult(node: coveredNode, similarity: 0.95, lane: .semantic),
                SearchResult(node: semanticNode, similarity: 0.64, lane: .semantic),
                SearchResult(node: longGapNode, similarity: 0.81, lane: .longGap)
            ],
            projectGoal: nil,
            now: now
        )

        XCTAssertEqual(
            trace.citationTrace,
            CitationTrace(citationCount: 2, longGapCount: 1, minSimilarity: 0.64, maxSimilarity: 0.81)
        )
    }

    func testGovernanceTraceOmitsUserModelLayerWhenOnlyPromptUserModelGoalDuplicatesProjectGoal() {
        let trace = PromptContextAssembler.governanceTrace(
            globalMemory: nil,
            userModel: UserModel(
                identity: [],
                goals: ["Ship memory jurisdiction"],
                workStyle: [],
                memoryBoundary: []
            ),
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: "Ship memory jurisdiction"
        )

        XCTAssertTrue(trace.promptLayers.contains("project_goal"))
        XCTAssertFalse(trace.promptLayers.contains("user_model"))
    }

    func testGovernanceTraceUsesFilteredMemoryEvidenceAndRecents() {
        let trace = PromptContextAssembler.governanceTrace(
            globalMemory: nil,
            memoryEvidence: [
                MemoryEvidenceSnippet(
                    label: "Project context",
                    sourceNodeId: UUID(),
                    sourceTitle: "Memory architecture",
                    snippet: "Jurisdiction should prevent duplicate memory claims."
                )
            ],
            projectMemory: "- Jurisdiction should prevent duplicate memory claims.",
            conversationMemory: "- Current chat is about memory jurisdiction.",
            recentConversations: [("Duplicate current chat", "- Current chat is about memory jurisdiction.")],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(trace.promptLayers.contains("project_memory"))
        XCTAssertTrue(trace.promptLayers.contains("conversation_memory"))
        XCTAssertFalse(trace.promptLayers.contains("memory_evidence"))
        XCTAssertFalse(trace.evidenceAttached)
        XCTAssertFalse(trace.promptLayers.contains("recent_conversations"))
    }

    func testGovernanceTraceIncludesStoicGroundingLayer() {
        let trace = PromptContextAssembler.governanceTrace(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(trace.promptLayers.contains("stoic_grounding_policy"))
    }

    func testAssembleContextIncludesIdentityFacetWhenGlobalMemoryIsEmpty() {
        let context = PromptContextAssembler.assembleContext(
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
        let enabled = PromptContextAssembler.assembleContext(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            activeQuickActionMode: .direction,
            allowInteractiveClarification: true
        ).combined
        let disabled = PromptContextAssembler.assembleContext(
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
        XCTAssertTrue(disabled.contains("QUICK MODE QUALITY POLICY"))
    }

    func testInteractiveClarificationOnlyAppliesToPlanAfterOpeningQuestion() {
        let firstReply = [
            Message(nodeId: UUID(), role: .user, content: "I'm stuck between two paths.")
        ]
        let secondReply = [
            Message(nodeId: UUID(), role: .user, content: "I'm stuck between two paths."),
            Message(nodeId: UUID(), role: .assistant, content: "Which two paths?"),
            Message(nodeId: UUID(), role: .user, content: "Staying in school or going all in.")
        ]

        XCTAssertTrue(
            TurnInteractionPolicy.shouldAllowInteractiveClarification(
                activeQuickActionMode: .plan,
                messages: firstReply
            )
        )
        XCTAssertFalse(
            TurnInteractionPolicy.shouldAllowInteractiveClarification(
                activeQuickActionMode: .plan,
                messages: secondReply
            )
        )
        XCTAssertFalse(
            TurnInteractionPolicy.shouldAllowInteractiveClarification(
                activeQuickActionMode: .direction,
                messages: firstReply
            )
        )
        XCTAssertFalse(
            TurnInteractionPolicy.shouldAllowInteractiveClarification(
                activeQuickActionMode: .brainstorm,
                messages: firstReply
            )
        )
        XCTAssertFalse(
            TurnInteractionPolicy.shouldAllowInteractiveClarification(
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

        // Post-L2.5: Direction's turnDirective is turn-based only (.keepActive at
        // turn 0, .complete at turn >= 1). The clarify/understanding/normal content
        // distinctions are now made by the agent's contextAddendum, not the directive.
        // These assertions still hold with turnIndex chosen to match expected outcome.
        XCTAssertEqual(
            TurnInteractionPolicy.updatedQuickActionMode(
                currentMode: .direction,
                assistantContent: clarificationReply,
                turnIndex: 0
            ),
            .direction
        )
        XCTAssertEqual(
            TurnInteractionPolicy.updatedQuickActionMode(
                currentMode: .direction,
                assistantContent: understandingQuestion,
                turnIndex: 0
            ),
            .direction
        )
        XCTAssertNil(
            TurnInteractionPolicy.updatedQuickActionMode(
                currentMode: .direction,
                assistantContent: normalReply,
                turnIndex: 1
            )
        )
    }

    func testQuickActionOpeningPromptStartsWithAssistantQuestioning() {
        let prompt = PlanAgent().openingPrompt()

        XCTAssertTrue(prompt.contains("Start the conversation yourself"))
        XCTAssertTrue(prompt.contains("Ask one short, natural, open-ended question"))
        XCTAssertTrue(prompt.contains("Plan"))
        XCTAssertTrue(prompt.contains("do not use the structured clarification card"))
        XCTAssertTrue(prompt.contains("<phase>understanding</phase>"))
    }

    func testAssembleContextIncludesChatFormatPolicyForQuickActionModes() {
        let context = PromptContextAssembler.assembleContext(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            activeQuickActionMode: .plan
        ).combined
        XCTAssertTrue(context.contains("CHAT FORMAT POLICY"),
                      "quick-action mode must include the chat format policy block")
        XCTAssertTrue(context.contains("`# 标题`"),
                      "policy must list `# 标题` as a literal code example")
        XCTAssertTrue(context.contains("`- bullet`"),
                      "policy must list `- bullet` as a literal code example")
        XCTAssertTrue(context.contains("`| table |`"),
                      "policy must list `| table |` as a literal code example")
        XCTAssertTrue(context.contains("「」"),
                      "policy must reference 「」 emphasis convention")
    }

    func testAssembleContextOmitsChatFormatPolicyInNormalChat() {
        let context = PromptContextAssembler.assembleContext(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        ).combined
        XCTAssertFalse(context.contains("CHAT FORMAT POLICY"),
                       "normal chat (no activeQuickActionMode) must let anchor drive prose register")
    }

    private func assembleLazyLoadSlice(
        loadedSkills: [LoadedSkill],
        matchedSkills: [Skill],
        activeMode: QuickActionMode?
    ) -> TurnSystemSlice {
        PromptContextAssembler.assembleContext(
            globalMemory: "- Alex owns the data layer.",
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            activeQuickActionMode: activeMode,
            loadedSkills: loadedSkills,
            matchedSkills: matchedSkills
        )
    }

    private func makePromptSkill(
        id: UUID = UUID(),
        name: String,
        description: String? = "Use this skill when relevant.",
        useWhen: String? = "Use when this skill is relevant.",
        priority: Int = 70
    ) -> Skill {
        Skill(
            id: id,
            userId: "alex",
            payload: SkillPayload(
                payloadVersion: 2,
                name: name,
                description: description,
                useWhen: useWhen,
                source: .alex,
                trigger: SkillTrigger(
                    kind: .always,
                    modes: [.direction],
                    priority: priority
                ),
                action: SkillAction(
                    kind: .promptFragment,
                    content: "Full content should only appear after loading."
                )
            ),
            state: .active,
            firedCount: 0,
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastModifiedAt: Date(timeIntervalSince1970: 2_000),
            lastFiredAt: nil
        )
    }

    private func sliceSection(_ text: String, header: String) -> String {
        guard let start = text.range(of: header)?.lowerBound else { return "" }
        return String(text[start...])
    }
}
