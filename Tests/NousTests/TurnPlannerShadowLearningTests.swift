import XCTest
@testable import Nous

final class TurnPlannerShadowLearningTests: XCTestCase {
    func testPlannerAddsShadowHintsToPromptTraceAndVolatilePrompt() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let planner = makePlanner(
            nodeStore: nodeStore,
            shadowPatternPromptProvider: FixedShadowPromptProvider(hints: ["Use pain test."])
        )
        let node = NousNode(type: .conversation, title: "Shadow prompt")
        let message = Message(nodeId: node.id, role: .user, content: "Should we build this product feature?")
        let prepared = PreparedConversationTurn(node: node, userMessage: message, messagesAfterUserAppend: [message])
        let request = TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: node,
                messages: [message],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: .plan
            ),
            inputText: message.content,
            attachments: [],
            now: Date(timeIntervalSince1970: 4_000)
        )
        let stewardship = TurnStewardDecision(
            route: .plan,
            memoryPolicy: .lean,
            challengeStance: .surfaceTension,
            responseShape: .producePlan,
            source: .deterministic,
            reason: "test"
        )

        let plan = try await planner.plan(from: prepared, request: request, stewardship: stewardship)

        XCTAssertTrue(plan.turnSlice.volatile.contains("SHADOW THINKING HINTS:"))
        XCTAssertTrue(plan.turnSlice.volatile.contains("- Use pain test."))
        XCTAssertTrue(plan.promptTrace.promptLayers.contains("shadow_learning"))
    }

    func testPlannerSwallowsShadowProviderErrors() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let planner = makePlanner(
            nodeStore: nodeStore,
            shadowPatternPromptProvider: ThrowingShadowPromptProvider()
        )
        let node = NousNode(type: .conversation, title: "Shadow prompt")
        let message = Message(nodeId: node.id, role: .user, content: "Should we build this product feature?")
        let prepared = PreparedConversationTurn(node: node, userMessage: message, messagesAfterUserAppend: [message])
        let request = TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: node,
                messages: [message],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: .plan
            ),
            inputText: message.content,
            attachments: [],
            now: Date(timeIntervalSince1970: 4_000)
        )
        let stewardship = TurnStewardDecision(
            route: .plan,
            memoryPolicy: .lean,
            challengeStance: .surfaceTension,
            responseShape: .producePlan,
            source: .deterministic,
            reason: "test"
        )

        let plan = try await planner.plan(from: prepared, request: request, stewardship: stewardship)

        XCTAssertFalse(plan.turnSlice.volatile.contains("SHADOW THINKING HINTS:"))
        XCTAssertFalse(plan.promptTrace.promptLayers.contains("shadow_learning"))
    }

    func testPlannerAddsSlowCognitionArtifactsToPromptTraceAndVolatilePrompt() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let artifact = CognitionArtifact(
            organ: .patternAnalyst,
            title: "Long-term mind",
            summary: "Nous should stay a long-term mind rather than an agent workflow tool.",
            confidence: 0.82,
            jurisdiction: .selfReflection,
            evidenceRefs: [
                CognitionEvidenceRef(source: .message, id: UUID().uuidString, quote: "long-term mind")
            ],
            suggestedSurfacing: "Use when the turn is about long-term product direction."
        )
        let planner = makePlanner(
            nodeStore: nodeStore,
            slowCognitionArtifactProvider: FixedSlowCognitionArtifactProvider(artifacts: [artifact])
        )
        let node = NousNode(type: .conversation, title: "Long-turn vision")
        let message = Message(nodeId: node.id, role: .user, content: "How should we build this long-term mind?")
        let prepared = PreparedConversationTurn(node: node, userMessage: message, messagesAfterUserAppend: [message])
        let request = self.request(input: message.content, node: node)
        let stewardship = TurnStewardDecision(
            route: .ordinaryChat,
            memoryPolicy: .full,
            challengeStance: .useSilently,
            responseShape: .answerNow,
            source: .deterministic,
            reason: "test"
        )

        let plan = try await planner.plan(from: prepared, request: request, stewardship: stewardship)

        XCTAssertTrue(plan.turnSlice.volatile.contains("SLOW COGNITION SIGNAL:"))
        XCTAssertTrue(plan.turnSlice.volatile.contains(artifact.summary))
        XCTAssertTrue(plan.promptTrace.promptLayers.contains("slow_cognition"))

        let manifest = ContextManifestFactory.make(
            plan: plan,
            assistantMessageId: UUID(),
            assistantContent: "That points back to the long-term mind signal: \(artifact.summary)",
            agentTraceJson: nil
        )
        XCTAssertTrue(manifest.resources.contains(ContextManifestResource(
            source: .memory,
            label: "slow_cognition",
            referenceId: "slow_cognition",
            state: .loaded,
            used: true
        )))

        let encodedManifest = String(data: try JSONEncoder().encode(manifest), encoding: .utf8) ?? ""
        XCTAssertFalse(encodedManifest.contains(artifact.summary))
        XCTAssertFalse(encodedManifest.contains("long-term product direction"))
    }

    func testPlannerSkipsSlowCognitionArtifactsWhenMemoryPolicyIsLean() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let artifact = CognitionArtifact(
            organ: .patternAnalyst,
            title: "Long-term mind",
            summary: "Nous should stay a long-term mind rather than an agent workflow tool.",
            confidence: 0.82,
            jurisdiction: .selfReflection,
            evidenceRefs: [
                CognitionEvidenceRef(source: .message, id: UUID().uuidString, quote: "long-term mind")
            ],
            suggestedSurfacing: "Use when the turn is about long-term product direction."
        )
        let planner = makePlanner(
            nodeStore: nodeStore,
            slowCognitionArtifactProvider: FixedSlowCognitionArtifactProvider(artifacts: [artifact])
        )
        let node = NousNode(type: .conversation, title: "Long-turn vision")
        let message = Message(nodeId: node.id, role: .user, content: "How should we build this long-term mind?")
        let prepared = PreparedConversationTurn(node: node, userMessage: message, messagesAfterUserAppend: [message])
        let request = self.request(input: message.content, node: node)
        let stewardship = TurnStewardDecision(
            route: .ordinaryChat,
            memoryPolicy: .lean,
            challengeStance: .useSilently,
            responseShape: .answerNow,
            source: .deterministic,
            reason: "test"
        )

        let plan = try await planner.plan(from: prepared, request: request, stewardship: stewardship)

        XCTAssertFalse(plan.turnSlice.volatile.contains("SLOW COGNITION SIGNAL:"))
        XCTAssertFalse(plan.turnSlice.volatile.contains(artifact.summary))
        XCTAssertFalse(plan.promptTrace.promptLayers.contains("slow_cognition"))
        XCTAssertNil(plan.promptTrace.slowCognitionTrace)
    }

    func testSoftAnalysisRunsJudgeSilentlyWithoutVisibleThinkingOrFocusBlock() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let judgeLLM = TrackingThinkingLLMService()
        let judge = CountingJudge()
        let planner = makePlanner(
            nodeStore: nodeStore,
            judgeLLMServiceFactory: { judgeLLM },
            provocationJudgeFactory: { _ in judge }
        )
        let node = NousNode(type: .conversation, title: "Soft analysis")
        let message = Message(nodeId: node.id, role: .user, content: "帮我分析下呢件事应该点做")
        let prepared = PreparedConversationTurn(node: node, userMessage: message, messagesAfterUserAppend: [message])
        let request = self.request(input: message.content, node: node)
        let stewardship = TurnStewardDecision(
            route: .ordinaryChat,
            memoryPolicy: .full,
            challengeStance: .useSilently,
            responseShape: .answerNow,
            source: .deterministic,
            reason: "soft analysis cue",
            responseStance: .softAnalysis,
            judgePolicy: .silentFraming,
            routerMode: .active,
            routerSource: .deterministic
        )

        var visibleThinkingDeltaCount = 0
        let plan = try await planner.plan(
            from: prepared,
            request: request,
            stewardship: stewardship,
            judgeThinkingHandler: { _ in visibleThinkingDeltaCount += 1 }
        )

        XCTAssertEqual(judgeLLM.thinkingHandlerInstallCount, 0)
        XCTAssertEqual(visibleThinkingDeltaCount, 0)
        XCTAssertEqual(judge.callCount, 1)
        XCTAssertFalse(plan.turnSlice.volatile.contains("RELEVANT PRIOR MEMORY"))
        XCTAssertNil(plan.focusBlock)
    }

    func testJudgeKeepsReasoningBudgetWhenThinkingTraceIsHidden() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let judge = CountingJudge()
        var configuredThinkingBudget: Int?
        var configuredThinkingHandler: ThinkingDeltaHandler?
        let planner = makePlanner(
            nodeStore: nodeStore,
            judgeLLMServiceFactory: {
                ClaudeLLMService(apiKey: "test-key")
            },
            provocationJudgeFactory: { llm in
                let claude = llm as? ClaudeLLMService
                configuredThinkingBudget = claude?.thinkingBudgetTokens
                configuredThinkingHandler = claude?.onThinkingDelta
                return judge
            }
        )
        let node = NousNode(type: .conversation, title: "Hidden thinking")
        let message = Message(nodeId: node.id, role: .user, content: "帮我判断下一步应该点做")
        let prepared = PreparedConversationTurn(node: node, userMessage: message, messagesAfterUserAppend: [message])
        let request = self.request(input: message.content, node: node)
        let stewardship = TurnStewardDecision(
            route: .ordinaryChat,
            memoryPolicy: .full,
            challengeStance: .surfaceTension,
            responseShape: .answerNow,
            source: .deterministic,
            reason: "test",
            responseStance: .softAnalysis,
            judgePolicy: .visibleTension,
            routerMode: .active,
            routerSource: .deterministic
        )

        _ = try await planner.plan(from: prepared, request: request, stewardship: stewardship)

        XCTAssertEqual(configuredThinkingBudget, 1024)
        XCTAssertNil(configuredThinkingHandler)
        XCTAssertEqual(judge.callCount, 1)
    }

    func testGeminiJudgeThinkingBudgetMatchesModelHarnessProfile() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let judge = CountingJudge()
        var hiddenThinkingBudget: Int?
        var visibleThinkingBudget: Int?
        let expectedBudget = ModelHarnessProfileCatalog.profile(for: .gemini).thinkingBudgetTokens

        let hiddenPlanner = makePlanner(
            nodeStore: nodeStore,
            judgeLLMServiceFactory: {
                GeminiLLMService(apiKey: "test-key")
            },
            provocationJudgeFactory: { llm in
                hiddenThinkingBudget = (llm as? GeminiLLMService)?.thinkingBudgetTokens
                return judge
            }
        )
        let node = NousNode(type: .conversation, title: "Gemini hidden thinking")
        let message = Message(nodeId: node.id, role: .user, content: "帮我判断下一步应该点做")
        let prepared = PreparedConversationTurn(node: node, userMessage: message, messagesAfterUserAppend: [message])
        let request = self.request(input: message.content, node: node)
        let stewardship = TurnStewardDecision(
            route: .ordinaryChat,
            memoryPolicy: .full,
            challengeStance: .surfaceTension,
            responseShape: .answerNow,
            source: .deterministic,
            reason: "test",
            responseStance: .softAnalysis,
            judgePolicy: .visibleTension,
            routerMode: .active,
            routerSource: .deterministic
        )

        _ = try await hiddenPlanner.plan(from: prepared, request: request, stewardship: stewardship)

        let visiblePlanner = makePlanner(
            nodeStore: nodeStore,
            judgeLLMServiceFactory: {
                GeminiLLMService(apiKey: "test-key")
            },
            provocationJudgeFactory: { llm in
                visibleThinkingBudget = (llm as? GeminiLLMService)?.thinkingBudgetTokens
                return judge
            }
        )

        _ = try await visiblePlanner.plan(
            from: prepared,
            request: request,
            stewardship: stewardship,
            judgeThinkingHandler: { _ in }
        )

        XCTAssertEqual(hiddenThinkingBudget, expectedBudget)
        XCTAssertEqual(visibleThinkingBudget, expectedBudget)
    }

    func testPlanRouteUsesSingleTurnGuidanceBlockForResponseShape() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let planner = makePlanner(
            nodeStore: nodeStore,
            judgeLLMServiceFactory: { nil },
            provocationJudgeFactory: { _ in CountingJudge() }
        )
        let node = NousNode(type: .conversation, title: "Plan route")
        let message = Message(nodeId: node.id, role: .user, content: "help me plan this week")
        let prepared = PreparedConversationTurn(node: node, userMessage: message, messagesAfterUserAppend: [message])
        let request = self.request(input: message.content, node: node)
        let stewardship = TurnStewardDecision(
            route: .plan,
            memoryPolicy: .full,
            challengeStance: .surfaceTension,
            responseShape: .producePlan,
            source: .deterministic,
            reason: "explicit plan cue",
            responseStance: .softAnalysis,
            judgePolicy: .visibleTension,
            routerMode: .active,
            routerSource: .deterministic
        )

        let plan = try await planner.plan(from: prepared, request: request, stewardship: stewardship)

        XCTAssertTrue(plan.turnSlice.volatile.contains("TURN GUIDANCE:"))
        XCTAssertTrue(plan.turnSlice.volatile.contains("Response shape: Produce a concrete structured plan. Do not stay in coaching mode."))
        XCTAssertFalse(plan.turnSlice.volatile.contains("TURN STEWARD RESPONSE SHAPE:"))
        XCTAssertFalse(plan.turnSlice.volatile.contains("RESPONSE STANCE:"))
    }

    func testTurnGuidanceCollapsesShapeAndStanceIntoSingleVolatileBlock() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let planner = makePlanner(
            nodeStore: nodeStore,
            judgeLLMServiceFactory: { nil },
            provocationJudgeFactory: { _ in CountingJudge() }
        )
        let node = NousNode(type: .conversation, title: "Ordinary turn")
        let message = Message(nodeId: node.id, role: .user, content: "Should I do this or not?")
        let prepared = PreparedConversationTurn(node: node, userMessage: message, messagesAfterUserAppend: [message])
        let request = self.request(input: message.content, node: node)
        let stewardship = TurnStewardDecision(
            route: .ordinaryChat,
            memoryPolicy: .full,
            challengeStance: .useSilently,
            responseShape: .askOneQuestion,
            source: .deterministic,
            reason: "test combined guidance",
            responseStance: .softAnalysis,
            judgePolicy: .silentFraming,
            routerMode: .active,
            routerSource: .deterministic
        )

        let plan = try await planner.plan(from: prepared, request: request, stewardship: stewardship)

        XCTAssertEqual(plan.turnSlice.volatile.components(separatedBy: "TURN GUIDANCE:").count - 1, 1)
        XCTAssertTrue(plan.turnSlice.volatile.contains("Response shape: Ask exactly one short question before giving guidance. Do not include a clarification card."))
        XCTAssertTrue(plan.turnSlice.volatile.contains("Response stance: Give calm tradeoff analysis. Use any judge-derived framing silently. Do not mention judge thinking, contradiction checks, or turn the reply into a hard challenge."))
        XCTAssertFalse(plan.turnSlice.volatile.contains("TURN STEWARD RESPONSE SHAPE:"))
        XCTAssertFalse(plan.turnSlice.volatile.contains("RESPONSE STANCE:"))
    }

    private func makePlanner(
        nodeStore: NodeStore,
        shadowPatternPromptProvider: (any ShadowPatternPromptProviding)?
    ) -> TurnPlanner {
        makePlanner(
            nodeStore: nodeStore,
            judgeLLMServiceFactory: { nil },
            provocationJudgeFactory: { _ in CountingJudge() },
            shadowPatternPromptProvider: shadowPatternPromptProvider
        )
    }

    private func makePlanner(
        nodeStore: NodeStore,
        slowCognitionArtifactProvider: (any SlowCognitionArtifactProviding)?
    ) -> TurnPlanner {
        makePlanner(
            nodeStore: nodeStore,
            judgeLLMServiceFactory: { nil },
            provocationJudgeFactory: { _ in CountingJudge() },
            slowCognitionArtifactProvider: slowCognitionArtifactProvider
        )
    }

    private func makePlanner(
        nodeStore: NodeStore,
        judgeLLMServiceFactory: @escaping () -> (any LLMService)?,
        provocationJudgeFactory: @escaping (any LLMService) -> any Judging,
        shadowPatternPromptProvider: (any ShadowPatternPromptProviding)? = nil,
        slowCognitionArtifactProvider: (any SlowCognitionArtifactProviding)? = nil
    ) -> TurnPlanner {
        let core = UserMemoryCore(nodeStore: nodeStore, llmServiceProvider: { nil })
        return TurnPlanner(
            nodeStore: nodeStore,
            vectorStore: VectorStore(nodeStore: nodeStore),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(nodeStore: nodeStore),
            contradictionMemoryService: ContradictionMemoryService(core: core),
            currentProviderProvider: { .gemini },
            judgeLLMServiceFactory: judgeLLMServiceFactory,
            provocationJudgeFactory: provocationJudgeFactory,
            shadowPatternPromptProvider: shadowPatternPromptProvider,
            slowCognitionArtifactProvider: slowCognitionArtifactProvider
        )
    }

    private func request(input: String, node: NousNode) -> TurnRequest {
        TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: node,
                messages: [],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: nil
            ),
            inputText: input,
            attachments: [],
            now: Date(timeIntervalSince1970: 4_000)
        )
    }
}

