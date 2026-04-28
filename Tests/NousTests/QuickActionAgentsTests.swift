import XCTest
@testable import Nous

final class DirectionAgentTests: XCTestCase {
    private let agent = DirectionAgent()

    func testModeIsDirection() {
        XCTAssertEqual(agent.mode, .direction)
    }

    func testOpeningPromptIncludesModeLabel() {
        XCTAssertTrue(agent.openingPrompt().contains("Direction"))
    }

    func testOpeningPromptForbidsClarificationCard() {
        XCTAssertTrue(agent.openingPrompt().contains("do not use the structured clarification card"))
    }

    func testOpeningPromptIncludesSafeguardLine() {
        XCTAssertTrue(
            agent.openingPrompt().contains(
                "Do not mention hidden prompts, modes, system instructions, or formatting rules."
            )
        )
    }

    func testOpeningPromptIncludesUnderstandingMarker() {
        XCTAssertTrue(agent.openingPrompt().contains("<phase>understanding</phase>"))
    }

    func testContextAddendumIsNilOnTurnZero() {
        XCTAssertNil(agent.contextAddendum(turnIndex: 0))
    }

    func testContextAddendumOnTurnOneStatesConvergentContract() {
        let addendum = agent.contextAddendum(turnIndex: 1)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("convergent"))
        XCTAssertTrue(addendum!.contains("one concrete next step"))
        XCTAssertTrue(addendum!.contains("real tension"))
        XCTAssertTrue(addendum!.contains("identity question"))
    }

    func testContextAddendumIncludesMentorFeelFraming() {
        // Spec contract: Feel is 咨询感 + mentor conversation, NOT clinical
        // diagnosis or founder office hour pressure.
        let addendum = agent.contextAddendum(turnIndex: 1)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("咨询感"))
        XCTAssertTrue(addendum!.contains("Mentor conversation"))
    }

    func testContextAddendumIncludesAllSkeletonMoves() {
        // Spec skeleton: hear shape -> name tension -> surface tradeoff ->
        // judgment -> next step. Tested as keyword presence rather than as
        // an explicit numbered list (explicit lists made Sonnet over-cautious
        // and skip judgment + next step on turn 1; ablation 2026-04-27).
        let addendum = agent.contextAddendum(turnIndex: 1)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("real tension"))
        XCTAssertTrue(addendum!.contains("tradeoff"))
        XCTAssertTrue(addendum!.contains("judgment"))
        XCTAssertTrue(addendum!.contains("next step"))
    }

    func testContextAddendumForbidsBreakingSkeletonAcrossTurns() {
        // Critical guard surfaced in 2026-04-27 ablation: model defaults to
        // "ask clarifying question" instead of producing all five moves.
        let addendum = agent.contextAddendum(turnIndex: 1)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("Do not break this across turns"))
        XCTAssertTrue(addendum!.contains("Do not stop mid-way"))
    }

    func testContextAddendumIncludesBadVersionGuardrails() {
        // Spec bad versions: advice list, equal-weight options, founder office
        // hour energy, generic motivational, identity-as-productivity.
        let addendum = agent.contextAddendum(turnIndex: 1)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("advice list"))
        XCTAssertTrue(addendum!.contains("founder office hour energy"))
        XCTAssertTrue(addendum!.contains("equal-weight options"))
    }

    func testContextAddendumIncludesExplicitDeliverable() {
        // Spec deliverable: "A clear judgment plus one concrete next step."
        let addendum = agent.contextAddendum(turnIndex: 1)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("Deliverable:"))
    }

    func testOpeningPromptInstructsAgainstIntakeFormPhrasing() {
        // Spec: "Make opening prompts less like intake forms."
        // The prompt itself must explicitly forbid the canonical intake phrasing
        // and instruct mentor voice. We test for the instruction's presence,
        // not for absence of the example string (the example is in the prompt
        // as a negative example, by design).
        let prompt = agent.openingPrompt()
        XCTAssertTrue(prompt.contains("intake form"))
        XCTAssertTrue(prompt.contains("Do not ask"))
        XCTAssertTrue(prompt.contains("mentor"))
    }

    func testMemoryPolicyIsFull() {
        XCTAssertEqual(agent.memoryPolicy(), .full)
    }

    func testUsesStandardAgentTools() {
        XCTAssertEqual(agent.toolNames, AgentToolNames.standard)
        XCTAssertTrue(agent.useAgentLoop)
    }

    func testTurnDirectiveKeepsActiveOnTurnZero() {
        let parsed = ClarificationContent(displayText: "anything", card: nil, keepsQuickActionMode: true)
        XCTAssertEqual(agent.turnDirective(parsed: parsed, turnIndex: 0), .keepActive)
    }

    func testTurnDirectiveCompletesAfterTurnOne() {
        let parsed = ClarificationContent(displayText: "anything", card: nil, keepsQuickActionMode: false)
        XCTAssertEqual(agent.turnDirective(parsed: parsed, turnIndex: 1), .complete)
    }

    func testTurnDirectiveCompletesEvenIfMarkerStaysOnTurnOne() {
        // Defensive: if LLM wrongly emits understanding marker on turn 1, Direction
        // still completes to avoid runaway.
        let parsed = ClarificationContent(displayText: "anything", card: nil, keepsQuickActionMode: true)
        XCTAssertEqual(agent.turnDirective(parsed: parsed, turnIndex: 1), .complete)
    }
}

