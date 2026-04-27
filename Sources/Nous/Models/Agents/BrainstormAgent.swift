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

        BRAINSTORM MODE PRODUCTION CONTRACT:
        Alex has answered the opening question. Your job is divergent.
        Generate genuinely distinct directions, surface the pattern behind them, and
        call out which feel alive vs which are probably noise. Do NOT narrow to a single
        answer.

        格式：用 `-` bullet 列出 distinct directions，每条 bullet 系「短 label + 一句 trade-off」
        （唔可以系完整段落），跟住一段「唔用 bullet 嘅 prose」拆边样 feel alive、边样系噪音。
        Bullet block 唔可以等权列 options——读者一眼睇到嘅唔系「四个并列选项」，
        而系「四条方向加一段判断」。

        Bias prevention: this turn intentionally runs without personal-memory layers
        (no userModel, no evidence, no project context, no project goal, no recent
        conversations, no RAG, no judge inference, no behavior profile).
        Lean into novelty rather than what you would assume Alex prefers from past chats.
        """
    }

    /// Brainstorm runs lean to actually achieve the bias-free divergence the contract
    /// promises. Strips all 12 memory layers; only anchor.md + chatMode block + the
    /// ACTIVE QUICK MODE marker + this addendum survive.
    func memoryPolicy() -> QuickActionMemoryPolicy { .lean }

    func turnDirective(parsed: ClarificationContent, turnIndex: Int) -> QuickActionTurnDirective {
        return turnIndex >= 1 ? .complete : .keepActive
    }
}
