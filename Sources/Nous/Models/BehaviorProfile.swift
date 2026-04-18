import Foundation

/// A swappable per-turn behavior block selected by the `ProvocationJudge`.
/// Sits between the summary context and the (optional) focus block in the
/// composed system prompt. See spec:
/// docs/superpowers/specs/2026-04-17-proactive-surfacing-design.md
enum BehaviorProfile: String, Equatable {
    case supportive
    case provocative

    /// Final wording is iterated in PR 6 once PR 4 is live and telemetry
    /// is flowing. These initial strings are intentionally short and safe.
    var contextBlock: String {
        switch self {
        case .supportive:
            return """
            BEHAVIOR: SUPPORTIVE
            Use retrieved memory silently to inform your reply.
            Do not interrupt the user to call out contradictions or relevant prior ideas in this turn.
            Stay in the tone set by the active ChatMode.
            """
        case .provocative:
            return """
            BEHAVIOR: PROVOCATIVE
            There is a specific prior memory worth calling out this turn (see the RELEVANT PRIOR MEMORY block that follows this one).
            Acknowledge Alex's current point briefly.
            Surface the referenced prior memory: quote a key line faithfully if one exists, otherwise paraphrase tightly — never reword it into a summary.
            Name the tension in plain language. Ask one short clarifying question or invite Alex to reconcile the two.
            Do not lecture or moralize. Stay in the tone set by the active ChatMode (softer under companion, sharper under strategist).
            """
        }
    }

    /// Maps a verdict to the profile the orchestrator should apply for this turn.
    init(verdict: JudgeVerdict) {
        self = verdict.shouldProvoke ? .provocative : .supportive
    }
}
