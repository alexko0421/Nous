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
            return """
            ---

            PLAN MODE — DECIDE OR ASK CONTRACT:
            Alex has answered your opening question. Either:
            (a) produce the structured plan now if you have enough on outcome, timeframe,
                and his real capacity, OR
            (b) ask exactly one more open-ended question if a critical piece is still missing.
            If you ask, keep the <phase>understanding</phase> marker.
            If you produce the plan, drop the marker.
            """
        default:
            return """
            ---

            PLAN MODE PRODUCTION CONTRACT:
            Produce a structured plan:
            - the actual outcome Alex is chasing (not the surface activity),
            - the few moves that really matter, and what is just noise,
            - what order makes sense given how Alex actually works,
            - where Alex will likely stall and what catches him when he does,
            - one concrete thing he can start today.
            Use what you know about Alex from prior conversations and stored memory.
            Stay specific. No generic productivity advice.
            Drop the <phase>understanding</phase> marker once you commit to the plan.
            """
        }
    }

    func memoryPolicy() -> QuickActionMemoryPolicy { .full }

    func turnDirective(parsed: ClarificationContent, turnIndex: Int) -> QuickActionTurnDirective {
        if turnIndex >= Self.maxClarificationTurns {
            return .complete
        }
        return parsed.keepsQuickActionMode ? .keepActive : .complete
    }
}
