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
        XCTAssertNil(agent.contextAddendum(turnIndex: 1))
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
        XCTAssertNil(agent.contextAddendum(turnIndex: 1))
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

    func testUseSilentlyKeepsMemoryButSkipsContradictionAndJudgeFocus() {
        let p = QuickActionMemoryPolicy.full.applyingChallengeStance(.useSilently)

        XCTAssertTrue(p.includeGlobalMemory)
        XCTAssertTrue(p.includeEssentialStory)
        XCTAssertTrue(p.includeUserModel)
        XCTAssertTrue(p.includeMemoryEvidence)
        XCTAssertTrue(p.includeProjectMemory)
        XCTAssertTrue(p.includeConversationMemory)
        XCTAssertTrue(p.includeRecentConversations)
        XCTAssertTrue(p.includeProjectGoal)
        XCTAssertTrue(p.includeCitations)
        XCTAssertTrue(p.includeBehaviorProfile)
        XCTAssertFalse(p.includeContradictionRecall)
        XCTAssertFalse(p.includeJudgeFocus)
    }

    func testSurfaceTensionKeepsPolicyUnchanged() {
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
