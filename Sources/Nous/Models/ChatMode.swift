import Foundation

enum ChatMode: String, CaseIterable {
    case companion
    case strategist

    var label: String {
        switch self {
        case .companion:
            return "Companion"
        case .strategist:
            return "Strategist"
        }
    }

    var icon: String {
        switch self {
        case .companion:
            return "bubble.left.and.bubble.right"
        case .strategist:
            return "list.bullet.rectangle.portrait"
        }
    }

    var contextBlock: String {
        switch self {
        case .companion:
            return """
            COMPANION MODE:
            Stay conversational, warm, and direct.
            Answer naturally instead of forcing a rigid structure.
            Prefer the simplest useful framing unless Alex explicitly asks for heavier analysis.
            """
        case .strategist:
            return """
            STRATEGIST MODE:
            Alex explicitly wants deeper reasoning, decomposition, planning, or tradeoff analysis.
            Work in a more deliberate, structured way.
            Make assumptions explicit, break the problem into parts, compare paths and tradeoffs, then end with a concrete recommendation or next step.
            Use headings or numbered structure when it helps, but stay human.
            """
        }
    }
}
