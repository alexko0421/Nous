import Foundation

struct ShadowPatternLexicon {
    static let shared = ShadowPatternLexicon()

    static let aliasMatchBonus = 0.45

    private let aliasesByLabel: [String: [String]]

    init(aliasesByLabel: [String: [String]] = ShadowPatternLexicon.defaultAliases) {
        self.aliasesByLabel = aliasesByLabel.mapValues { aliases in
            aliases
                .map(Self.normalized)
                .filter(Self.isAllowedAlias)
                .filter { !$0.isEmpty }
        }
    }

    func aliases(for label: String) -> [String] {
        aliasesByLabel[label] ?? []
    }

    func matchesObservation(label: String, text: String) -> Bool {
        containsAlias(label: label, text: text)
    }

    func matchingLabels(in text: String) -> [String] {
        aliasesByLabel.keys
            .filter { containsAlias(label: $0, text: text) }
            .sorted()
    }

    func aliasMatchBonus(label: String, text: String) -> Double {
        containsAlias(label: label, text: text) ? Self.aliasMatchBonus : 0.0
    }

    private func containsAlias(label: String, text: String) -> Bool {
        let normalizedText = Self.normalized(text)
        return aliases(for: label).contains { alias in
            normalizedText.contains(alias)
        }
    }

    static func normalized(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAllowedAlias(_ alias: String) -> Bool {
        let cjkCount = alias.unicodeScalars.filter(Self.isCJK).count

        let words = alias
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        let asciiWords = words.filter { word in
            word.allSatisfy { $0.isASCII && $0.isLetter }
        }

        if cjkCount == 0 {
            return words.count >= 2 || alias == "inversion"
        }

        if asciiWords.isEmpty {
            return cjkCount >= 3
        }

        return cjkCount >= 2 && asciiWords.contains { $0.count >= 4 }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static let defaultAliases: [String: [String]] = [
        "first_principles_decision_frame": [
            "first principle",
            "first principles",
            "first-principles",
            "第一性原理",
            "从根上",
            "由底层逻辑",
            "由底層邏輯"
        ],
        "inversion_before_recommendation": [
            "反过来",
            "反過來",
            "inversion",
            "worst version",
            "最坏版本",
            "最壞版本"
        ],
        "pain_test_for_product_scope": [
            "会痛不痛",
            "会痛唔痛",
            "會痛唔痛",
            "痛不痛",
            "痛唔痛",
            "冇呢样嘢",
            "无呢样嘢",
            "没有这个",
            "pain test"
        ],
        "concrete_over_generic": [
            "讲到太泛",
            "講到太泛",
            "太抽象",
            "具体例子",
            "具體例子",
            "concrete example",
            "具体 tradeoff",
            "具體 tradeoff"
        ],
        "direct_pushback_when_wrong": [
            "push back",
            "直接说",
            "直接講",
            "直接讲",
            "不要顺着我",
            "不要順著我",
            "唔好顺住我",
            "唔好順住我"
        ],
        "organize_before_judging": [
            "我说不清",
            "我講唔清",
            "我讲唔清",
            "我讲到好乱",
            "我講到好亂",
            "帮我整理",
            "幫我整理",
            "先整理",
            "organize this"
        ]
    ]
}
