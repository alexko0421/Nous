import Foundation

enum QuickActionMode: String, CaseIterable {
    case direction
    case brainstorm
    case plan

    // Includes "mental health" as a legacy alias so DB conversations created before
    // the rename (2026-04-26) still register as placeholder-titled chats.
    private static let placeholderConversationTitles: Set<String> = Set(
        Self.allCases.map { $0.label.lowercased() }
    ).union(["mental health"])

    var label: String {
        switch self {
        case .direction:
            return "Direction"
        case .brainstorm:
            return "Brainstorm"
        case .plan:
            return "Plan"
        }
    }

    var icon: String {
        switch self {
        case .direction:
            return "safari"
        case .brainstorm:
            return "brain"
        case .plan:
            return "map"
        }
    }

    // TODO: this property is not currently consumed in production. The actual
    // opening prompt sent to the LLM is built by ChatViewModel.quickActionOpeningPrompt(for:),
    // which references only mode.label as of 2026-04-26. This stays here to capture
    // design intent and so a future wire-up has a single source of truth.
    var prompt: String {
        switch self {
        case .direction:
            return """
            Help me get clear on my next step.
            Break this down into:
            1. the real paths in front of me,
            2. the tradeoff of each path,
            3. which option feels most aligned versus just easiest,
            4. the one missing question that matters most.
            Then give me a concrete next step.
            If one key detail is missing, ask once before you conclude. Otherwise give me the clearest next step you can.
            """
        case .brainstorm:
            return """
            Let's brainstorm without forcing an answer too early.
            Give me:
            1. several distinct directions,
            2. the pattern behind them,
            3. which ideas feel alive,
            4. which ones are probably just noise.
            Be bold, but keep it grounded in reality.
            """
        case .plan:
            return """
            Let's plan this without pretending it's simple.
            Walk through with me:
            - the actual outcome I'm chasing (not the surface activity),
            - the few moves that really matter, and what's just noise,
            - what order makes sense given how I actually work,
            - where I'll likely stall, and what catches me when I do,
            - one concrete thing I can start today.

            If the outcome, timeframe, or my real capacity is genuinely unclear,
            ask me one short question first. Otherwise, plan now using what you know about me.

            Stay specific to me. I don't need a generic study plan.
            """
        }
    }

    static func isPlaceholderConversationTitle(_ title: String) -> Bool {
        placeholderConversationTitles.contains(
            title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
}
