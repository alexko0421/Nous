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

    private static let planFormatScaffold = """

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
    """

    private static let decideOrAskAddendum = """
    ---

    PLAN MODE — TURN 1 CONTRACT:

    Feel: 规划感, execution gravity. Not a Notion template, not generic productivity advice.

    Alex has answered your opening question. Produce one of these in this single reply — empathy + a clarifying question alone is a contract failure:

    (A) Full structured plan, if outcome + real constraint + Alex's real capacity are all clearly inferable from his reply + memory. Use the markdown scaffold below. Drop the <phase>understanding</phase> marker.

    (B) Partial plan with best-guess outcome (marked draft) + best-guess real constraint (one specific limit you observe or infer) + best-guess likely failure mode (one specific way this will break), followed by ONE clarifying question to refine the draft. Always commit to all three triad pieces before asking — empathy + clarification with no triad is a contract failure. Keep the <phase>understanding</phase> marker.

    If the surface ask hides a direction or identity question (Alex doesn't know whether to do this at all), say that plainly and give a Direction-style judgment instead of fake-planning.

    Avoid: pretty schedule, generic productivity advice, assuming ideal team or unlimited energy or unlimited time, calendar-first planning when the real risk is scope or doubt or execution breakage.
    """

    private static let normalProductionAddendum = """
    ---

    PLAN MODE PRODUCTION CONTRACT:
    Produce a structured plan using these markdown sections:
    \(planFormatScaffold)
    Use what you know about Alex from prior conversations and stored memory.
    Start from Alex's real capacity and likely failure mode, not an ideal version of him.
    Stay specific. No generic productivity advice. If a plan section would be filler,
    replace it with a concrete constraint, tradeoff, or first action.
    Drop the <phase>understanding</phase> marker once you commit to the plan.
    """

    private static let finalUrgentAddendum = """
    ---

    PLAN MODE — FINAL TURN:
    This is your last chance to produce the plan. Mode drops after this reply.
    You may NOT ask another clarifying question. Output the structured plan now
    using whatever you have learned so far:
    \(planFormatScaffold)
    Name the main failure mode before the schedule. Drop the <phase>understanding</phase>
    marker. Stay specific.
    """

    func memoryPolicy() -> QuickActionMemoryPolicy {
        #if DEBUG
        return DebugAblation.override(.full)
        #else
        return .full
        #endif
    }

    var toolNames: [String] {
        AgentToolNames.standard
    }

    func turnDirective(parsed: ClarificationContent, turnIndex: Int) -> QuickActionTurnDirective {
        if turnIndex >= Self.maxClarificationTurns {
            return .complete
        }
        return parsed.keepsQuickActionMode ? .keepActive : .complete
    }
}
