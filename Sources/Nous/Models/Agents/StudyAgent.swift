import Foundation

struct StudyAgent: QuickActionAgent {
    let mode: QuickActionMode = .study

    func openingPrompt() -> String {
        """
        Alex just entered Study mode from the welcome screen. Read his recent
        conversations and source context, then guide him into a source-reading
        session: ask for the article/source if none is attached, or name the
        source you see and invite him to start with the first section. Study mode
        is for reading and learning, not planning, brainstorming, or judging too
        early.

        This is only the opening turn, so do not use the structured clarification card yet.
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
        parsed.keepsQuickActionMode ? .keepActive : .complete
    }
}
