import XCTest
@testable import Nous

final class PromptContextAssemblerDirectJudgmentTests: XCTestCase {
    func testAnswerClosurePolicyIsStableForOrdinaryInsightTurns() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "我觉得 Nous 最近好识问问题，但有时未够主动帮我落结论。",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(slice.stable.contains("ANSWER CLOSURE POLICY"))
        XCTAssertTrue(slice.stable.contains("one usable rule, one judgment test, or one next action"))
        XCTAssertTrue(slice.stable.contains("A question is not the default closing move"))
    }

    func testAnswerClosurePolicyAllowsSupportAndStyleDemoWithoutChecklist() {
        let supportSlice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "我今日真系好攰，你陪我坐一阵就好。",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )
        let styleSlice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "你应该用什么语气跟我说话？不要讲原则，直接示范一下。",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(supportSlice.stable.contains("Do not force a checklist onto pure emotional support, style demonstrations, or open reflection"))
        XCTAssertTrue(styleSlice.stable.contains("Do not force a checklist onto pure emotional support, style demonstrations, or open reflection"))
        XCTAssertTrue(styleSlice.volatile.contains("STYLE DEMONSTRATION CONTRACT"))
    }

    func testDirectJudgmentRequestAddsProvisionalJudgmentGuard() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .strategist,
            currentUserInput: "我想判断一个新问题：我应唔应该把 Galaxy 的关系解释做得更主动，定系先保持安静？你直接俾判断。",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(slice.volatile.contains("DIRECT JUDGMENT CONTRACT"))
        XCTAssertTrue(slice.volatile.contains("Give the provisional judgment first"))
        XCTAssertTrue(slice.volatile.contains("Do not lead with a clarification question"))
        XCTAssertTrue(slice.volatile.contains("State the assumption you are using"))
        XCTAssertTrue(slice.volatile.contains("A question is not the default CTA"))
        XCTAssertTrue(slice.volatile.contains("name the flip condition instead of ending with a question"))
    }

    func testDirectJudgmentGuardIsGeneralNotGalaxySpecific() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .strategist,
            currentUserInput: "直接给判断：我今日应该继续打磨完整系统，还是先收一个极小版本？",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(slice.volatile.contains("DIRECT JUDGMENT CONTRACT"))
        XCTAssertTrue(slice.volatile.contains("If details are missing, make the smallest honest assumption"))
    }

    func testQuickModeQualityPolicyUsesDeliverableClosureInsteadOfQuestionCTA() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .strategist,
            currentUserInput: "帮我用 Direction mode 判断今晚应该修边个问题。",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            activeQuickActionMode: .direction
        )

        XCTAssertTrue(slice.volatile.contains("QUICK MODE QUALITY POLICY"))
        XCTAssertTrue(slice.volatile.contains("Question is not the default CTA in quick mode"))
        XCTAssertTrue(slice.volatile.contains("End with a usable rule, test, or next action"))
    }

    func testOrdinaryQuestionDoesNotAddDirectJudgmentGuard() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "Galaxy 呢个关系解释应该点样设计会自然啲？",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertFalse(slice.volatile.contains("DIRECT JUDGMENT CONTRACT"))
    }

    func testOrdinaryEnglishHowToQuestionDoesNotAddDirectJudgmentGuard() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "How should I organize my memory notes so they are easier to review?",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertFalse(slice.volatile.contains("DIRECT JUDGMENT CONTRACT"))
    }

    func testGovernanceTraceIncludesDirectJudgmentLayerOnlyWhenNeeded() {
        let traceWithDirectJudgment = PromptContextAssembler.governanceTrace(
            chatMode: .strategist,
            currentUserInput: "你直接俾判断，我应该做主动解释还是保持安静？",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )
        let traceWithoutDirectJudgment = PromptContextAssembler.governanceTrace(
            chatMode: .strategist,
            currentUserInput: "帮我探索一下主动解释同被动解释的 tradeoff。",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(traceWithDirectJudgment.promptLayers.contains("direct_judgment_guard"))
        XCTAssertFalse(traceWithoutDirectJudgment.promptLayers.contains("direct_judgment_guard"))
    }

    func testRealityConstraintProbeAnswersFromMemoryBeforeClarifying() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .strategist,
            currentUserInput: "基于你知道我的现实约束，我做这个决定时最不能忽略什么？",
            globalMemory: "Alex is on an F-1 visa, uses school to maintain status, and has limited capital.",
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(slice.volatile.contains("REALITY CONSTRAINT PROBE CONTRACT"))
        XCTAssertTrue(slice.volatile.contains("answer from the known constraint first"))
        XCTAssertTrue(slice.volatile.contains("Do not turn this into a legal conclusion"))
        XCTAssertTrue(slice.volatile.contains("Do not lead by asking which decision"))
    }

    func testSupportBoundaryProbeChoosesABlendedStance() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "我现在需要你安慰我，还是需要你指出我哪里想错了？",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: "Alex said that under pressure he wants warmth first, then an honest correction if his frame is wrong.",
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(slice.volatile.contains("SUPPORT BOUNDARY PROBE CONTRACT"))
        XCTAssertTrue(slice.volatile.contains("Choose the stance instead of asking Alex to choose"))
        XCTAssertTrue(slice.volatile.contains("one steadying line"))
        XCTAssertTrue(slice.volatile.contains("then name the likely thinking error"))
    }

    func testStyleDemoProbeRequiresDemonstrationNotPrinciples() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "你应该用什么语气跟我说话？不要讲原则，直接示范一下。",
            globalMemory: "Alex prefers Cantonese and Mandarin mixed naturally: Cantonese warmth, Mandarin clarity, English technical terms.",
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(slice.volatile.contains("STYLE DEMONSTRATION CONTRACT"))
        XCTAssertTrue(slice.volatile.contains("Do not explain the style principles"))
        XCTAssertTrue(slice.volatile.contains("Answer as a sample message"))
        XCTAssertTrue(slice.volatile.contains("Match Alex's mixed Cantonese / Mandarin / English surface"))
    }

    func testUserAddressPolicyPreventsThirdPersonAlexLeakage() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "什么时候我应该快，什么时候应该慢？",
            globalMemory: "Alex wants to ship quickly, but does not want Nous to feel sloppy.",
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(slice.stable.contains("USER ADDRESS POLICY"))
        XCTAssertTrue(slice.stable.contains("Do not write phrases like \"Alex 会觉得\""))
        XCTAssertTrue(slice.stable.contains("Address him as \"你\" / \"you\" / \"我哋\""))
    }

    func testMemoryBoundaryProbeAnswersStorageQuestionDirectly() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "你有没有把我刚才说不要记住的东西当成长期记忆？",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(slice.volatile.contains("MEMORY BOUNDARY ANSWER CONTRACT"))
        XCTAssertTrue(slice.volatile.contains("Answer the storage question directly first"))
        XCTAssertTrue(slice.volatile.contains("Do not answer with a generic claim that Nous has long-term memory"))
        XCTAssertTrue(slice.volatile.contains("Do not ask Alex to repeat the protected detail"))
    }

    func testMemorySynthesisFinalProbesAddJudgmentContract() {
        let probes: [(input: String, requiredLine: String)] = [
            (
                "我到底是讨厌计划，还是讨厌假计划？",
                "name the distinction that makes the tension intelligible"
            ),
            (
                "什么时候我应该快，什么时候应该慢？",
                "For tensions"
            ),
            (
                "如果我之前说过 A，但后来改成 B，你现在应该怎样理解我？",
                "latest explicit correction wins"
            ),
            (
                "你觉得一个新 UI 方向怎样才像 Nous，而不是普通 AI app？",
                "concrete product direction"
            ),
            (
                "这两个想法之间有没有共同模式，还是只是表面相似？",
                "shared mechanism is real or only surface similarity"
            ),
            (
                "这个 project 现在真正目标是什么？哪些方向其实已经偏了？",
                "current real goal first"
            )
        ]

        for probe in probes {
            let slice = PromptContextAssembler.assembleContext(
                chatMode: .strategist,
                currentUserInput: probe.input,
                globalMemory: "Alex cares about real constraints, current corrections, taste, and project continuity.",
                projectMemory: "The current project changed direction after several iterations.",
                conversationMemory: "Alex corrected older claims and asked Nous to judge the real pattern.",
                recentConversations: [],
                citations: [],
                projectGoal: nil
            )

            XCTAssertTrue(slice.volatile.contains("MEMORY SYNTHESIS JUDGMENT CONTRACT"), probe.input)
            XCTAssertTrue(slice.volatile.contains("Use the relevant memory first"), probe.input)
            XCTAssertTrue(slice.volatile.contains(probe.requiredLine), probe.input)
        }
    }

    func testMemorySynthesisProbeAddsGovernanceLayer() {
        let trace = PromptContextAssembler.governanceTrace(
            chatMode: .strategist,
            currentUserInput: "这两个想法之间有没有共同模式，还是只是表面相似？",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(trace.promptLayers.contains("memory_synthesis_judgment_guard"))
    }

    func testOrdinaryActuallySentenceDoesNotTriggerMemorySynthesisViaOrSubstring() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "I actually feel more focused today.",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )
        let trace = PromptContextAssembler.governanceTrace(
            chatMode: .companion,
            currentUserInput: "I actually feel more focused today.",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertFalse(slice.volatile.contains("MEMORY SYNTHESIS JUDGMENT CONTRACT"))
        XCTAssertFalse(trace.promptLayers.contains("memory_synthesis_judgment_guard"))
    }

    func testMemoryBoundaryProbeAddsGovernanceLayer() {
        let trace = PromptContextAssembler.governanceTrace(
            chatMode: .companion,
            currentUserInput: "你有没有把我刚才说不要记住的东西当成长期记忆？",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(trace.promptLayers.contains("user_address_policy"))
        XCTAssertTrue(trace.promptLayers.contains("memory_boundary_answer_guard"))
    }
}
