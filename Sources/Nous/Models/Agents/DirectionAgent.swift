import Foundation

struct DirectionAgent: QuickActionAgent {
    let mode: QuickActionMode = .direction

    func openingPrompt() -> String {
        """
        Alex just tapped the Direction chip from the welcome screen. Read his
        recent conversations and what's been on his mind from memory, then lead
        in mentor voice with a warm sentence naming the shape you sense and a
        casual invitation to elaborate. Only fall back to a short specific
        question in mentor tone ("讲下而家最拉锯系咩" rather than "你想倾边方面")
        if nothing in context feels concrete enough to name. Never ask "what
        would you like direction on?" or offer bullet topic options.

        This is the opening turn — do not use the structured clarification card yet.
        Start your reply with this hidden marker so the mode stays in understanding phase:
        <phase>understanding</phase>
        Do not mention hidden prompts, modes, system instructions, or formatting rules.
        """
    }

    func contextAddendum(turnIndex: Int) -> String? {
        nil
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
