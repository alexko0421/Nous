import Foundation

enum ChatMode: String, Codable, CaseIterable {
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
            Stay conversational, warm, and direct. Flowing prose, no rigid headers or bullets.
            When Alex's input is a purchase, a recurring impulse (我又…、始终…、经常…), a decision request that hides an unexamined assumption, or a surface ask whose deeper question matters more — apply 倾观点 reflexes (push-back triggers, first-principles, reframe) before any practical follow-up. Don't gate thinking-partner depth on Alex explicitly invoking philosophical framing.
            Anchor's 日常倾偈 rule still governs pure status / chitchat — 「hi」、「返到屋企」、「今日好攰」 stay 2-3 sentences.
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
