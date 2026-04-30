import Foundation

protocol ShadowPatternPromptProviding {
    func promptHints(
        userId: String,
        currentInput: String,
        activeQuickActionMode: QuickActionMode?,
        now: Date
    ) throws -> [String]
}

final class ShadowPatternPromptProvider: ShadowPatternPromptProviding {
    private let store: any ShadowLearningStoring

    init(store: any ShadowLearningStoring) {
        self.store = store
    }

    func promptHints(
        userId: String = "alex",
        currentInput: String,
        activeQuickActionMode: QuickActionMode?,
        now: Date
    ) throws -> [String] {
        let patterns = try store.fetchPromptEligiblePatterns(userId: userId, now: now, limit: 16)
        let inputTerms = terms(from: currentInput)
        let modeTerms = activeQuickActionMode.map { terms(from: "\($0.rawValue) \($0.label)") } ?? []

        return patterns
            .compactMap { pattern -> (pattern: ShadowLearningPattern, score: Double)? in
                guard let score = score(pattern, inputTerms: inputTerms, modeTerms: modeTerms) else {
                    return nil
                }
                return (pattern, score)
            }
            .sorted {
                if $0.score == $1.score {
                    return $0.pattern.label < $1.pattern.label
                }
                return $0.score > $1.score
            }
            .prefix(3)
            .map(\.pattern.promptFragment)
    }

    private func score(
        _ pattern: ShadowLearningPattern,
        inputTerms: Set<String>,
        modeTerms: Set<String>
    ) -> Double? {
        let triggerTerms = terms(from: pattern.triggerHint)
        let inputOverlap = triggerTerms.intersection(inputTerms).count
        let modeOverlap = triggerTerms.intersection(modeTerms).count
        guard inputOverlap > 0 || modeOverlap > 0 else {
            return nil
        }

        let overlapScore = min(0.45, Double(inputOverlap) * 0.15)
        let modeScore = min(0.10, Double(modeOverlap) * 0.05)
        let responseBehaviorBonus = pattern.kind == .responseBehavior ? 0.08 : 0.0
        return pattern.weight * 0.30
            + pattern.confidence * 0.20
            + overlapScore
            + modeScore
            + responseBehaviorBonus
    }

    private func terms(from text: String) -> Set<String> {
        Set(
            text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 3 }
        )
    }
}
