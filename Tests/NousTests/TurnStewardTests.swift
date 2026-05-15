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
        XCTAssertEqual(decision.latencyTier, .deep)
    }

    func testActiveStudyQuickActionUsesSourceReadingLane() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "帮我读呢篇文章"),
            request: request(input: "帮我读呢篇文章", activeQuickActionMode: .study)
        )

        XCTAssertEqual(decision.route, .sourceAnalysis)
        XCTAssertEqual(decision.memoryPolicy, .full)
        XCTAssertEqual(decision.challengeStance, .useSilently)
        XCTAssertEqual(decision.judgePolicy, .off)
        XCTAssertEqual(decision.responseShape, .answerNow)
        XCTAssertEqual(decision.trace.reason, "active quick action mode")
        XCTAssertTrue(decision.supervisorLanes.contains(.source))
        XCTAssertEqual(decision.latencyTier, .deep)
    }

    func testActiveBrainstormQuickActionStaysNormalLatency() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "give me a few ideas"),
            request: request(input: "give me a few ideas", activeQuickActionMode: .brainstorm)
        )

        XCTAssertEqual(decision.route, .brainstorm)
        XCTAssertEqual(decision.memoryPolicy, .lean)
        XCTAssertEqual(decision.responseShape, .listDirections)
        XCTAssertEqual(decision.latencyTier, .normal)
    }

    func testActiveBrainstormQuickActionUsesDeepLatencyForExplicitDeepCue() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "认真拆一下呢个 tradeoff"),
            request: request(input: "认真拆一下呢个 tradeoff", activeQuickActionMode: .brainstorm)
        )

        XCTAssertEqual(decision.route, .brainstorm)
        XCTAssertEqual(decision.responseShape, .listDirections)
        XCTAssertEqual(decision.latencyTier, .deep)
        XCTAssertEqual(decision.trace.latencyTier, .deep)
    }

    func testActiveBrainstormDistressDropsToSupportFirstWithoutActiveRouter() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "我好焦虑，先陪我一下"),
            request: request(input: "我好焦虑，先陪我一下", activeQuickActionMode: .brainstorm)
        )

        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.memoryPolicy, .conversationOnly)
        XCTAssertEqual(decision.challengeStance, .supportFirst)
        XCTAssertEqual(decision.responseShape, .answerNow)
        XCTAssertEqual(decision.judgePolicy, .off)
        XCTAssertEqual(decision.latencyTier, .normal)
    }

    func testActiveDirectionAndPlanDistressAnswerNowWithoutActiveRouter() {
        let examples: [(QuickActionMode, TurnRoute)] = [
            (.direction, .direction),
            (.plan, .plan)
        ]

        for (mode, expectedRoute) in examples {
            let decision = steward.steer(
                prepared: preparedTurn(userText: "我好焦虑，帮我处理下一步"),
                request: request(input: "我好焦虑，帮我处理下一步", activeQuickActionMode: mode)
            )

            XCTAssertEqual(decision.route, expectedRoute, "\(mode)")
            XCTAssertEqual(decision.memoryPolicy, .full, "\(mode)")
            XCTAssertEqual(decision.challengeStance, .supportFirst, "\(mode)")
            XCTAssertEqual(decision.responseShape, .answerNow, "\(mode)")
            XCTAssertEqual(decision.judgePolicy, .off, "\(mode)")
            XCTAssertEqual(decision.latencyTier, .deep, "\(mode)")
        }
    }

    func testActiveQuickActionMemoryOptOutKeepsLeanMemoryPolicy() {
        for mode in QuickActionMode.allCases {
            let decision = steward.steer(
                prepared: preparedTurn(userText: "from scratch, don't use memory"),
                request: request(input: "from scratch, don't use memory", activeQuickActionMode: mode)
            )

            XCTAssertEqual(decision.memoryPolicy, .lean, "\(mode) should respect explicit memory opt-out")
        }
    }

    func testActiveBrainstormWithAttachmentOrSourceUsesDeepLatency() {
        let sourceNodeId = UUID()
        let attachedDecision = steward.steer(
            prepared: preparedTurn(userText: "give me ideas from this"),
            request: request(
                input: "give me ideas from this",
                activeQuickActionMode: .brainstorm,
                attachments: [
                    AttachedFileContext(name: "notes.txt", extractedText: "Product notes.")
                ]
            )
        )
        let sourceDecision = steward.steer(
            prepared: preparedTurn(userText: "give me ideas from this"),
            request: request(
                input: "give me ideas from this",
                activeQuickActionMode: .brainstorm,
                sourceMaterials: [
                    SourceMaterialContext(
                        sourceNodeId: sourceNodeId,
                        title: "Research note",
                        originalURL: nil,
                        originalFilename: "research.txt",
                        chunks: [
                            SourceChunkContext(
                                sourceNodeId: sourceNodeId,
                                ordinal: 0,
                                text: "A source-backed product note.",
                                similarity: nil
                            )
                        ]
                    )
                ]
            )
        )

        XCTAssertEqual(attachedDecision.latencyTier, .deep)
        XCTAssertEqual(sourceDecision.latencyTier, .deep)
    }

    func testExplicitBrainstormWithAttachmentUsesDeepLatency() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "brainstorm ideas from this file"),
            request: request(
                input: "brainstorm ideas from this file",
                attachments: [
                    AttachedFileContext(name: "notes.txt", extractedText: "Product notes.")
                ]
            )
        )

        XCTAssertEqual(decision.route, .brainstorm)
        XCTAssertEqual(decision.latencyTier, .deep)
        XCTAssertEqual(decision.trace.latencyTier, .deep)
    }

    func testInTurnPatternNamingFixtureSet() {
        let sourceNodeId = UUID()
        let fixtures: [PatternFixture] = [
            PatternFixture(
                input: "今日听到其他人讲 USC 同 Berkeley，我突然觉得同龄人已经 ahead，我好似慢好多。",
                expected: .comparisonLoop
            ),
            PatternFixture(
                input: "I keep comparing my progress with other 19 year old founders and it makes my next step feel fake.",
                expected: .comparisonLoop
            ),
            PatternFixture(
                input: "听完同学讲 transfer school，我又开始用学校名去量自己够唔够格。",
                expected: .comparisonLoop
            ),
            PatternFixture(
                input: "Everyone seems ahead because their credentials look cleaner than mine.",
                expected: .comparisonLoop
            ),
            PatternFixture(
                input: "我见到 peer shipping faster，就开始觉得自己整个 path 都落后。",
                expected: .comparisonLoop
            ),
            PatternFixture(
                input: "F-1 同 school 呢件事令我觉得自己唔似一个真正 founder。",
                expected: .identityPressure
            ),
            PatternFixture(
                input: "I am 19 and still at SMC, so I keep asking whether I am legitimate enough to build this.",
                expected: .identityPressure
            ),
            PatternFixture(
                input: "我唔系担心一个具体限制，我系觉得 visa status 好似证明我唔够格。",
                expected: .identityPressure
            ),
            PatternFixture(
                input: "我英文又唔好，技术又唔识，去 Codex event 会觉得自己好蚀底同唔配。",
                expected: .identityPressure
            ),
            PatternFixture(
                input: "听到人哋去好学校，我就觉得自己系个差学生，好失败。",
                expected: .identityPressure
            ),
            PatternFixture(
                input: "Maybe before shipping this small slice I should redesign the whole architecture and write a full framework.",
                expected: .planningAsAvoidance
            ),
            PatternFixture(
                input: "我明明可以今日做一个小 demo，但我又想先排完整 roadmap 同 system design。",
                expected: .planningAsAvoidance
            ),
            PatternFixture(
                input: "Let's create the whole operating system first before doing the exposed next step.",
                expected: .bigSystemEscape
            ),
            PatternFixture(
                input: "我可能应该先再研究 realtime docs，之后先决定 voice 要点做。",
                expected: .learningInsteadOfShipping
            ),
            PatternFixture(
                input: "Before shipping the prototype, I want to read a few more PDFs and model docs.",
                expected: .learningInsteadOfShipping
            ),
            PatternFixture(
                input: "呢个 slice 已经清楚，但我仲想继续 research provider comparison 先。",
                expected: .learningInsteadOfShipping
            ),
            PatternFixture(
                input: "我其实见到用户反应唔错，但而家主要惊别人觉得呢个产品唔够高级。",
                expected: .externalJudgmentSensitivity,
                expectedReasonCode: "external_judgment_over_product_truth"
            ),
            PatternFixture(
                input: "I know the user pain is real, but I am steering the decision around what people on Twitter will think.",
                expected: .externalJudgmentSensitivity
            ),
            PatternFixture(
                input: "我主要目标唔系大学，但我会惊人哋觉得我一日无所事事。",
                expected: .externalJudgmentSensitivity,
                expectedReasonCode: "external_judgment_self_presentation"
            ),
            PatternFixture(
                input: "我明明知道自己喺 build，但都惊别人觉得我不务正业。",
                expected: .externalJudgmentSensitivity
            ),
            PatternFixture(
                input: "我知道最小版本可以发出去，但我一直话自己未准备好，想等到 ready 先 ship。",
                expected: .notReadyRationalization
            ),
            PatternFixture(
                input: "The prototype is enough to test, but I keep saying I am not ready before launching it.",
                expected: .notReadyRationalization
            ),
            PatternFixture(
                input: "我明明有一个 small slice 可以今日测试，但我想先做完整 memory operating system。",
                expected: .bigSystemEscape
            ),
            PatternFixture(
                input: "Before the exposed next step, I want to build the whole system so I don't have to show the rough slice.",
                expected: .bigSystemEscape
            ),
            PatternFixture(
                input: "你直接帮我决定吧，虽然我已经见到用户反应同我自己 product taste 都指向 A。",
                expected: .overTrustingSystem
            ),
            PatternFixture(
                input: "Codex, tell me the product decision. I have live evidence, but I want you to choose for me.",
                expected: .overTrustingSystem
            ),
            PatternFixture(
                input: "我其实已经知道呢个 UI 唔 work，但我想 Nous 替我定案。",
                expected: .overTrustingSystem
            ),
            PatternFixture(input: "ping", expected: nil),
            PatternFixture(input: "翻译成英文：我今日好攰", expected: nil),
            PatternFixture(input: "帮我总结这篇文章第一部分", expected: nil, activeQuickActionMode: .study),
            PatternFixture(input: "summarize this source", expected: nil, sourceNodeId: sourceNodeId),
            PatternFixture(input: "from scratch, don't use memory, should I ship this?", expected: nil),
            PatternFixture(input: "我好焦虑，先陪我一下", expected: nil),
            PatternFixture(input: "我好焦虑，惊人哋觉得我无所事事，先陪我一下", expected: nil),
            PatternFixture(input: "最近听返首旧歌，突然觉得好有味道", expected: nil),
            PatternFixture(input: "帮我 plan this week", expected: nil),
            PatternFixture(input: "what does TTFT mean?", expected: nil),
            PatternFixture(input: "我想做一个更完整的系统", expected: nil),
            PatternFixture(input: "我想伤害自己，应该点算", expected: nil),
            PatternFixture(input: "我 panic 到唔知自己安唔安全", expected: nil),
            PatternFixture(input: "你可以诊断我系咪 depression 同要唔要食药吗？", expected: nil)
        ]

        XCTAssertEqual(fixtures.count, 41)

        for fixture in fixtures {
            let decision = steward.steer(
                prepared: preparedTurn(userText: fixture.input),
                request: request(
                    input: fixture.input,
                    activeQuickActionMode: fixture.activeQuickActionMode,
                    sourceMaterials: fixture.sourceMaterials
                )
            )

            if let expected = fixture.expected {
                let signal = try? XCTUnwrap(decision.inTurnPatternSignal, fixture.input)
                XCTAssertEqual(signal?.kind, expected, fixture.input)
                XCTAssertGreaterThanOrEqual(signal?.confidence ?? 0, 0.75, fixture.input)
                if let expectedReasonCode = fixture.expectedReasonCode {
                    XCTAssertEqual(signal?.reasonCode, expectedReasonCode, fixture.input)
                }
                XCTAssertEqual(decision.trace.inTurnPatternSignal, signal, fixture.input)
                XCTAssertTrue(decision.supervisorLanes.contains(.pattern), fixture.input)
            } else {
                XCTAssertNil(decision.inTurnPatternSignal, fixture.input)
                XCTAssertNil(decision.trace.inTurnPatternSignal, fixture.input)
                XCTAssertFalse(decision.supervisorLanes.contains(.pattern), fixture.input)
            }
        }
    }

    func testComparisonPatternWinsWhenIdentityPressureAlsoMatches() {
        let text = "I keep comparing myself to other 19 year old founders, and then I use school and F-1 status to ask if I am legitimate enough."

        let decision = steward.steer(
            prepared: preparedTurn(userText: text),
            request: request(input: text)
        )

        XCTAssertEqual(decision.inTurnPatternSignal?.kind, .comparisonLoop)
    }

    func testDecisionCannotDropPatternLaneWhenSignalIsPresent() {
        let signal = InTurnPatternSignal(
            kind: .comparisonLoop,
            confidence: 0.9,
            surfacePolicy: .directName,
            reasonCode: "comparison_status_progress"
        )

        let decision = TurnStewardDecision(
            route: .ordinaryChat,
            memoryPolicy: .lean,
            challengeStance: .useSilently,
            responseShape: .answerNow,
            source: .deterministic,
            reason: "fixture",
            inTurnPatternSignal: signal,
            supervisorLanes: [.memory]
        )

        XCTAssertTrue(decision.supervisorLanes.contains(.pattern))
        XCTAssertTrue(decision.trace.supervisorLanes.contains(.pattern))
    }

    func testTraceCannotDropPatternLaneWhenSignalIsPresent() throws {
        let signal = InTurnPatternSignal(
            kind: .identityPressure,
            confidence: 0.88,
            surfacePolicy: .directName,
            reasonCode: "identity_constraint_judgment"
        )
        let trace = TurnStewardTrace(
            route: .ordinaryChat,
            memoryPolicy: .lean,
            challengeStance: .useSilently,
            responseShape: .answerNow,
            projectSignalKind: nil,
            source: .deterministic,
            reason: "fixture",
            inTurnPatternSignal: signal,
            supervisorLanes: []
        )

        XCTAssertTrue(trace.supervisorLanes.contains(.pattern))

        let data = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(TurnStewardTrace.self, from: data)

        XCTAssertTrue(decoded.supervisorLanes.contains(.pattern))
    }

    func testTraceDecodeAddsPatternLaneWhenSignalFieldExistsWithoutLanes() throws {
        let json = """
        {
          "route": "ordinaryChat",
          "memoryPolicy": "lean",
          "challengeStance": "useSilently",
          "responseShape": "answerNow",
          "source": "deterministic",
          "reason": "fixture",
          "inTurnPatternSignal": {
            "kind": "identityPressure",
            "confidence": 0.88,
            "surfacePolicy": "directName",
            "reasonCode": "identity_constraint_judgment"
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TurnStewardTrace.self, from: json)

        XCTAssertTrue(decoded.supervisorLanes.contains(.pattern))
    }

    func testPatternNamingDoesNotTriggerOnLiteralKeywordCollisions() {
        let controls = [
            "We should plan ahead for progress on the school onboarding page.",
            "What is the legitimate HTTP status for this route?",
            "Please research docs for the unit test failure before changing code.",
            "Nous has live evidence in the cognition trace; explain it, don't decide.",
            "Can you demo the framework architecture?",
            "I am researching relationship dynamics for product onboarding.",
            "Is this package legitimate enough for the build tool?",
            "The peer dependency affects founder docs in the progress screen.",
            "I am not ready to launch because the release build is failing.",
            "I need to explain the user pain to people on Twitter without letting that change the product decision.",
            "I want a complete system, but the next step is only to document the architecture."
        ]

        for text in controls {
            let decision = steward.steer(
                prepared: preparedTurn(userText: text),
                request: request(input: text)
            )

            XCTAssertNil(decision.inTurnPatternSignal, text)
        }
    }

    func testReflectiveMeaningFixtureSet() {
        let sourceNodeId = UUID()
        let fixtures: [MeaningFixture] = [
            MeaningFixture(
                input: "我想复盘下演唱会嗰个女仔，点解我会咁在意？",
                expected: true,
                expectedPolicy: .compact
            ),
            MeaningFixture(
                input: "帮我睇清楚呢件事真正牵住我嘅係咩。",
                expected: true,
                expectedPolicy: .compact
            ),
            MeaningFixture(
                input: "我想分析清楚啲，点解我对呢个 product idea 咁有感觉？",
                expected: true,
                expectedPolicy: .layered
            ),
            MeaningFixture(
                input: "复盘下我错过同嗰个 founder 合作嘅机会，真正代表咩？",
                expected: true,
                expectedPolicy: .compact
            ),
            MeaningFixture(
                input: "帮我看清楚为什么那句评论会让我这么在意。",
                expected: true,
                expectedPolicy: .compact
            ),
            MeaningFixture(
                input: "why did missing that window matter so much to me?",
                expected: true,
                expectedPolicy: .compact
            ),
            MeaningFixture(
                input: "帮我睇清楚呢段 conversation 点解我咁在意",
                expected: true,
                expectedPolicy: .compact,
                sourceNodeId: sourceNodeId
            ),
            MeaningFixture(
                input: "帮我睇清楚呢张截图入面段 conversation，点解我咁在意？",
                expected: true,
                expectedPolicy: .compact,
                attachments: [
                    AttachedFileContext(
                        name: "conversation.png",
                        extractedText: nil,
                        kind: .image,
                        imageData: Data([0x01]),
                        imageMimeType: "image/png"
                    )
                ]
            ),
            MeaningFixture(input: "今日食咩好？", expected: false),
            MeaningFixture(input: "What is TTFT?", expected: false),
            MeaningFixture(input: "帮我总结这篇文章第一部分。", expected: false, sourceNodeId: sourceNodeId),
            MeaningFixture(
                input: "帮我总结呢张截图。",
                expected: false,
                attachments: [
                    AttachedFileContext(
                        name: "conversation.png",
                        extractedText: nil,
                        kind: .image,
                        imageData: Data([0x01]),
                        imageMimeType: "image/png"
                    )
                ]
            ),
            MeaningFixture(input: "帮我做一个 shipping plan。", expected: false),
            MeaningFixture(input: "What do you think about this UI?", expected: false),
            MeaningFixture(input: "下次遇到倾得开心嘅人，我应该点开口？", expected: false),
            MeaningFixture(input: "我好焦虑，点解我咁在意自己会唔会失败？", expected: false),
            MeaningFixture(input: "我同学校同龄人比较到想死，帮我睇清楚。", expected: false),
            MeaningFixture(input: "don't use memory, 帮我睇清楚点解我咁在意。", expected: false),
            MeaningFixture(input: "翻译成英文：点解我咁在意", expected: false)
        ]

        for fixture in fixtures {
            let decision = steward.steer(
                prepared: preparedTurn(userText: fixture.input),
                request: request(
                    input: fixture.input,
                    attachments: fixture.attachments,
                    sourceMaterials: fixture.sourceMaterials
                )
            )

            if fixture.expected {
                let signal = try? XCTUnwrap(decision.reflectiveMeaningSignal, fixture.input)
                XCTAssertNotNil(signal, fixture.input)
                XCTAssertGreaterThanOrEqual(signal?.confidence ?? 0, 0.75, fixture.input)
                XCTAssertEqual(signal?.surfacePolicy, fixture.expectedPolicy, fixture.input)
                XCTAssertTrue(decision.supervisorLanes.contains(.meaning), fixture.input)
                XCTAssertTrue(decision.trace.supervisorLanes.contains(.meaning), fixture.input)
            } else {
                XCTAssertNil(decision.reflectiveMeaningSignal, fixture.input)
            }
        }
    }

    func testReflectiveMeaningSuppressesPatternNamingForExplicitReflection() {
        let text = "帮我睇清楚，点解我同其他 founder 比较之后会咁在意自己进度？"

        let decision = steward.steer(
            prepared: preparedTurn(userText: text),
            request: request(input: text)
        )

        XCTAssertNotNil(decision.reflectiveMeaningSignal)
        XCTAssertNil(decision.inTurnPatternSignal)
    }

    func testDecisionCannotDropMeaningLaneWhenSignalIsPresent() {
        let signal = ReflectiveMeaningSignal(
            confidence: 0.86,
            surfacePolicy: .compact,
            reasonCode: "reflective_meaning_request"
        )

        let decision = TurnStewardDecision(
            route: .ordinaryChat,
            memoryPolicy: .lean,
            challengeStance: .useSilently,
            responseShape: .answerNow,
            source: .deterministic,
            reason: "fixture",
            reflectiveMeaningSignal: signal,
            supervisorLanes: [.memory]
        )

        XCTAssertTrue(decision.supervisorLanes.contains(.meaning))
        XCTAssertTrue(decision.trace.supervisorLanes.contains(.meaning))
    }

    func testTraceDecodeAddsMeaningLaneWhenSignalFieldExistsWithoutLanes() throws {
        let json = """
        {
          "route": "ordinaryChat",
          "memoryPolicy": "lean",
          "challengeStance": "useSilently",
          "responseShape": "answerNow",
          "source": "deterministic",
          "reason": "fixture",
          "reflectiveMeaningSignal": {
            "confidence": 0.86,
            "surfacePolicy": "compact",
            "reasonCode": "reflective_meaning_request"
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TurnStewardTrace.self, from: json)

        XCTAssertNotNil(decoded.reflectiveMeaningSignal)
        XCTAssertTrue(decoded.supervisorLanes.contains(.meaning))
    }

    func testSelfHarmLanguageBypassesPatternNamingAndRoutesSupportFirst() {
        let text = "我同学校同龄人比较到觉得自己想死"

        let decision = steward.steer(
            prepared: preparedTurn(userText: text),
            request: request(input: text)
        )

        XCTAssertNil(decision.inTurnPatternSignal)
        XCTAssertEqual(decision.challengeStance, .supportFirst)
        XCTAssertEqual(decision.responseShape, .answerNow)
        XCTAssertEqual(decision.judgePolicy, .off)
    }

    func testOrdinaryDistressMemoryOptOutKeepsLeanPolicy() {
        let text = "don't use memory, 我好焦虑，先陪我一下"

        let decision = steward.steer(
            prepared: preparedTurn(userText: text),
            request: request(input: text)
        )

        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.memoryPolicy, .lean)
        XCTAssertEqual(decision.challengeStance, .supportFirst)
        XCTAssertEqual(decision.judgePolicy, .off)
    }

    func testSimpleSelfContainedOrdinaryTurnsUseFastLatencyTier() {
        let examples = [
            "ping",
            "翻译成英文：我今日好攰",
            "帮我改短：今日会议主要讲产品节奏",
            "what does TTFT mean?"
        ]

        for text in examples {
            let decision = steward.steer(
                prepared: preparedTurn(userText: text),
                request: request(input: text)
            )

            XCTAssertEqual(decision.route, .ordinaryChat, text)
            XCTAssertEqual(decision.latencyTier, .fast, text)
            XCTAssertEqual(decision.trace.latencyTier, .fast, text)
        }
    }

    func testDeepReasoningTurnsUseDeepLatency() {
        let examples = [
            "继续",
            "呢个点解",
            "你记得我上次讲咩",
            "我係咪错",
            "help me plan this week",
            "what does this mean?",
            "帮我深度分析呢个决定",
            "认真拆一下呢个 tradeoff"
        ]

        for text in examples {
            let decision = steward.steer(
                prepared: preparedTurn(userText: text),
                request: request(input: text)
            )

            XCTAssertEqual(decision.latencyTier, .deep, text)
            XCTAssertEqual(decision.trace.latencyTier, .deep, text)
        }
    }

    func testDistressSupportFirstTurnsStayNormalLatency() {
        let examples = [
            "我好焦虑，点算",
            "今日真系好崩溃"
        ]

        for text in examples {
            let decision = steward.steer(
                prepared: preparedTurn(userText: text),
                request: request(input: text)
            )

            XCTAssertEqual(decision.challengeStance, .supportFirst, text)
            XCTAssertEqual(decision.latencyTier, .normal, text)
            XCTAssertEqual(decision.trace.latencyTier, .normal, text)
        }
    }

    func testShortPersonalConversationTurnsStayNormalLatency() {
        let examples = [
            "我今日同屋企人嘈咗",
            "又諗起佢",
            "最近状态麻麻",
            "我有啲空",
            "just thinking out loud"
        ]

        for text in examples {
            let decision = steward.steer(
                prepared: preparedTurn(userText: text),
                request: request(input: text)
            )

            XCTAssertEqual(decision.route, .ordinaryChat, text)
            XCTAssertEqual(decision.latencyTier, .normal, text)
            XCTAssertEqual(decision.trace.latencyTier, .normal, text)
        }
    }

    func testAttachmentsAndSourcesUseDeepLatency() {
        let sourceNodeId = UUID()
        let attachedDecision = steward.steer(
            prepared: preparedTurn(userText: "summarize this"),
            request: request(
                input: "summarize this",
                attachments: [
                    AttachedFileContext(name: "note.txt", extractedText: "A short note.")
                ]
            )
        )
        let sourceDecision = steward.steer(
            prepared: preparedTurn(userText: "what does this mean?"),
            request: request(
                input: "what does this mean?",
                sourceMaterials: [
                    SourceMaterialContext(
                        sourceNodeId: sourceNodeId,
                        title: "External source",
                        originalURL: nil,
                        originalFilename: "source.txt",
                        chunks: [
                            SourceChunkContext(
                                sourceNodeId: sourceNodeId,
                                ordinal: 0,
                                text: "Source-backed context.",
                                similarity: nil
                            )
                        ]
                    )
                ]
            )
        )

        XCTAssertEqual(attachedDecision.latencyTier, .deep)
        XCTAssertEqual(sourceDecision.latencyTier, .deep)
    }

    func testActivePlanQuickActionWithDistressKeepsPlanRouteButAnswersNow() {
        let decision = TurnSteward(routerModeProvider: { .active }).steer(
            prepared: preparedTurn(userText: "我好焦虑，帮我 plan this week"),
            request: request(input: "我好焦虑，帮我 plan this week", activeQuickActionMode: .plan)
        )

        XCTAssertEqual(decision.route, .plan)
        XCTAssertEqual(decision.memoryPolicy, .full)
        XCTAssertEqual(decision.challengeStance, .supportFirst)
        XCTAssertEqual(decision.responseShape, .answerNow)
        XCTAssertEqual(decision.judgePolicy, .off)
        XCTAssertEqual(decision.trace.responseStance, .supportFirst)
        XCTAssertEqual(decision.latencyTier, .deep)
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

    func testExplicitBrainstormUsesDeepLatencyForExplicitDeepCue() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "brainstorm deep analysis of this tradeoff"),
            request: request(input: "brainstorm deep analysis of this tradeoff")
        )

        XCTAssertEqual(decision.route, .brainstorm)
        XCTAssertEqual(decision.memoryPolicy, .lean)
        XCTAssertEqual(decision.responseShape, .listDirections)
        XCTAssertEqual(decision.latencyTier, .deep)
        XCTAssertEqual(decision.trace.latencyTier, .deep)
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
        XCTAssertEqual(decision.latencyTier, .deep)
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
        XCTAssertEqual(decision.latencyTier, .deep)
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

    func testSourceMaterialMemoryOptOutKeepsLeanMemoryPolicy() {
        let sourceNodeId = UUID()
        let decision = steward.steer(
            prepared: preparedTurn(userText: "don't use memory, just analyze this source"),
            request: request(
                input: "don't use memory, just analyze this source",
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
        XCTAssertEqual(decision.memoryPolicy, .lean)
        XCTAssertEqual(decision.latencyTier, .deep)
    }

    func testSourceMaterialDistressKeepsSourceButRoutesSupportFirst() {
        let sourceNodeId = UUID()
        let decision = steward.steer(
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
        XCTAssertEqual(decision.challengeStance, .supportFirst)
        XCTAssertEqual(decision.responseShape, .answerNow)
        XCTAssertEqual(decision.judgePolicy, .off)
        XCTAssertEqual(decision.latencyTier, .deep)
        XCTAssertTrue(decision.supervisorLanes.contains(.source))
        XCTAssertEqual(decision.trace.supervisorLanes, decision.supervisorLanes)
    }

    func testSourceMaterialsKeepJudgeEngaged() {
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

        XCTAssertEqual(decision.challengeStance, .surfaceTension)
        XCTAssertEqual(decision.judgePolicy, .visibleTension)
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

    func testDistressPlusDecisionKeepsDirectionRouteButAnswersNow() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "我好焦虑，但我应该点拣？"),
            request: request(input: "我好焦虑，但我应该点拣？")
        )

        XCTAssertEqual(decision.route, .direction)
        XCTAssertEqual(decision.memoryPolicy, .full)
        XCTAssertEqual(decision.challengeStance, .supportFirst)
        XCTAssertEqual(decision.responseShape, .answerNow)
        XCTAssertEqual(decision.judgePolicy, .off)
    }

    func testDistressPlusPlanKeepsPlanRouteButAnswersNow() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "我好攰，帮我 plan this week"),
            request: request(input: "我好攰，帮我 plan this week")
        )

        XCTAssertEqual(decision.route, .plan)
        XCTAssertEqual(decision.memoryPolicy, .full)
        XCTAssertEqual(decision.challengeStance, .supportFirst)
        XCTAssertEqual(decision.responseShape, .answerNow)
        XCTAssertEqual(decision.judgePolicy, .off)
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

    func testMemoryOptOutFreshDoesNotMatchFreshmanSubstring() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "I am a freshman founder and need direction"),
            request: request(input: "I am a freshman founder and need direction")
        )

        XCTAssertEqual(decision.route, .direction)
        XCTAssertEqual(decision.memoryPolicy, .full)
    }

    func testMemoryOptOutFreshStillMatchesStandaloneWord() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "fresh, help me think from first principles"),
            request: request(input: "fresh, help me think from first principles")
        )

        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.memoryPolicy, .lean)
    }

    func testMemoryOptOutDoesNotSuppressExplicitDeepLatency() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "don't use memory, deep analysis this tradeoff"),
            request: request(input: "don't use memory, deep analysis this tradeoff")
        )

        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.memoryPolicy, .lean)
        XCTAssertEqual(decision.latencyTier, .deep)
        XCTAssertEqual(decision.trace.latencyTier, .deep)
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
        XCTAssertEqual(decision.route, .direction)
        XCTAssertEqual(decision.memoryPolicy, .full)
        XCTAssertEqual(decision.trace.responseStance, .supportFirst)
        XCTAssertEqual(decision.responseShape, .answerNow)
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

    func testClassifierSupportFirstWithoutDistressUsesConversationOnlyMemory() async {
        let classifier = StubSpeechActClassifier(
            output: SpeechActClassifierOutput(
                stance: .supportFirst,
                confidence: 0.93,
                softerFallback: .companion,
                reason: "classifier saw support need"
            )
        )
        let steward = TurnSteward(
            routerModeProvider: { .active },
            currentProviderProvider: { .gemini },
            classifier: classifier
        )

        let decision = await steward.steerForTurn(
            prepared: preparedTurn(userText: "你觉得我应该点样处理呢件事？"),
            request: request(input: "你觉得我应该点样处理呢件事？")
        )

        XCTAssertEqual(classifier.callCount, 1)
        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.memoryPolicy, .conversationOnly)
        XCTAssertEqual(decision.trace.responseStance, .supportFirst)
        XCTAssertEqual(decision.responseShape, .answerNow)
        XCTAssertEqual(decision.judgePolicy, .off)
    }

    func testClassifierSupportFirstRespectsMemoryOptOut() async {
        let classifier = StubSpeechActClassifier(
            output: SpeechActClassifierOutput(
                stance: .supportFirst,
                confidence: 0.93,
                softerFallback: .companion,
                reason: "classifier saw support need"
            )
        )
        let steward = TurnSteward(
            routerModeProvider: { .active },
            currentProviderProvider: { .gemini },
            classifier: classifier
        )
        let input = "from scratch, 你觉得我应该点样处理呢件事？"

        let decision = await steward.steerForTurn(
            prepared: preparedTurn(userText: input),
            request: request(input: input)
        )

        XCTAssertEqual(classifier.callCount, 1)
        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.memoryPolicy, .lean)
        XCTAssertEqual(decision.trace.responseStance, .supportFirst)
        XCTAssertEqual(decision.responseShape, .answerNow)
        XCTAssertEqual(decision.judgePolicy, .off)
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
        XCTAssertEqual(decision.latencyTier, .deep)
        XCTAssertEqual(decision.trace.latencyTier, .deep)
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
        XCTAssertEqual(decision.latencyTier, .deep)
        XCTAssertEqual(decision.trace.latencyTier, .deep)
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
        attachments: [AttachedFileContext] = [],
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
            attachments: attachments,
            sourceMaterials: sourceMaterials,
            now: Date()
        )
    }

    private struct PatternFixture {
        let input: String
        let expected: InTurnPatternKind?
        let expectedReasonCode: String?
        let activeQuickActionMode: QuickActionMode?
        let sourceMaterials: [SourceMaterialContext]

        init(
            input: String,
            expected: InTurnPatternKind?,
            expectedReasonCode: String? = nil,
            activeQuickActionMode: QuickActionMode? = nil,
            sourceNodeId: UUID? = nil
        ) {
            self.input = input
            self.expected = expected
            self.expectedReasonCode = expectedReasonCode
            self.activeQuickActionMode = activeQuickActionMode
            if let sourceNodeId {
                self.sourceMaterials = [
                    SourceMaterialContext(
                        sourceNodeId: sourceNodeId,
                        title: "Fixture source",
                        originalURL: nil,
                        originalFilename: "fixture.txt",
                        chunks: [
                            SourceChunkContext(
                                sourceNodeId: sourceNodeId,
                                ordinal: 0,
                                text: "Fixture source text.",
                                similarity: nil
                            )
                        ]
                    )
                ]
            } else {
                self.sourceMaterials = []
            }
        }
    }

    private struct MeaningFixture {
        let input: String
        let expected: Bool
        let expectedPolicy: ReflectiveMeaningSurfacePolicy?
        let attachments: [AttachedFileContext]
        let sourceMaterials: [SourceMaterialContext]

        init(
            input: String,
            expected: Bool,
            expectedPolicy: ReflectiveMeaningSurfacePolicy? = nil,
            attachments: [AttachedFileContext] = [],
            sourceNodeId: UUID? = nil
        ) {
            self.input = input
            self.expected = expected
            self.expectedPolicy = expectedPolicy
            self.attachments = attachments
            if let sourceNodeId {
                self.sourceMaterials = [
                    SourceMaterialContext(
                        sourceNodeId: sourceNodeId,
                        title: "Conversation fixture",
                        originalURL: nil,
                        originalFilename: "conversation.txt",
                        chunks: [
                            SourceChunkContext(
                                sourceNodeId: sourceNodeId,
                                ordinal: 0,
                                text: "Alex is reviewing a personal conversation.",
                                similarity: nil
                            )
                        ]
                    )
                ]
            } else {
                self.sourceMaterials = []
            }
        }
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
