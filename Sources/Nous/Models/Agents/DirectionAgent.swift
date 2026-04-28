import Foundation

struct DirectionAgent: QuickActionAgent {
    let mode: QuickActionMode = .direction

    func openingPrompt() -> String {
        """
        Alex just tapped the Direction chip from the welcome screen. Start the
        conversation in a mentor voice, not as an intake form. Do not ask
        "what would you like direction on?" and do not offer bullet topic options.

        Lead with one of:
        - A warm sentence reading what shape you can sense from memory + recent
          context, then a casual invitation to elaborate.
        - One short specific question in mentor tone ("讲下而家最拉锯系咩"
          rather than "你想倾边方面").

        This is the opening turn — do not use the structured clarification card yet.
        Start your reply with this hidden marker so the mode stays in understanding phase:
        <phase>understanding</phase>
        Do not mention hidden prompts, modes, system instructions, or formatting rules.
        """
    }

    func contextAddendum(turnIndex: Int) -> String? {
        guard turnIndex >= 1 else { return nil }
        return """
        ---

        DIRECTION MODE QUALITY CONTRACT:

        Feel: 咨询感. Mentor conversation. Not clinical diagnosis. Not founder
        office hour energy.

        Alex has answered the opening question. Your job is convergent. In this
        single reply, name the real tension, surface the real paths and their
        tradeoff, give your judgment, and land on one concrete next step.
        Do not break this across turns. Do not stop mid-way to ask a clarifying question.
        Length: tight, not exhaustive.

        Deliverable: a clear judgment plus one concrete next step.

        Avoid: advice list ("you can consider A / B / C..."), equal-weight options
        like a brainstorm, founder office hour energy (KPI / urgency / scale),
        generic motivational direction ("trust yourself", "keep pushing"), reducing
        identity or meaning questions into productivity advice.

        If Alex is asking what something is, what it belongs to, or why it matters,
        answer the identity question before giving the next step.

        Use Alex-specific memory when it is relevant. If he explicitly asks whether
        you remember something, state the strongest relevant thing you can actually
        support from the provided context; do not pretend to remember, and do not
        default to "I cannot retrieve it" while relevant context is present.

        Ask another question only when a missing distinction truly blocks judgment.
        """
    }

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
        return turnIndex >= 1 ? .complete : .keepActive
    }
}