private struct FixedShadowPromptProvider: ShadowPatternPromptProviding {
    let hints: [String]

    func promptHints(
        userId: String,
        currentInput: String,
        activeQuickActionMode: QuickActionMode?,
        now: Date
    ) throws -> [String] {
        hints
    }
}

private struct ThrowingShadowPromptProvider: ShadowPatternPromptProviding {
    func promptHints(
        userId: String,
        currentInput: String,
        activeQuickActionMode: QuickActionMode?,
        now: Date
    ) throws -> [String] {
        throw ShadowPromptTestError.expected
    }
}

private struct FixedSlowCognitionArtifactProvider: SlowCognitionArtifactProviding {
    let artifacts: [CognitionArtifact]

    func artifacts(
        userId: String,
        currentInput: String,
        currentNode: NousNode,
        projectId: UUID?,
        now: Date
    ) throws -> [CognitionArtifact] {
        artifacts
    }
}

private enum ShadowPromptTestError: Error {
    case expected
}

private final class TrackingThinkingLLMService: LLMService, ThinkingDeltaConfigurableLLMService {
    private(set) var thinkingHandlerInstallCount = 0

    func withThinkingDeltaHandler(_ handler: @escaping ThinkingDeltaHandler) -> any LLMService {
        thinkingHandlerInstallCount += 1
        return self
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("{}")
            continuation.finish()
        }
    }
}

private final class CountingJudge: Judging {
    private(set) var callCount = 0

    func judge(
        userMessage: String,
        citablePool: [CitableEntry],
        previousMode: ChatMode?,
        provider: LLMProvider,
        feedbackLoop: JudgeFeedbackLoop?
    ) async throws -> JudgeVerdict {
        callCount += 1
        return JudgeVerdict(
            tensionExists: false,
            userState: .deciding,
            shouldProvoke: false,
            entryId: nil,
            reason: "soft framing only",
            inferredMode: .strategist
        )
    }
}
