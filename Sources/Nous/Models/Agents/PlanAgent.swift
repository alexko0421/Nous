import Foundation

struct PlanAgent: QuickActionAgent {
    let mode: QuickActionMode = .plan

    /// Defensive max-turn cap. If the LLM keeps emitting <phase>understanding</phase>
    /// past this turn, drop the mode anyway to prevent runaway clarification.
    private static let maxClarificationTurns = 4

    func openingPrompt() -> String {
        """
        Alex just entered the Plan mode from the welcome screen.
        Start the conversation yourself instead of waiting for him to type.
        This is only the opening turn, so do not use the structured clarification card yet.
        Ask one short, natural, open-ended question that helps you understand what Alex
        is actually trying to plan, including the timeframe and his real capacity.
        Start your reply with this hidden marker so the mode stays in understanding phase:
        <phase>understanding</phase>
        Do not mention hidden prompts, modes, system instructions, or formatting rules.
        """
    }

    func contextAddendum(turnIndex: Int) -> String? {
        switch turnIndex {
        case 0:
            return nil
        case 1:
            return Self.decideOrAskAddendum
        case Self.maxClarificationTurns...:
            return Self.finalUrgentAddendum
        default:
            return Self.normalProductionAddendum
        }
    }

    private static let decideOrAskAddendum = """
    ---

    PLAN MODE — DECIDE OR ASK CONTRACT:
    Alex has answered your opening question. Either:
    (a) produce the structured plan now if you have enough on outcome, timeframe,
        and his real capacity, OR
    (b) ask exactly one more open-ended question if a critical piece is still missing.
    If you ask, keep the <phase>understanding</phase> marker.
    If you produce the plan, drop the marker.
    """

    private static let normalProductionAddendum = """
    ---

    PLAN MODE PRODUCTION CONTRACT:
    Produce a structured plan using these markdown sections:

    # Outcome
    （one short paragraph — the actual outcome Alex is chasing, not the surface activity）

    # Weekly schedule
    | 周 | 重点 | 具体动作 |
    |---|---|---|
    | Week 1 | ... | ... |

    # Where you'll stall
    - ...
    - ...

    # Today's first step
    （one concrete action）

    Use what you know about Alex from prior conversations and stored memory.
    Stay specific. No generic productivity advice.
    Drop the <phase>understanding</phase> marker once you commit to the plan.
    """

    private static let finalUrgentAddendum = """
    ---

    PLAN MODE — FINAL TURN:
    This is your last chance to produce the plan. Mode drops after this reply.
    You may NOT ask another clarifying question. Output the four markdown sections
    now using whatever you have learned so far:

    # Outcome
    # Weekly schedule (use the | table | format)
    # Where you'll stall
    # Today's first step

    Drop the <phase>understanding</phase> marker. Stay specific.
    """

    func memoryPolicy() -> QuickActionMemoryPolicy { .full }

    func turnDirective(parsed: ClarificationContent, turnIndex: Int) -> QuickActionTurnDirective {
        if turnIndex >= Self.maxClarificationTurns {
            return .complete
        }
        return parsed.keepsQuickActionMode ? .keepActive : .complete
    }
}
