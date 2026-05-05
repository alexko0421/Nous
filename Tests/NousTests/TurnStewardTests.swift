import XCTest
@testable import Nous

final class TurnStewardTests: XCTestCase {
    private let steward = TurnSteward()

    func testRouterModeDefaultsToShadowAndCanBeFlippedWithDefaults() {
        let suiteName = "TurnStewardTests.router-mode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(ResponseStanceRouterMode.current(defaults: defaults), .shadow)

        defaults.set(ResponseStanceRouterMode.active.rawValue, forKey: ResponseStanceRouterMode.userDefaultsKey)
        XCTAssertEqual(ResponseStanceRouterMode.current(defaults: defaults), .active)

        defaults.set("not-a-mode", forKey: ResponseStanceRouterMode.userDefaultsKey)
        XCTAssertEqual(ResponseStanceRouterMode.current(defaults: defaults), .shadow)
    }

    func testActiveQuickActionWins() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "brainstorm something else"),
            request: request(input: "brainstorm something else", activeQuickActionMode: .plan)
        )

        XCTAssertEqual(decision.route, .plan)
        XCTAssertEqual(decision.memoryPolicy, .full)
        XCTAssertEqual(decision.responseShape, .producePlan)
        XCTAssertEqual(decision.trace.reason, "active quick action mode")
    }

    func testExplicitBrainstormRoutesLean() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "brainstorm a few ideas"),
            request: request(input: "brainstorm a few ideas")
        )

        XCTAssertEqual(decision.route, .brainstorm)
        XCTAssertEqual(decision.memoryPolicy, .lean)
        XCTAssertEqual(decision.challengeStance, .useSilently)
        XCTAssertEqual(decision.responseShape, .listDirections)
    }

    func testExplicitPlanRoutesFullAndProducePlan() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "help me plan this week"),
            request: request(input: "help me plan this week")
        )

        XCTAssertEqual(decision.route, .plan)
        XCTAssertEqual(decision.memoryPolicy, .full)
        XCTAssertEqual(decision.challengeStance, .surfaceTension)
        XCTAssertEqual(decision.responseShape, .producePlan)
    }

    func testExplicitDirectionRoutesFullAndNarrowNextStep() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "what is my next step"),
            request: request(input: "what is my next step")
        )

        XCTAssertEqual(decision.route, .direction)
        XCTAssertEqual(decision.memoryPolicy, .full)
        XCTAssertEqual(decision.challengeStance, .surfaceTension)
        XCTAssertEqual(decision.responseShape, .narrowNextStep)
    }

    func testSourceMaterialsRouteToSourceAnalysis() {
        let sourceNodeId = UUID()
        let decision = steward.steer(
            prepared: preparedTurn(userText: "what connects here?"),
            request: request(
                input: "what connects here?",
                sourceMaterials: [
                    SourceMaterialContext(
                        sourceNodeId: sourceNodeId,
                        title: "External essay",
                        originalURL: "https://example.com/essay",
                        originalFilename: nil,
                        chunks: [
                            SourceChunkContext(
                                sourceNodeId: sourceNodeId,
                                ordinal: 0,
                                text: "External essay chunk about connecting ideas.",
                                similarity: nil
                            )
                        ]
                    )
                ]
            )
        )

        XCTAssertEqual(decision.route, .sourceAnalysis)
        XCTAssertEqual(decision.memoryPolicy, .full)
        XCTAssertEqual(decision.responseShape, .answerNow)
        XCTAssertEqual(decision.supervisorLanes, [.source, .memory, .project, .analytics, .reflection])
        XCTAssertEqual(decision.trace.supervisorLanes, decision.supervisorLanes)
    }

    func testActiveSupportFirstRouterDoesNotEraseSourceAnalysisLane() async {
        let sourceNodeId = UUID()
        let decision = await TurnSteward(
            routerModeProvider: { .active }
        ).steerForTurn(
            prepared: preparedTurn(userText: "我好焦虑，帮我 connect this source"),
            request: request(
                input: "我好焦虑，帮我 connect this source",
                sourceMaterials: [
                    SourceMaterialContext(
                        sourceNodeId: sourceNodeId,
                        title: "External essay",
                        originalURL: "https://example.com/essay",
                        originalFilename: nil,
                        chunks: [
                            SourceChunkContext(
                                sourceNodeId: sourceNodeId,
                                ordinal: 0,
                                text: "External essay chunk about connecting ideas.",
                                similarity: nil
                            )
                        ]
                    )
                ]
            )
        )

        XCTAssertEqual(decision.route, .sourceAnalysis)
        XCTAssertEqual(decision.trace.responseStance, .supportFirst)
        XCTAssertTrue(decision.supervisorLanes.contains(.source))
        XCTAssertEqual(decision.trace.supervisorLanes, decision.supervisorLanes)
    }

    func testPlanRouteActivatesProjectSupervisorLanes() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "help me plan the next phase"),
            request: request(input: "help me plan the next phase")
        )

        XCTAssertEqual(decision.route, .plan)
        XCTAssertTrue(decision.supervisorLanes.contains(.memory))
        XCTAssertTrue(decision.supervisorLanes.contains(.project))
        XCTAssertTrue(decision.supervisorLanes.contains(.analytics))
        XCTAssertTrue(decision.supervisorLanes.contains(.reflection))
        XCTAssertFalse(decision.supervisorLanes.contains(.source))
    }

    func testEmotionalDistressSupportFirst() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "我好攰，感觉顶唔顺"),
            request: request(input: "我好攰，感觉顶唔顺")
        )

        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.memoryPolicy, .conversationOnly)
        XCTAssertEqual(decision.challengeStance, .supportFirst)
        XCTAssertEqual(decision.responseShape, .answerNow)
    }

    func testMemoryOptOutForFreshBrainstorm() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "brainstorm from scratch, don't use memory"),
            request: request(input: "brainstorm from scratch, don't use memory")
        )

        XCTAssertEqual(decision.route, .brainstorm)
        XCTAssertEqual(decision.memoryPolicy, .lean)
        XCTAssertEqual(decision.trace.reason, "explicit brainstorm with memory opt-out")
    }

    func testMemoryOptOutForOrdinaryChat() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "don't use memory, think from first principles"),
            request: request(input: "don't use memory, think from first principles")
        )

        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.memoryPolicy, .lean)
        XCTAssertEqual(decision.challengeStance, .useSilently)
    }

    func testOrdinaryChatDefaultForAmbiguousText() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "just thinking out loud"),
            request: request(input: "just thinking out loud")
        )

        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.memoryPolicy, .full)
        XCTAssertEqual(decision.challengeStance, .useSilently)
        XCTAssertEqual(decision.responseShape, .answerNow)
    }

    func testAnalysisGateSkillSurfacesTensionWithoutQuickMode() {
        let steward = TurnSteward(skillStore: GateSkillStore(skills: [analysisGateSkill()]))

        let decision = steward.steer(
            prepared: preparedTurn(userText: "帮我分析下呢件事，可能有咩盲点？"),
            request: request(input: "帮我分析下呢件事，可能有咩盲点？")
        )

        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.memoryPolicy, .full)
        XCTAssertEqual(decision.challengeStance, .surfaceTension)
        XCTAssertEqual(decision.responseShape, .answerNow)
        XCTAssertEqual(decision.trace.reason, "analysis skill cue")
    }

    func testAnalysisGateSkillRespectsMemoryOptOut() {
        let steward = TurnSteward(skillStore: GateSkillStore(skills: [analysisGateSkill()]))

        let decision = steward.steer(
            prepared: preparedTurn(userText: "from scratch 帮我分析下呢件事"),
            request: request(input: "from scratch 帮我分析下呢件事")
        )

        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.memoryPolicy, .lean)
        XCTAssertEqual(decision.challengeStance, .useSilently)
        XCTAssertEqual(decision.trace.reason, "memory opt-out cue")
    }

    func testDisabledAnalysisGateSkillKeepsOrdinaryChatLight() {
        let steward = TurnSteward(skillStore: GateSkillStore(skills: [analysisGateSkill(state: .disabled)]))

        let decision = steward.steer(
            prepared: preparedTurn(userText: "帮我分析下呢件事"),
            request: request(input: "帮我分析下呢件事")
        )

        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.challengeStance, .useSilently)
        XCTAssertEqual(decision.trace.reason, "ordinary chat default")
    }

    func testNoIdeaDoesNotRouteToBrainstorm() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "I have no idea what to do"),
            request: request(input: "I have no idea what to do")
        )

        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.memoryPolicy, .full)
    }

    func testTopicAloneDoesNotOpenJudge() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "最近听返首旧歌，突然觉得好有味道"),
            request: request(input: "最近听返首旧歌，突然觉得好有味道")
        )

        XCTAssertEqual(decision.trace.responseStance, .companion)
        XCTAssertEqual(decision.trace.judgePolicy, .off)
        XCTAssertEqual(decision.challengeStance, .useSilently)
    }

    func testOrdinaryCompanionShadowDoesNotCallClassifier() async {
        let classifier = StubSpeechActClassifier(
            output: SpeechActClassifierOutput(
                stance: .softAnalysis,
                confidence: 0.99,
                softerFallback: .reflective,
                reason: "would make ordinary chat too heavy"
            )
        )
        let steward = TurnSteward(
            routerModeProvider: { .shadow },
            currentProviderProvider: { .gemini },
            classifier: classifier
        )

        let decision = await steward.steerForTurn(
            prepared: preparedTurn(userText: "最近听返首旧歌，突然觉得好有味道"),
            request: request(input: "最近听返首旧歌，突然觉得好有味道")
        )

        XCTAssertEqual(classifier.callCount, 0)
        XCTAssertEqual(decision.trace.responseStance, .companion)
        XCTAssertEqual(decision.judgePolicy, .off)
    }

    func testReflectiveShadowDoesNotCallClassifier() async {
        let classifier = StubSpeechActClassifier(
            output: SpeechActClassifierOutput(
                stance: .softAnalysis,
                confidence: 0.99,
                softerFallback: .reflective,
                reason: "would over-interpret reflection"
            )
        )
        let steward = TurnSteward(
            routerModeProvider: { .shadow },
            currentProviderProvider: { .gemini },
            classifier: classifier
        )

        let decision = await steward.steerForTurn(
            prepared: preparedTurn(userText: "我发现自己最近变咗好多"),
            request: request(input: "我发现自己最近变咗好多")
        )

        XCTAssertEqual(classifier.callCount, 0)
        XCTAssertEqual(decision.trace.responseStance, .reflective)
        XCTAssertEqual(decision.judgePolicy, .off)
    }

    func testLocalOpinionQuestionStaysCompanionNotSoftAnalysis() async {
        let decision = await TurnSteward(
            routerModeProvider: { .active },
            currentProviderProvider: { .local }
        ).steerForTurn(
            prepared: preparedTurn(userText: "你觉得呢首歌点样？"),
            request: request(input: "你觉得呢首歌点样？")
        )

        XCTAssertEqual(decision.trace.responseStance, .companion)
        XCTAssertEqual(decision.judgePolicy, .off)
    }

    func testBroadOpinionQuestionUsesClassifierInShadowWithoutChangingBehavior() async {
        let classifier = StubSpeechActClassifier(
            output: SpeechActClassifierOutput(
                stance: .softAnalysis,
                confidence: 0.91,
                softerFallback: .reflective,
                reason: "advice request"
            )
        )
        let steward = TurnSteward(
            routerModeProvider: { .shadow },
            currentProviderProvider: { .gemini },
            classifier: classifier
        )

        let decision = await steward.steerForTurn(
            prepared: preparedTurn(userText: "我想买对新鞋，你觉得点？"),
            request: request(input: "我想买对新鞋，你觉得点？")
        )

        XCTAssertEqual(classifier.callCount, 1)
        XCTAssertEqual(decision.trace.responseStance, .softAnalysis)
        XCTAssertEqual(decision.trace.judgePolicy, .silentFraming)
        XCTAssertEqual(decision.judgePolicy, .off)
    }

    func testBroadOpinionClassifierCanKeepTasteTalkCompanion() async {
        let classifier = StubSpeechActClassifier(
            output: SpeechActClassifierOutput(
                stance: .companion,
                confidence: 0.9,
                softerFallback: .companion,
                reason: "taste talk"
            )
        )
        let steward = TurnSteward(
            routerModeProvider: { .active },
            currentProviderProvider: { .gemini },
            classifier: classifier
        )

        let decision = await steward.steerForTurn(
            prepared: preparedTurn(userText: "你觉得呢首歌点样？"),
            request: request(input: "你觉得呢首歌点样？")
        )

        XCTAssertEqual(classifier.callCount, 1)
        XCTAssertEqual(decision.trace.responseStance, .companion)
        XCTAssertEqual(decision.judgePolicy, .off)
    }

    func testAnalysisWithoutChallengeIsSoftAnalysisInActiveMode() async {
        let steward = TurnSteward(
            skillStore: GateSkillStore(skills: [analysisGateSkill()]),
            routerModeProvider: { .active }
        )

        let decision = await steward.steerForTurn(
            prepared: preparedTurn(userText: "帮我分析下呢件事应该点做"),
            request: request(input: "帮我分析下呢件事应该点做")
        )

        XCTAssertEqual(decision.trace.responseStance, .softAnalysis)
        XCTAssertEqual(decision.trace.judgePolicy, .silentFraming)
        XCTAssertEqual(decision.judgePolicy, .silentFraming)
        XCTAssertEqual(decision.challengeStance, .useSilently)
    }

    func testHardJudgeRequiresExplicitChallengeLanguage() async {
        let classifier = StubSpeechActClassifier(
            output: SpeechActClassifierOutput(
                stance: .hardJudge,
                confidence: 0.96,
                softerFallback: .softAnalysis,
                reason: "model overreached"
            )
        )
        let steward = TurnSteward(
            routerModeProvider: { .active },
            currentProviderProvider: { .gemini },
            classifier: classifier
        )

        let decision = await steward.steerForTurn(
            prepared: preparedTurn(userText: "我想买对新鞋，应该买定唔买？"),
            request: request(input: "我想买对新鞋，应该买定唔买？")
        )

        XCTAssertNotEqual(decision.trace.responseStance, .hardJudge)
        XCTAssertEqual(decision.trace.responseStance, .softAnalysis)
        XCTAssertEqual(decision.trace.fallbackUsed, true)
        XCTAssertEqual(decision.judgePolicy, .silentFraming)
    }

    func testExplicitChallengeAllowsHardJudgeInActiveMode() async {
        let decision = await TurnSteward(
            skillStore: GateSkillStore(skills: [analysisGateSkill()]),
            routerModeProvider: { .active }
        ).steerForTurn(
            prepared: preparedTurn(userText: "反驳我，我呢个判断有咩盲点？"),
            request: request(input: "反驳我，我呢个判断有咩盲点？")
        )

        XCTAssertEqual(decision.trace.responseStance, .hardJudge)
        XCTAssertEqual(decision.trace.judgePolicy, .visibleTension)
        XCTAssertEqual(decision.judgePolicy, .visibleTension)
        XCTAssertEqual(decision.challengeStance, .surfaceTension)
    }

    func testFitQuestionDoesNotBecomeHardJudgeWithoutChallengeLanguage() async {
        let decision = await TurnSteward(
            routerModeProvider: { .active },
            currentProviderProvider: { .local }
        ).steerForTurn(
            prepared: preparedTurn(userText: "呢首歌啱唔啱我口味？"),
            request: request(input: "呢首歌啱唔啱我口味？")
        )

        XCTAssertNotEqual(decision.trace.responseStance, .hardJudge)
        XCTAssertNotEqual(decision.judgePolicy, .visibleTension)
    }

    func testMissedDeadlinePhraseDoesNotBecomeHardJudgeBySubstring() async {
        let decision = await TurnSteward(
            routerModeProvider: { .active },
            currentProviderProvider: { .local }
        ).steerForTurn(
            prepared: preparedTurn(userText: "我错过咗报名时间，应该点做？"),
            request: request(input: "我错过咗报名时间，应该点做？")
        )

        XCTAssertEqual(decision.trace.responseStance, .softAnalysis)
        XCTAssertEqual(decision.judgePolicy, .silentFraming)
    }

    func testDistressPlusDecisionStaysSupportFirstAndSkipsClassifier() async {
        let classifier = StubSpeechActClassifier(
            output: SpeechActClassifierOutput(
                stance: .hardJudge,
                confidence: 0.99,
                softerFallback: .softAnalysis,
                reason: "should never override distress"
            )
        )
        let steward = TurnSteward(
            routerModeProvider: { .active },
            currentProviderProvider: { .gemini },
            classifier: classifier
        )

        let decision = await steward.steerForTurn(
            prepared: preparedTurn(userText: "我好焦虑，但我应该点拣？"),
            request: request(input: "我好焦虑，但我应该点拣？")
        )

        XCTAssertEqual(classifier.callCount, 0)
        XCTAssertEqual(decision.trace.responseStance, .supportFirst)
        XCTAssertEqual(decision.trace.judgePolicy, .off)
        XCTAssertEqual(decision.judgePolicy, .off)
        XCTAssertEqual(decision.challengeStance, .supportFirst)
        XCTAssertTrue(decision.trace.reason.contains("support-first"))
    }

    func testShadowModeRecordsClassifierDecisionWithoutChangingEffectiveBehavior() async {
        let classifier = StubSpeechActClassifier(
            output: SpeechActClassifierOutput(
                stance: .softAnalysis,
                confidence: 0.91,
                softerFallback: .reflective,
                reason: "decision request"
            )
        )
        let steward = TurnSteward(
            routerModeProvider: { .shadow },
            currentProviderProvider: { .gemini },
            classifier: classifier
        )

        let decision = await steward.steerForTurn(
            prepared: preparedTurn(userText: "你觉得我应该点样处理呢件事？"),
            request: request(input: "你觉得我应该点样处理呢件事？")
        )

        XCTAssertEqual(classifier.callCount, 1)
        XCTAssertEqual(decision.trace.routerMode, .shadow)
        XCTAssertEqual(decision.trace.responseStance, .softAnalysis)
        XCTAssertEqual(decision.trace.judgePolicy, .silentFraming)
        XCTAssertEqual(decision.challengeStance, .useSilently)
        XCTAssertEqual(decision.judgePolicy, .off)
        XCTAssertEqual(decision.trace.reason, "ordinary chat default")
    }

    func testMediumClassifierConfidenceUsesSofterFallback() async {
        let classifier = StubSpeechActClassifier(
            output: SpeechActClassifierOutput(
                stance: .softAnalysis,
                confidence: 0.58,
                softerFallback: .reflective,
                reason: "uncertain decision"
            )
        )
        let steward = TurnSteward(
            routerModeProvider: { .active },
            currentProviderProvider: { .claude },
            classifier: classifier
        )

        let decision = await steward.steerForTurn(
            prepared: preparedTurn(userText: "我应该继续做定暂停？"),
            request: request(input: "我应该继续做定暂停？")
        )

        XCTAssertEqual(decision.trace.responseStance, .reflective)
        XCTAssertEqual(decision.trace.fallbackUsed, true)
        XCTAssertEqual(decision.judgePolicy, .off)
    }

    func testLowClassifierConfidenceFallsBackSoftly() async {
        let classifier = StubSpeechActClassifier(
            output: SpeechActClassifierOutput(
                stance: .softAnalysis,
                confidence: 0.22,
                softerFallback: .reflective,
                reason: "too uncertain"
            )
        )
        let steward = TurnSteward(
            routerModeProvider: { .active },
            currentProviderProvider: { .openai },
            classifier: classifier
        )

        let decision = await steward.steerForTurn(
            prepared: preparedTurn(userText: "我应该继续做定暂停？"),
            request: request(input: "我应该继续做定暂停？")
        )

        XCTAssertEqual(decision.trace.responseStance, .reflective)
        XCTAssertEqual(decision.trace.fallbackUsed, true)
        XCTAssertEqual(decision.judgePolicy, .off)
    }

    func testLocalProviderDoesNotCallClassifier() async {
        let classifier = StubSpeechActClassifier(
            output: SpeechActClassifierOutput(
                stance: .softAnalysis,
                confidence: 0.99,
                softerFallback: .reflective,
                reason: "cloud should not be called"
            )
        )
        let steward = TurnSteward(
            routerModeProvider: { .active },
            currentProviderProvider: { .local },
            classifier: classifier
        )

        let decision = await steward.steerForTurn(
            prepared: preparedTurn(userText: "呢个 situation 应该点睇？"),
            request: request(input: "呢个 situation 应该点睇？")
        )

        XCTAssertEqual(classifier.callCount, 0)
        XCTAssertNotEqual(decision.trace.routerSource, .classifier)
        XCTAssertEqual(decision.trace.responseStance, .softAnalysis)
    }

    func testClassifierTimeoutCoversUnfinishedStreamCollection() async throws {
        let classifier = CloudSpeechActClassifier(
            llmService: HangingStreamLLMService(),
            timeout: 0.05
        )
        let steward = TurnSteward(
            routerModeProvider: { .shadow },
            currentProviderProvider: { .gemini },
            classifier: classifier
        )

        let decision = try await awaitDecision(timeoutNanoseconds: 500_000_000) {
            await steward.steerForTurn(
                prepared: self.preparedTurn(userText: "你觉得我应该点样处理呢件事？"),
                request: self.request(input: "你觉得我应该点样处理呢件事？")
            )
        }

        XCTAssertEqual(decision.trace.routerMode, ResponseStanceRouterMode.shadow)
        XCTAssertEqual(decision.trace.routerSource, ResponseStanceRouterSource.fallback)
        XCTAssertEqual(decision.trace.fallbackUsed, true)
        XCTAssertEqual(decision.trace.responseStance, ResponseStance.softAnalysis)
    }

    func testExplicitPlanTraceDoesNotBecomeHardJudgeWithoutChallengeLanguage() async {
        let decision = await TurnSteward(
            routerModeProvider: { .shadow },
            currentProviderProvider: { .gemini }
        ).steerForTurn(
            prepared: preparedTurn(userText: "help me plan this week"),
            request: request(input: "help me plan this week")
        )

        XCTAssertEqual(decision.route, .plan)
        XCTAssertEqual(decision.trace.responseStance, .softAnalysis)
        XCTAssertNotEqual(decision.trace.responseStance, .hardJudge)
    }

    func testExplicitPlanTraceJudgePolicyMatchesPreservedQuickActionPolicy() async {
        let decision = await TurnSteward(
            routerModeProvider: { .shadow },
            currentProviderProvider: { .gemini }
        ).steerForTurn(
            prepared: preparedTurn(userText: "help me plan this week"),
            request: request(input: "help me plan this week")
        )

        XCTAssertEqual(decision.route, .plan)
        XCTAssertEqual(decision.trace.responseStance, .softAnalysis)
        XCTAssertEqual(decision.judgePolicy, .visibleTension)
        XCTAssertEqual(decision.trace.judgePolicy, .visibleTension)
    }

    func testLocalProviderPrioritizesDecisionSpeechActOverGenericWhy() async {
        let decision = await TurnSteward(
            routerModeProvider: { .active },
            currentProviderProvider: { .local }
        ).steerForTurn(
            prepared: preparedTurn(userText: "why should I keep doing this?"),
            request: request(input: "why should I keep doing this?")
        )

        XCTAssertEqual(decision.trace.responseStance, .softAnalysis)
        XCTAssertEqual(decision.judgePolicy, .silentFraming)
    }

    func testMemoryOptOutTraceJudgePolicyMatchesEffectivePolicy() async {
        let decision = await TurnSteward(
            skillStore: GateSkillStore(skills: [analysisGateSkill()]),
            routerModeProvider: { .active }
        ).steerForTurn(
            prepared: preparedTurn(userText: "from scratch 反驳我，我有咩盲点？"),
            request: request(input: "from scratch 反驳我，我有咩盲点？")
        )

        XCTAssertEqual(decision.trace.responseStance, .hardJudge)
        XCTAssertEqual(decision.judgePolicy, .off)
        XCTAssertEqual(decision.trace.judgePolicy, .off)
    }

    private func preparedTurn(userText: String) -> PreparedTurnSession {
        let node = NousNode(type: .conversation, title: "test")
        let message = Message(nodeId: node.id, role: .user, content: userText)
        return PreparedConversationTurn(
            node: node,
            userMessage: message,
            messagesAfterUserAppend: [message]
        )
    }

    private func request(
        input: String,
        activeQuickActionMode: QuickActionMode? = nil,
        sourceMaterials: [SourceMaterialContext] = []
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
            sourceMaterials: sourceMaterials,
            now: Date()
        )
    }

    private func awaitDecision(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async -> TurnStewardDecision
    ) async throws -> TurnStewardDecision {
        try await withThrowingTaskGroup(of: TurnStewardDecision.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw RouterTestTimeout()
            }

            guard let result = try await group.next() else {
                throw RouterTestTimeout()
            }
            group.cancelAll()
            return result
        }
    }

    private func analysisGateSkill(state: SkillState = .active) -> Skill {
        Skill(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
            userId: "alex",
            payload: SkillPayload(
                payloadVersion: 2,
                name: "analysis-judge-gate",
                description: "Open judge only when Alex asks for analysis.",
                useWhen: "Use when Alex asks for analysis, blind spots, or whether his framing is wrong.",
                source: .alex,
                trigger: SkillTrigger(
                    kind: .analysisGate,
                    modes: [],
                    priority: 80,
                    cues: ["分析", "盲点", "blind spot", "am i wrong"]
                ),
                action: SkillAction(
                    kind: .promptFragment,
                    content: "Enable judge focus for explicit analysis intent without changing ordinary chat shape."
                ),
                rationale: "Ordinary chat should stay light unless Alex asks for judgment.",
                antiPatternExamples: []
            ),
            state: state,
            firedCount: 0,
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastModifiedAt: Date(timeIntervalSince1970: 2_000),
            lastFiredAt: nil
        )
    }

    private final class GateSkillStore: SkillStoring {
        let skills: [Skill]

        init(skills: [Skill]) {
            self.skills = skills
        }

        func fetchAllSkills(userId: String) throws -> [Skill] { skills.filter { $0.userId == userId } }
        func fetchActiveSkills(userId: String) throws -> [Skill] { skills.filter { $0.userId == userId && $0.state == .active } }
        func fetchSkill(id: UUID) throws -> Skill? { skills.first { $0.id == id } }
        func loadedSkills(in conversationID: UUID) throws -> [LoadedSkill] { [] }
        func markSkillLoaded(skillID: UUID, in conversationID: UUID, at loadedAt: Date) throws -> MarkSkillLoadedResult { .missingSkill }
        func unloadAllSkills(in conversationID: UUID) throws {}
        func insertSkill(_ skill: Skill) throws {}
        func updateSkill(_ skill: Skill) throws {}
        func setSkillState(id: UUID, state: SkillState) throws {}
        func incrementFiredCount(id: UUID, firedAt: Date) throws {}
    }

    private final class StubSpeechActClassifier: SpeechActClassifying {
        let output: SpeechActClassifierOutput
        private(set) var callCount = 0

        init(output: SpeechActClassifierOutput) {
            self.output = output
        }

        func classify(text: String) async throws -> SpeechActClassifierOutput {
            callCount += 1
            return output
        }
    }

    private struct RouterTestTimeout: Error {}

    private final class HangingStreamLLMService: LLMService {
        func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { _ in }
        }
    }
}
