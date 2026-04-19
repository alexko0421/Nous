import Foundation

enum QuickActionMode: String, CaseIterable {
    case direction
    case brainstorm
    case mentalHealth

    var label: String {
        switch self {
        case .direction:
            return "Direction"
        case .brainstorm:
            return "Brainstorm"
        case .mentalHealth:
            return "Mental Health"
        }
    }

    var icon: String {
        switch self {
        case .direction:
            return "safari"
        case .brainstorm:
            return "sparkles"
        case .mentalHealth:
            return "heart.text.square"
        }
    }

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
        case .mentalHealth:
            return """
            I need space to talk this through gently and honestly.
            Don't over-diagnose or pretend certainty.
            Help me:
            1. name what I may be feeling,
            2. see what may be driving it,
            3. separate what needs care now from what can wait,
            4. take one small next step if I'm ready.
            If something sounds serious, say that clearly and carefully.
            """
        }
    }
}
