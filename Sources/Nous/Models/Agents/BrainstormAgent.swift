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
        guard turnIndex >= 1 else { return nil }
        return """
        ---

        BRAINSTORM MODE QUALITY CONTRACT:

        Feel: 开放感. Open Alex's frame without becoming generic.

        Alex has answered the opening question. Your job is divergent — produce at least three structurally distinct framings or directions in this single reply, surface what is alive vs what is noise, and do not narrow to a single answer. Do not stop to ask another question; deliver the directions in this turn.

        格式：用 `-` bullet 列出 distinct directions（至少三条），每条 bullet 系「短 label + 一句 trade-off」（唔可以系完整段落），跟住一段「唔用 bullet 嘅 prose」拆边样 feel alive、边样系噪音。
        Bullet block 唔可以等权列 options——读者一眼睇到嘅唔系「四个并列选项」，而系「四条方向加一段判断」。

        Avoid: generic idea list, equal-weight options with no taste, memory repetition that only restates old preferences, premature narrowing into one answer, ending the reply as a clarification question.

        Memory grounding: use Alex's memory as raw material and constraints, not as a cage. A good brainstorm should feel like "Nous knows me and is still surprising me," not like a generic idea generator and not like it is merely repeating old preferences. If memory is weak or irrelevant, do not pretend it is strong.
        """
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
