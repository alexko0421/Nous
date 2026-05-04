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
