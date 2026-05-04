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
