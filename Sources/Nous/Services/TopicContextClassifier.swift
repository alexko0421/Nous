import Foundation

final class TopicContextClassifier {
    private struct LaneRule {
        let lane: TopicContextLane
        let keywords: [String]
        let subtopic: String
    }

    private let rules: [LaneRule] = [
        LaneRule(
            lane: .nousProduct,
            keywords: [
                "nous", "source recall", "skill", "scratchpad", "quick mode",
                "voice", "node", "recall", "rag", "codex", "xcode", "swiftui",
                "回憶", "語音"
            ],
            subtopic: "nous product / memory / source recall"
        ),
        LaneRule(
            lane: .aiResearch,
            keywords: [
                "ai", "agent", "operator", "model", "openai", "anthropic",
                "llm", "research", "hermes", "claude", "gemini", "reasoning",
                "人工智能", "模型", "研究"
            ],
            subtopic: "ai research / agents / models"
        ),
        LaneRule(
            lane: .education,
            keywords: [
                "smc", "school", "visa", "f-1", "class", "study", "learn",
                "learning", "assignment", "college", "education", "student",
                "campus", "course", "學校", "讀書", "學習", "功課", "課"
            ],
            subtopic: "school / visa / learning depth"
        ),
        LaneRule(
            lane: .finance,
            keywords: [
                "stock", "finance", "investing", "investment", "fomo",
                "spending", "money", "market", "bank", "budget", "cash",
                "消費", "投資", "股票", "錢", "市場"
            ],
            subtopic: "money / investing / spending"
        ),
        LaneRule(
            lane: .personalReflection,
            keywords: [
                "identity", "values", "life", "thinking", "relationship",
                "feeling", "reflection", "stress", "pressure", "pattern",
                "反思", "價值", "壓力", "感受", "關係", "人生"
            ],
            subtopic: "identity / feelings / personal pattern"
        ),
        LaneRule(
            lane: .travelLogistics,
            keywords: [
                "travel", "trip", "itinerary", "wwdc", "apple park", "flight",
                "hotel", "route", "airport", "ticket", "行程", "旅行", "機票",
                "酒店", "路線"
            ],
            subtopic: "travel / itinerary / logistics"
        )
    ]

    func classify(text: String) -> TopicContextClassification {
        let normalized = text.lowercased()
        let asciiTokens = Set(normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        let scores = rules.map { rule -> (rule: LaneRule, score: Int) in
            let score = rule.keywords.reduce(0) { partial, keyword in
                Self.matches(keyword: keyword, normalizedText: normalized, asciiTokens: asciiTokens)
                    ? partial + 1
                    : partial
            }
            return (rule, score)
        }

        guard let top = scores.max(by: { $0.score < $1.score }),
              top.score > 0
        else {
            return TopicContextClassification(
                primaryLane: .general,
                secondaryLanes: [],
                subtopicLabel: "general",
                confidence: 0.3,
                source: .fallback
            )
        }

        let secondary = scores
            .filter { $0.rule.lane != top.rule.lane && $0.score > 0 }
            .sorted {
                if $0.score == $1.score {
                    return $0.rule.lane.rawValue < $1.rule.lane.rawValue
                }
                return $0.score > $1.score
            }
            .prefix(2)
            .map(\.rule.lane)

        let confidence = min(0.95, 0.7 + (Double(top.score) * 0.05))
        return TopicContextClassification(
            primaryLane: top.rule.lane,
            secondaryLanes: Array(secondary),
            subtopicLabel: top.rule.subtopic,
            confidence: confidence,
            source: .deterministic
        )
    }

    private static func matches(
        keyword: String,
        normalizedText: String,
        asciiTokens: Set<String>
    ) -> Bool {
        let normalizedKeyword = keyword.lowercased()
        let isAsciiWord = normalizedKeyword.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber)
        }
        if isAsciiWord {
            return asciiTokens.contains(normalizedKeyword)
        }
        return normalizedText.contains(normalizedKeyword)
    }
}