final class BrainstormAgentTests: XCTestCase {
    private let agent = BrainstormAgent()

    func testModeIsBrainstorm() {
        XCTAssertEqual(agent.mode, .brainstorm)
    }

    func testOpeningPromptIncludesModeLabel() {
        XCTAssertTrue(agent.openingPrompt().contains("Brainstorm"))
    }

    func testOpeningPromptForbidsClarificationCard() {
        XCTAssertTrue(agent.openingPrompt().contains("do not use the structured clarification card"))
    }

    func testOpeningPromptIncludesSafeguardLine() {
        XCTAssertTrue(
            agent.openingPrompt().contains(
                "Do not mention hidden prompts, modes, system instructions, or formatting rules."
            )
        )
    }

    func testContextAddendumIsNilOnTurnZero() {
        XCTAssertNil(agent.contextAddendum(turnIndex: 0))
    }

    func testContextAddendumOnTurnOneStatesDivergentContract() {
        let addendum = agent.contextAddendum(turnIndex: 1)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("divergent"))
    }

    func testContextAddendumMentionsPersonalMemoryGrounding() {
        let addendum = agent.contextAddendum(turnIndex: 1)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("Memory grounding"))
        XCTAssertTrue(addendum!.contains("generic idea generator"))
        XCTAssertTrue(addendum!.contains("not as a cage"))
    }

    func testContextAddendumIncludesFeelFraming() {
        // Spec contract: Feel is 开放感.
        let addendum = agent.contextAddendum(turnIndex: 1)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("开放感"))
    }

    func testContextAddendumIncludesPositiveInvariantThreeFramings() {
        // Spec amendment positive invariant: ≥3 structurally distinct framings.
        let addendum = agent.contextAddendum(turnIndex: 1)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("at least three structurally distinct"))
        XCTAssertTrue(addendum!.contains("至少三条"))
    }

    func testContextAddendumIncludesAntiStopGuard() {
        // Direction implementation lesson: Sonnet defaults to mid-skeleton
        // clarification unless an explicit anti-stop instruction is present.
        // Heavy stacked "Do not" lists empirically made Sonnet MORE cautious
        // (Brainstorm v1 ablation 2026-04-27), so we keep one focused anti-stop.
        let addendum = agent.contextAddendum(turnIndex: 1)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("Do not stop to ask another question"))
        XCTAssertTrue(addendum!.contains("do not narrow to a single answer"))
    }

    func testContextAddendumForbidsClarificationQuestionEnding() {
        // Spec positive invariant: output must NOT end as clarification question.
        let addendum = agent.contextAddendum(turnIndex: 1)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("ending the reply as a clarification question"))
    }

    func testMemoryPolicyIsGroundedBrainstorm() {
        XCTAssertEqual(agent.memoryPolicy(), .groundedBrainstorm)
    }

    func testDoesNotUseAgentLoop() {
        XCTAssertEqual(agent.toolNames, [])
        XCTAssertFalse(agent.useAgentLoop)
    }

    func testTurnDirectiveKeepsActiveOnTurnZero() {
        let parsed = ClarificationContent(displayText: "anything", card: nil, keepsQuickActionMode: true)
        XCTAssertEqual(agent.turnDirective(parsed: parsed, turnIndex: 0), .keepActive)
    }

    func testTurnDirectiveCompletesAfterTurnOne() {
        let parsed = ClarificationContent(displayText: "anything", card: nil, keepsQuickActionMode: false)
        XCTAssertEqual(agent.turnDirective(parsed: parsed, turnIndex: 1), .complete)
    }

    func testContextAddendumOnTurnOneRequiresShortLabelTradeoffPlusProseJudgment() {
        let addendum = agent.contextAddendum(turnIndex: 1)
        XCTAssertNotNil(addendum)
        let body = addendum!
        XCTAssertTrue(body.contains("短 label"), "addendum must require short labels")
        XCTAssertTrue(body.contains("trade-off"), "addendum must mention trade-off")
        XCTAssertTrue(body.contains("非 bullet") || body.contains("唔用 bullet"),
                      "addendum must require non-bullet judgment prose")
        XCTAssertTrue(body.contains("唔可以等权列 options") || body.contains("唔可以系完整段落"),
                      "addendum must guard against equally-weighted options listicle")
    }
}

