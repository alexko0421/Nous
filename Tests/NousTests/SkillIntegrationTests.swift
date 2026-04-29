import XCTest
@testable import Nous

@MainActor
final class SkillIntegrationTests: XCTestCase {
    private let skipModeAddendumKey = "AblationSkipModeAddendum"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: skipModeAddendumKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: skipModeAddendumKey)
        super.tearDown()
    }

    func testDirectionOpeningTurnZeroUsesTasteOnlySeedSkills() async throws {
        let seeded = try makeSeededStores()
        let llm = FirstPromptCapturingLLMService(output: "Direction opening")
        let vm = makeViewModel(nodeStore: seeded.nodeStore, skillStore: seeded.skillStore, llm: llm)

        await vm.beginQuickActionConversation(.direction)

        let prompt = llm.firstPromptText
        assertContainsAllTasteSkills(prompt)
        XCTAssertFalse(prompt.contains(directionSkeletonMarker))
        XCTAssertFalse(prompt.contains(brainstormSkeletonMarker))
        XCTAssertTrue(vm.lastPromptGovernanceTrace?.promptLayers.contains("quick_action_addendum") == true)
    }

    func testBrainstormOpeningTurnZeroUsesTasteOnlySeedSkills() async throws {
        let seeded = try makeSeededStores()
        let llm = FirstPromptCapturingLLMService(output: "Brainstorm opening")
        let vm = makeViewModel(nodeStore: seeded.nodeStore, skillStore: seeded.skillStore, llm: llm)

        await vm.beginQuickActionConversation(.brainstorm)

        let prompt = llm.firstPromptText
        assertContainsAllTasteSkills(prompt)
        XCTAssertFalse(prompt.contains(directionSkeletonMarker))
        XCTAssertFalse(prompt.contains(brainstormSkeletonMarker))
        XCTAssertTrue(vm.lastPromptGovernanceTrace?.promptLayers.contains("quick_action_addendum") == true)
    }

    func testPlanOpeningTurnZeroUsesAllTasteSkillsWithoutPlanContract() async throws {
        let seeded = try makeSeededStores()
        let llm = FirstPromptCapturingLLMService(output: "Plan opening")
        let vm = makeViewModel(nodeStore: seeded.nodeStore, skillStore: seeded.skillStore, llm: llm)

        await vm.beginQuickActionConversation(.plan)

        let prompt = llm.firstPromptText
        assertContainsAllTasteSkills(prompt)
        XCTAssertFalse(prompt.contains("TURN 1 CONTRACT"))
        XCTAssertFalse(prompt.contains("PLAN MODE PRODUCTION CONTRACT"))
        XCTAssertFalse(prompt.contains("FINAL TURN"))
        XCTAssertTrue(vm.lastPromptGovernanceTrace?.promptLayers.contains("quick_action_addendum") == true)
    }

    func testDirectionTurnOneUsesSkeletonAndTopFourTasteSkills() async throws {
        let plan = try await plan(
            explicitMode: .direction,
            route: .direction,
            responseShape: .narrowNextStep,
            userTurnCount: 1
        )

        let prompt = plan.turnSlice.volatile
        XCTAssertTrue(prompt.contains(directionSkeletonMarker))
        XCTAssertFalse(prompt.contains(brainstormSkeletonMarker))
        assertContainsTopFourTasteSkills(prompt)
        XCTAssertFalse(prompt.contains(weightAgainstDefaultChatBaselineMarker))
        XCTAssertTrue(plan.promptTrace.promptLayers.contains("quick_action_addendum"))
    }

    func testBrainstormTurnOneUsesSkeletonAndTopFourTasteSkills() async throws {
        let plan = try await plan(
            explicitMode: .brainstorm,
            route: .brainstorm,
            responseShape: .listDirections,
            userTurnCount: 1
        )

        let prompt = plan.turnSlice.volatile
        XCTAssertTrue(prompt.contains(brainstormSkeletonMarker))
        XCTAssertFalse(prompt.contains(directionSkeletonMarker))
        assertContainsTopFourTasteSkills(prompt)
        XCTAssertFalse(prompt.contains(weightAgainstDefaultChatBaselineMarker))
        XCTAssertTrue(plan.promptTrace.promptLayers.contains("quick_action_addendum"))
    }

    func testPlanTurnsKeepStateMachineAddendumAndAppendTasteSkills() async throws {
        let turn1 = try await plan(
            explicitMode: .plan,
            route: .plan,
            responseShape: .askOneQuestion,
            userTurnCount: 1
        )
        XCTAssertTrue(turn1.turnSlice.volatile.contains("TURN 1 CONTRACT"))
        XCTAssertTrue(turn1.turnSlice.volatile.contains("best-guess outcome"))
        assertContainsAllTasteSkills(turn1.turnSlice.volatile)

        let turn2 = try await plan(
            explicitMode: .plan,
            route: .plan,
            responseShape: .producePlan,
            userTurnCount: 2
        )
        XCTAssertTrue(turn2.turnSlice.volatile.contains("PLAN MODE PRODUCTION CONTRACT"))
        XCTAssertTrue(turn2.turnSlice.volatile.contains("# Weekly schedule"))
        assertContainsAllTasteSkills(turn2.turnSlice.volatile)

        let turn3 = try await plan(
            explicitMode: .plan,
            route: .plan,
            responseShape: .producePlan,
            userTurnCount: 3
        )
        XCTAssertTrue(turn3.turnSlice.volatile.contains("PLAN MODE PRODUCTION CONTRACT"))
        assertContainsAllTasteSkills(turn3.turnSlice.volatile)

        let turn4 = try await plan(
            explicitMode: .plan,
            route: .plan,
            responseShape: .producePlan,
            userTurnCount: 4
        )
        XCTAssertTrue(turn4.turnSlice.volatile.contains("FINAL TURN"))
        XCTAssertFalse(turn4.turnSlice.volatile.contains("PLAN MODE PRODUCTION CONTRACT"))
        assertContainsAllTasteSkills(turn4.turnSlice.volatile)
    }

    func testStewardInferredDirectionUsesInferredModeSkeletonAtTurnOne() async throws {
        let plan = try await plan(
            explicitMode: nil,
            route: .direction,
            responseShape: .narrowNextStep,
            userTurnCount: 1
        )

        let prompt = plan.turnSlice.volatile
        XCTAssertTrue(prompt.contains(directionSkeletonMarker))
        assertContainsTopFourTasteSkills(prompt)
        XCTAssertFalse(prompt.contains(weightAgainstDefaultChatBaselineMarker))
        XCTAssertTrue(plan.promptTrace.promptLayers.contains("quick_action_addendum"))
    }

    func testDefaultChatDoesNotFireSkills() async throws {
        let plan = try await plan(
            explicitMode: nil,
            route: .ordinaryChat,
            responseShape: .answerNow,
            userTurnCount: 1
        )

        let prompt = plan.turnSlice.volatile
        XCTAssertFalse(prompt.contains(directionSkeletonMarker))
        XCTAssertFalse(prompt.contains(brainstormSkeletonMarker))
        assertContainsNoTasteSkills(prompt)
        XCTAssertFalse(plan.promptTrace.promptLayers.contains("quick_action_addendum"))
    }

    func testDebugAblationSkipModeAddendumFallsBackToPlanAgentAddendumOnly() async throws {
        UserDefaults.standard.set(true, forKey: skipModeAddendumKey)
        defer { UserDefaults.standard.removeObject(forKey: skipModeAddendumKey) }

        let plan = try await plan(
            explicitMode: .plan,
            route: .plan,
            responseShape: .askOneQuestion,
            userTurnCount: 1
        )

        let prompt = plan.turnSlice.volatile
        XCTAssertTrue(prompt.contains("TURN 1 CONTRACT"))
        assertContainsNoTasteSkills(prompt)
        XCTAssertFalse(prompt.contains(directionSkeletonMarker))
        XCTAssertFalse(prompt.contains(brainstormSkeletonMarker))
        XCTAssertTrue(plan.promptTrace.promptLayers.contains("quick_action_addendum"))
    }

    func testSkillTraceLinesIncludeModePriorityAndFireCount() {
        #if DEBUG
        let skill = Skill(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            userId: "alex",
            payload: SkillPayload(
                payloadVersion: 1,
                name: "trace-skill",
                source: .alex,
                trigger: SkillTrigger(kind: .always, modes: [.direction], priority: 70),
                action: SkillAction(kind: .promptFragment, content: "Trace content")
            ),
            state: .active,
            firedCount: 12,
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastModifiedAt: Date(timeIntervalSince1970: 1_000),
            lastFiredAt: nil
        )

        let lines = SkillTraceLogger.lines(
            matched: [skill],
            mode: .direction,
            turnIndex: 17
        )

        XCTAssertEqual(lines[0], "[SkillTrace] Turn 17 (mode: direction)")
        XCTAssertEqual(lines[1], "  Active skills (1 fired):")
        XCTAssertEqual(lines[2], "  - trace-skill (priority 70, fired 12 times)")
        #endif
    }

    private func plan(
        explicitMode: QuickActionMode?,
        route: TurnRoute,
        responseShape: ResponseShape,
        userTurnCount: Int
    ) async throws -> TurnPlan {
        let seeded = try makeSeededStores()
        let planner = makePlanner(nodeStore: seeded.nodeStore, skillStore: seeded.skillStore)
        let prepared = preparedTurn(userTurnCount: userTurnCount)
        return try await planner.plan(
            from: prepared,
            request: request(input: "Need help", activeQuickActionMode: explicitMode),
            stewardship: TurnStewardDecision(
                route: route,
                memoryPolicy: .lean,
                challengeStance: .surfaceTension,
                responseShape: responseShape,
                source: .deterministic,
                reason: "skill integration test"
            )
        )
    }

    private func makeSeededStores() throws -> (nodeStore: NodeStore, skillStore: SkillStore) {
        let nodeStore = try NodeStore(path: ":memory:")
        let skillStore = SkillStore(nodeStore: nodeStore)
        let dates = Date(timeIntervalSince1970: 10_000)

        for row in try decodeSeedRows() {
            try skillStore.insertSkill(
                Skill(
                    id: row.id,
                    userId: row.userId,
                    payload: row.payload,
                    state: row.state,
                    firedCount: 0,
                    createdAt: dates,
                    lastModifiedAt: dates,
                    lastFiredAt: nil
                )
            )
        }

        return (nodeStore, skillStore)
    }

    private func makePlanner(nodeStore: NodeStore, skillStore: SkillStore) -> TurnPlanner {
        let core = UserMemoryCore(nodeStore: nodeStore, llmServiceProvider: { nil })
        return TurnPlanner(
            nodeStore: nodeStore,
            vectorStore: VectorStore(nodeStore: nodeStore),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(core: core),
            contradictionMemoryService: ContradictionMemoryService(core: core),
            currentProviderProvider: { .gemini },
            judgeLLMServiceFactory: { nil },
            skillStore: skillStore,
            skillMatcher: SkillMatcher(),
            skillTracker: nil
        )
    }

    private func makeViewModel(
        nodeStore: NodeStore,
        skillStore: SkillStore,
        llm: FirstPromptCapturingLLMService
    ) -> ChatViewModel {
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let suiteName = "SkillIntegrationTests.scratchpad.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        return ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: EmbeddingService(),
            graphEngine: GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore),
            userMemoryService: userMemoryService,
            userMemoryScheduler: UserMemoryScheduler(service: userMemoryService),
            llmServiceProvider: { llm },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            skillStore: skillStore,
            skillMatcher: SkillMatcher(),
            skillTracker: nil,
            scratchPadStore: ScratchPadStore(nodeStore: nodeStore, defaults: defaults)
        )
    }

    private func preparedTurn(userTurnCount: Int) -> PreparedTurnSession {
        let node = NousNode(type: .conversation, title: "Skill integration test")
        var messages: [Message] = []
        var lastUserMessage: Message?

        for index in 1...max(userTurnCount, 1) {
            if index > 1 {
                messages.append(Message(nodeId: node.id, role: .assistant, content: "Assistant \(index - 1)"))
            }
            let userMessage = Message(nodeId: node.id, role: .user, content: "User \(index)")
            messages.append(userMessage)
            lastUserMessage = userMessage
        }

        return PreparedConversationTurn(
            node: node,
            userMessage: lastUserMessage!,
            messagesAfterUserAppend: messages
        )
    }

    private func request(
        input: String,
        activeQuickActionMode: QuickActionMode?
    ) -> TurnRequest {
        TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: nil,
                messages: [],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: activeQuickActionMode
            ),
            inputText: input,
            attachments: [],
            now: Date(timeIntervalSince1970: 20_000)
        )
    }

    private func decodeSeedRows() throws -> [SeedSkillRow] {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("Sources/Nous/Resources/seed-skills.json")
        return try JSONDecoder().decode([SeedSkillRow].self, from: Data(contentsOf: url))
    }

    private func assertContainsAllTasteSkills(
        _ prompt: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for marker in tasteSkillMarkers {
            XCTAssertTrue(prompt.contains(marker), "Missing taste marker: \(marker)", file: file, line: line)
        }
    }

    private func assertContainsTopFourTasteSkills(
        _ prompt: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for marker in Array(tasteSkillMarkers.prefix(4)) {
            XCTAssertTrue(prompt.contains(marker), "Missing taste marker: \(marker)", file: file, line: line)
        }
    }

    private func assertContainsNoTasteSkills(
        _ prompt: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for marker in tasteSkillMarkers {
            XCTAssertFalse(prompt.contains(marker), "Unexpected taste marker: \(marker)", file: file, line: line)
        }
    }

    private var directionSkeletonMarker: String {
        "DIRECTION MODE QUALITY CONTRACT"
    }

    private var brainstormSkeletonMarker: String {
        "BRAINSTORM MODE QUALITY CONTRACT"
    }

    private var weightAgainstDefaultChatBaselineMarker: String {
        "Do not ask filler questions when you can make a useful judgment"
    }

    private var tasteSkillMarkers: [String] {
        [
            "Speak as a stoic Cantonese mentor",
            "Use specific files, function names, real numbers",
            "If Alex's framing is wrong",
            "Use Cantonese for warmth, judgment, and product taste",
            weightAgainstDefaultChatBaselineMarker
        ]
    }
}

private final class FirstPromptCapturingLLMService: LLMService {
    private let lock = NSLock()
    private let output: String
    private var didCaptureFirstPrompt = false
    private var storedFirstSystem: String?
    private var storedFirstMessages: [LLMMessage] = []

    var firstPromptText: String {
        lock.withLock {
            ([storedFirstSystem ?? ""] + storedFirstMessages.map(\.content))
                .joined(separator: "\n\n")
        }
    }

    init(output: String) {
        self.output = output
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        lock.withLock {
            if !didCaptureFirstPrompt {
                didCaptureFirstPrompt = true
                storedFirstSystem = system
                storedFirstMessages = messages
            }
        }

        let output = self.output
        return AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}
