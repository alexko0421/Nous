import Foundation

final class MemoryCurator {
    func assess(
        latestUserText: String?,
        boundaryLines: [String]
    ) -> MemoryCurationAssessment {
        let normalized = Self.normalized(latestUserText)
        if normalized.isEmpty {
            return rejected("empty latest user text", suppressionReason: .unspecified)
        }

        if SafetyGuardrails.containsHardMemoryOptOut(normalized) {
            return rejected("hard opt-out", suppressionReason: .hardOptOut)
        }

        if Self.looksLowSignalProbe(normalized) {
            return ephemeral("low-signal probe without new durable memory")
        }

        if Self.looksProbeOnlyQuestion(normalized) {
            return ephemeral("probe-only question without new durable memory")
        }

        if SafetyGuardrails.requiresConsentForSensitiveMemory(boundaryLines: boundaryLines),
           SafetyGuardrails.containsSensitiveMemory(normalized) {
            return consentRequired("sensitive memory needs consent")
        }

        if Self.looksTemporary(normalized), !Self.hasStableHorizon(normalized) {
            return ephemeral("temporary instruction or short-lived errand")
        }

        return stable(
            kind: Self.inferredKind(from: normalized),
            reason: "stable enough for memory refresh"
        )
    }

    private func stable(kind: MemoryKind?, reason: String) -> MemoryCurationAssessment {
        MemoryCurationAssessment(
            role: .memoryCurator,
            lifecycle: .stable,
            kind: kind,
            persistenceDecision: .persist,
            reason: reason
        )
    }

    private func ephemeral(_ reason: String) -> MemoryCurationAssessment {
        MemoryCurationAssessment(
            role: .memoryCurator,
            lifecycle: .ephemeral,
            kind: .temporaryContext,
            persistenceDecision: .suppress(.unspecified),
            reason: reason
        )
    }

    private func rejected(_ reason: String, suppressionReason: MemorySuppressionReason) -> MemoryCurationAssessment {
        MemoryCurationAssessment(
            role: .memoryCurator,
            lifecycle: .rejected,
            kind: nil,
            persistenceDecision: .suppress(suppressionReason),
            reason: reason
        )
    }

    private func consentRequired(_ reason: String) -> MemoryCurationAssessment {
        MemoryCurationAssessment(
            role: .memoryCurator,
            lifecycle: .consentRequired,
            kind: nil,
            persistenceDecision: .suppress(.sensitiveConsentRequired),
            reason: reason
        )
    }

    private static func looksTemporary(_ text: String) -> Bool {
        let phrases = [
            "today",
            "tomorrow",
            "right now",
            "for now",
            "this week",
            "今日",
            "聽日",
            "听日",
            "而家",
            "暂时",
            "暫時"
        ]
        return phrases.contains { text.contains($0) }
    }

    private static func looksLowSignalProbe(_ text: String) -> Bool {
        guard !hasDurableSignal(text) else { return false }
        let phrases = [
            "context unclear",
            "final probe",
            "recall probe",
            "qa probe",
            "memory probe",
            "probe:",
            "测试 probe",
            "測試 probe"
        ]
        return phrases.contains { text.contains($0) }
    }

    private static func looksProbeOnlyQuestion(_ text: String) -> Bool {
        guard isQuestionLike(text) else { return false }

        let probePhrases = [
            "基于你知道",
            "基於你知道",
            "based on what you know",
            "你记得",
            "你記得",
            "do you remember",
            "刚才",
            "剛才",
            "之前",
            "previously",
            "can you recall",
            "你有没有",
            "你有沒有",
            "有没有把",
            "有沒有把",
            "我到底",
            "什么时候我应该",
            "什麼時候我應該",
            "什么时候我應該",
            "你觉得",
            "你覺得",
            "这两个想法",
            "這兩個想法",
            "这个 project",
            "這個 project",
            "这个项目",
            "這個項目",
            "我现在需要你",
            "我現在需要你",
            "你应该用什么语气",
            "你應該用什麼語氣",
            "如果我之前"
        ]
        return probePhrases.contains { text.contains($0) }
    }

    private static func hasDurableSignal(_ text: String) -> Bool {
        let phrases = [
            "remember that",
            "记住",
            "記住",
            "from now on",
            "going forward",
            "以后",
            "以後",
            "prefer",
            "preference",
            "decision",
            "decided",
            "决定",
            "決定",
            "correction"
        ]
        return phrases.contains { text.contains($0) }
    }

    private static func isQuestionLike(_ text: String) -> Bool {
        text.contains("?") ||
            text.contains("？") ||
            text.hasSuffix("吗") ||
            text.hasSuffix("嗎") ||
            text.hasSuffix("咩") ||
            text.hasSuffix("么")
    }

    private static func hasStableHorizon(_ text: String) -> Bool {
        let phrases = [
            "from now on",
            "going forward",
            "long term",
            "以后",
            "以後",
            "长期",
            "長期"
        ]
        return phrases.contains { text.contains($0) }
    }

    private static func inferredKind(from text: String) -> MemoryKind? {
        if text.contains("prefer") ||
            text.contains("preference") ||
            text.contains("鍾意") ||
            text.contains("钟意") {
            return .preference
        }

        if text.contains("don't") ||
            text.contains("do not") ||
            text.contains("唔好") ||
            text.contains("不要") {
            return .boundary
        }

        if text.contains("decided") ||
            text.contains("decision") ||
            text.contains("决定") ||
            text.contains("決定") {
            return .decision
        }

        return nil
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "")
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