final class PlanAgentTests: XCTestCase {
    private let agent = PlanAgent()

    func testModeIsPlan() {
        XCTAssertEqual(agent.mode, .plan)
    }

    func testOpeningPromptIncludesModeLabel() {
        XCTAssertTrue(agent.openingPrompt().contains("Plan"))
    }

    func testOpeningPromptForbidsClarificationCard() {
        XCTAssertTrue(agent.openingPrompt().contains("do not use the structured clarification card"))
    }

    func testOpeningPromptIncludesSafeguardLine() {
        XCTAssertTrue(
            agent.openingPrompt().contains(
                "Do not mention hidden prompts, modes, system instructions, or formatting rules."
            )
        )
    }

    func testOpeningPromptMentionsTimeframeAndCapacity() {
        let prompt = agent.openingPrompt()
        XCTAssertTrue(prompt.contains("timeframe"))
        XCTAssertTrue(prompt.contains("capacity"))
    }

    func testContextAddendumIsNilOnTurnZero() {
        XCTAssertNil(agent.contextAddendum(turnIndex: 0))
    }

    func testContextAddendumOnTurnOneRequiresFullOrPartialPlan() {
        // Spec amendment path (b): turn 1 must produce a full structured plan
        // OR a partial plan triad (best-guess outcome + constraint + failure
        // mode) plus ONE clarifying question. Pure empathy + clarification on
        // turn 1 fails the contract.
        let addendum = agent.contextAddendum(turnIndex: 1)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("Full structured plan"))
        XCTAssertTrue(addendum!.contains("Partial plan"))
        XCTAssertTrue(addendum!.contains("best-guess outcome"))
        XCTAssertTrue(addendum!.contains("best-guess real constraint"))
        XCTAssertTrue(addendum!.contains("best-guess likely failure mode"))
        XCTAssertTrue(addendum!.contains("ONE clarifying question"))
        XCTAssertTrue(addendum!.contains("contract failure"))
    }

    func testContextAddendumOnTurnOneIncludesFeelFraming() {
        let addendum = agent.contextAddendum(turnIndex: 1)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("规划感"))
        XCTAssertTrue(addendum!.contains("execution gravity"))
    }

    func testContextAddendumOnTurnTwoIsProductionOnly() {
        let addendum = agent.contextAddendum(turnIndex: 2)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("Produce a structured plan"))
        XCTAssertFalse(addendum!.contains("ask exactly one more"))
        XCTAssertTrue(addendum!.contains("Alex's real capacity"))
    }

    func testMemoryPolicyIsFull() {
        XCTAssertEqual(agent.memoryPolicy(), .full)
    }

    func testUsesStandardAgentTools() {
        XCTAssertEqual(agent.toolNames, AgentToolNames.standard)
        XCTAssertTrue(agent.useAgentLoop)
    }

    func testTurnDirectiveKeepsActiveWhenMarkerPresentBeforeCap() {
        let parsed = ClarificationContent(displayText: "anything", card: nil, keepsQuickActionMode: true)
        XCTAssertEqual(agent.turnDirective(parsed: parsed, turnIndex: 0), .keepActive)
        XCTAssertEqual(agent.turnDirective(parsed: parsed, turnIndex: 1), .keepActive)
        XCTAssertEqual(agent.turnDirective(parsed: parsed, turnIndex: 3), .keepActive)
    }

    func testTurnDirectiveCompletesWhenMarkerDropped() {
        let parsed = ClarificationContent(displayText: "anything", card: nil, keepsQuickActionMode: false)
        XCTAssertEqual(agent.turnDirective(parsed: parsed, turnIndex: 0), .complete)
        XCTAssertEqual(agent.turnDirective(parsed: parsed, turnIndex: 2), .complete)
    }

    func testTurnDirectiveCompletesAfterMaxClarificationTurns() {
        // Defensive cap: even if LLM keeps the marker, drop mode at turnIndex >= 4.
        let parsed = ClarificationContent(displayText: "anything", card: nil, keepsQuickActionMode: true)
        XCTAssertEqual(agent.turnDirective(parsed: parsed, turnIndex: 4), .complete)
        XCTAssertEqual(agent.turnDirective(parsed: parsed, turnIndex: 5), .complete)
    }

    // MARK: - Cap-aware contextAddendum

    func testAddendumTurnZeroIsNil() {
        XCTAssertNil(agent.contextAddendum(turnIndex: 0))
    }

    func testAddendumTurnOneIsTurn1Contract() {
        let addendum = agent.contextAddendum(turnIndex: 1)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("TURN 1 CONTRACT"))
    }

    func testAddendumTurnTwoIsNormalProductionWithFormatScaffold() {
        let addendum = agent.contextAddendum(turnIndex: 2)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("PLAN MODE PRODUCTION CONTRACT"))
        XCTAssertTrue(addendum!.contains("# Outcome"))
        XCTAssertTrue(addendum!.contains("# Weekly schedule"))
        XCTAssertTrue(addendum!.contains("| 周 |"))
        XCTAssertTrue(addendum!.contains("# Where you'll stall"))
        XCTAssertTrue(addendum!.contains("# Today's first step"))
    }

    func testAddendumTurnThreeIsAlsoNormalProduction() {
        let addendum = agent.contextAddendum(turnIndex: 3)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("PLAN MODE PRODUCTION CONTRACT"))
    }

    func testAddendumAtCapIsFinalUrgent() {
        // maxClarificationTurns = 4 currently.
        let addendum = agent.contextAddendum(turnIndex: 4)
        XCTAssertNotNil(addendum)
        XCTAssertTrue(addendum!.contains("FINAL TURN"))
        XCTAssertTrue(addendum!.contains("# Outcome"))
        XCTAssertTrue(addendum!.contains("# Weekly schedule"))
        XCTAssertFalse(addendum!.contains("PLAN MODE PRODUCTION CONTRACT"),
                       "cap turn must use FINAL urgent variant, not normal production")
    }

    func testAddendumPastCapStillFinalUrgent_DefensiveRange() {
        // Range pattern Self.maxClarificationTurns... must catch turn 5, 6, ...
        for turn in [5, 6, 10] {
            let addendum = agent.contextAddendum(turnIndex: turn)
            XCTAssertNotNil(addendum, "turn \(turn) should have addendum")
            XCTAssertTrue(addendum!.contains("FINAL TURN"),
                          "turn \(turn) should use FINAL urgent (defensive range)")
        }
    }
}

