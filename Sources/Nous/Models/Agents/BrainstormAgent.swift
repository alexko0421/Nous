import Foundation

struct BrainstormAgent: QuickActionAgent {
    let mode: QuickActionMode = .brainstorm

    func openingPrompt() -> String {
        """
        Alex just entered the Brainstorm mode from the welcome screen.
        Start the conversation yourself instead of waiting for him to type.
        This is only the opening turn, so do not use the structured clarification card yet.
        Ask one short, natural, open-ended question first to understand what he wants to brainstorm about.
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
