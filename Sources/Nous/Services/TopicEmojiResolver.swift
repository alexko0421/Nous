import Foundation

enum TopicEmojiResolver {
    private static let rules: [(emoji: String, keywords: [String])] = [
        ("🍜", ["食", "吃", "饮", "餐", "飯", "饭", "餸", "what to eat", "eat", "food", "meal", "dinner", "lunch", "breakfast", "recipe", "cook", "cooking"]),
        ("💼", ["business", "startup", "company", "product", "sales", "market", "marketing", "客户", "客戶", "商业", "生意", "创业", "創業", "brand"]),
        ("🧭", ["direction", "next step", "what should i do", "路线", "方向", "下一步", "roadmap", "plan", "planning", "decide", "decision"]),
        ("💡", ["brainstorm", "idea", "ideas", "concept", "creative", "创意", "創意", "諗法", "想法", "点子"]),
        ("💚", ["mental", "emotion", "feeling", "feelings", "therapy", "anxiety", "stress", "sad", "upset", "心理", "情绪", "情緒", "感受", "压力", "壓力", "焦虑", "焦慮"]),
        ("💕", ["love", "relationship", "dating", "girl", "boy", "friend", "crush", "真心", "拍拖", "感情", "关系", "關係", "恋爱", "戀愛"]),
        ("💻", ["code", "coding", "bug", "swift", "xcode", "app", "ui", "frontend", "backend", "program", "programming", "开发", "開發", "工程", "debug"]),
        ("📚", ["study", "school", "college", "class", "exam", "homework", "learn", "learning", "课程", "課程", "学校", "學校", "考试", "考試", "visa"]),
        ("✈️", ["travel", "trip", "flight", "hotel", "vacation", "austin", "tokyo", "japan", "taiwan", "香港", "旅行", "行程"]),
        ("💰", ["money", "finance", "budget", "pricing", "revenue", "profit", "investment", "invest", "fund", "cash", "金钱", "金錢", "预算", "預算", "收入"]),
        ("🏃", ["health", "workout", "gym", "run", "sleep", "diet", "body", "exercise", "健身", "运动", "運動", "睡眠", "健康"]),
        ("✍️", ["write", "writing", "essay", "note", "journal", "post", "article", "文案", "写作", "寫作", "文章"]),
    ]
    static let allowedEmojis = Set(rules.map(\.emoji) + ["💬", "📝", "🔗", "📄"])

    static func emoji(for node: NousNode) -> String {
        if let stored = storedEmoji(from: node.emoji) {
            return stored
        }

        let haystack = "\(node.title) \(node.content)".lowercased()

        for rule in rules {
            if rule.keywords.contains(where: haystack.contains) {
                return rule.emoji
            }
        }

        return fallbackEmoji(for: node.type)
    }

    static func storedEmoji(from text: String?) -> String? {
        guard let text else { return nil }
        return allowedEmojis.first(where: text.contains)
    }

    static func fallbackEmoji(for type: NodeType) -> String {
        switch type {
        case .conversation:
            return "💬"
        case .note:
            return "📝"
        case .source:
            return "🔗"
        }
    }
}