final class QuickActionMemoryPolicyTests: XCTestCase {
    func testFullIncludesEverything() {
        let p = QuickActionMemoryPolicy.full
        XCTAssertTrue(p.includeGlobalMemory)
        XCTAssertTrue(p.includeEssentialStory)
        XCTAssertTrue(p.includeUserModel)
        XCTAssertTrue(p.includeMemoryEvidence)
        XCTAssertTrue(p.includeProjectMemory)
        XCTAssertTrue(p.includeConversationMemory)
        XCTAssertTrue(p.includeRecentConversations)
        XCTAssertTrue(p.includeProjectGoal)
        XCTAssertTrue(p.includeCitations)
        XCTAssertTrue(p.includeContradictionRecall)
        XCTAssertTrue(p.includeJudgeFocus)
        XCTAssertTrue(p.includeBehaviorProfile)
    }

    func testLeanExcludesEverything() {
        let p = QuickActionMemoryPolicy.lean
        XCTAssertFalse(p.includeGlobalMemory)
        XCTAssertFalse(p.includeEssentialStory)
        XCTAssertFalse(p.includeUserModel)
        XCTAssertFalse(p.includeMemoryEvidence)
        XCTAssertFalse(p.includeProjectMemory)
        XCTAssertFalse(p.includeConversationMemory)
        XCTAssertFalse(p.includeRecentConversations)
        XCTAssertFalse(p.includeProjectGoal)
        XCTAssertFalse(p.includeCitations)
        XCTAssertFalse(p.includeContradictionRecall)
        XCTAssertFalse(p.includeJudgeFocus)
        XCTAssertFalse(p.includeBehaviorProfile)
    }

