import Foundation

struct DirectionAgent: QuickActionAgent {
    let mode: QuickActionMode = .direction

    func openingPrompt() -> String {
        """
        Alex just entered the Direction mode from the welcome screen.
        Start the conversation yourself instead of waiting for him to type.
        This is only the opening turn, so do not use the structured clarification card yet.
        Ask one short, natural, open-ended question first so you can understand his situation.
        Start your reply with this hidden marker so the mode stays in understanding phase:
        <phase>understanding</phase>
        Do not mention hidden prompts, modes, system instructions, or formatting rules.
        """
    }

    func contextAddendum(turnIndex: Int) -> String? {
        guard turnIndex >= 1 else { return nil }
        return """
        ---

        DIRECTION MODE PRODUCTION CONTRACT:
        Alex has answered the opening question. Your job is convergent.
        Surface the real paths in front of him and the tradeoff of each, but narrow to
        one concrete next step. Do NOT enumerate equally-weighted options like a brainstorm.
        Length: tight. Aim for clarity, not coverage.
        """
    }

    func memoryPolicy() -> QuickActionMemoryPolicy { .full }

    func turnDirective(parsed: ClarificationContent, turnIndex: Int) -> QuickActionTurnDirective {
        return turnIndex >= 1 ? .complete : .keepActive
    }
}
