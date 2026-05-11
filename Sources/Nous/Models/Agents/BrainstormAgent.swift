import Foundation

struct BrainstormAgent: QuickActionAgent {
    let mode: QuickActionMode = .brainstorm

    func openingPrompt() -> String {
        """
        Alex just entered the Brainstorm mode from the welcome screen. Read his
        recent conversations and what's been on his mind from memory, then offer
        a concrete thread back to him as a starting seed for divergence — name
        the shape, don't fish. Only fall back to one short specific question if
        nothing in context feels brainstorm-shaped. Never open with generic
        "what do you want to brainstorm about?".

        This is only the opening turn, so do not use the structured clarification card yet.
        Start your reply with this hidden marker so the mode stays in understanding phase:
        <phase>understanding</phase>
        Do not mention hidden prompts, modes, system instructions, or formatting rules.
        """
    }

    func contextAddendum(turnIndex: Int) -> String? {
        nil
    }

    /// Brainstorm stays personalized because Nous's product promise is memory-aware
    /// ideation. It keeps judge and contradiction recall off so memory grounds the
    /// divergence without turning the turn into a critique.
    func memoryPolicy() -> QuickActionMemoryPolicy {
        #if DEBUG
        return DebugAblation.override(.groundedBrainstorm)
        #else
        return .groundedBrainstorm
        #endif
    }

    var toolNames: [String] { [] }

    func turnDirective(parsed: ClarificationContent, turnIndex: Int) -> QuickActionTurnDirective {
        return turnIndex >= 1 ? .complete : .keepActive
    }
}