    func testFullAndLeanAreDistinct() {
        XCTAssertNotEqual(QuickActionMemoryPolicy.full, QuickActionMemoryPolicy.lean)
    }

    func testGroundedBrainstormUsesMemoryWithoutJudgeOrContradictionRecall() {
        let p = QuickActionMemoryPolicy.groundedBrainstorm

        XCTAssertTrue(p.includeGlobalMemory)
        XCTAssertTrue(p.includeEssentialStory)
        XCTAssertTrue(p.includeUserModel)
        XCTAssertTrue(p.includeMemoryEvidence)
        XCTAssertTrue(p.includeProjectMemory)
        XCTAssertTrue(p.includeConversationMemory)
        XCTAssertTrue(p.includeRecentConversations)
        XCTAssertTrue(p.includeProjectGoal)
        XCTAssertTrue(p.includeCitations)
        XCTAssertFalse(p.includeContradictionRecall)
        XCTAssertFalse(p.includeJudgeFocus)
        XCTAssertTrue(p.includeBehaviorProfile)
    }

    func testProjectOnlyPresetIncludesOnlyProjectLayersAndBehaviorProfile() {
        let p = QuickActionMemoryPolicy.fromStewardPreset(.projectOnly)

        XCTAssertFalse(p.includeGlobalMemory)
        XCTAssertFalse(p.includeEssentialStory)
        XCTAssertFalse(p.includeUserModel)
        XCTAssertFalse(p.includeMemoryEvidence)
        XCTAssertTrue(p.includeProjectMemory)
        XCTAssertFalse(p.includeConversationMemory)
        XCTAssertFalse(p.includeRecentConversations)
        XCTAssertTrue(p.includeProjectGoal)
        XCTAssertFalse(p.includeCitations)
        XCTAssertFalse(p.includeContradictionRecall)
        XCTAssertFalse(p.includeJudgeFocus)
        XCTAssertTrue(p.includeBehaviorProfile)
    }

    func testConversationOnlyPresetIncludesOnlyConversationLayerAndBehaviorProfile() {
        let p = QuickActionMemoryPolicy.fromStewardPreset(.conversationOnly)

        XCTAssertFalse(p.includeGlobalMemory)
        XCTAssertFalse(p.includeEssentialStory)
        XCTAssertFalse(p.includeUserModel)
        XCTAssertFalse(p.includeMemoryEvidence)
        XCTAssertFalse(p.includeProjectMemory)
        XCTAssertTrue(p.includeConversationMemory)
        XCTAssertFalse(p.includeRecentConversations)
        XCTAssertFalse(p.includeProjectGoal)
        XCTAssertFalse(p.includeCitations)
        XCTAssertFalse(p.includeContradictionRecall)
        XCTAssertFalse(p.includeJudgeFocus)
        XCTAssertTrue(p.includeBehaviorProfile)
    }

    func testSupportFirstDisablesContradictionRecallAndJudgeFocus() {
        let p = QuickActionMemoryPolicy.full.applyingChallengeStance(.supportFirst)

        XCTAssertTrue(p.includeGlobalMemory)
        XCTAssertTrue(p.includeProjectGoal)
        XCTAssertTrue(p.includeBehaviorProfile)
        XCTAssertFalse(p.includeContradictionRecall)
        XCTAssertFalse(p.includeJudgeFocus)
    }

    func testNonSupportChallengeStancesKeepPolicyUnchanged() {
        XCTAssertEqual(
            QuickActionMemoryPolicy.full.applyingChallengeStance(.useSilently),
            .full
        )
        XCTAssertEqual(
            QuickActionMemoryPolicy.full.applyingChallengeStance(.surfaceTension),
            .full
        )
    }
}

final class QuickActionModeAgentExtensionTests: XCTestCase {
    func testEachModeReturnsExpectedAgentType() {
        XCTAssertTrue(QuickActionMode.direction.agent() is DirectionAgent)
        XCTAssertTrue(QuickActionMode.brainstorm.agent() is BrainstormAgent)
        XCTAssertTrue(QuickActionMode.plan.agent() is PlanAgent)
    }

    func testEachAgentReportsCorrectMode() {
        XCTAssertEqual(QuickActionMode.direction.agent().mode, .direction)
        XCTAssertEqual(QuickActionMode.brainstorm.agent().mode, .brainstorm)
        XCTAssertEqual(QuickActionMode.plan.agent().mode, .plan)
    }
}
