import Foundation

enum ShadowPatternLifecycle {
    static let correctionSuppressionWindow: TimeInterval = 7 * 86_400
    static let fadeAfter: TimeInterval = 30 * 86_400
    static let retireAfter: TimeInterval = 60 * 86_400

    static func afterObservation(
        _ pattern: ShadowLearningPattern,
        evidenceMessageId: UUID,
        at date: Date
    ) -> ShadowLearningPattern {
        var updated = pattern

        if !updated.evidenceMessageIds.contains(evidenceMessageId) {
            updated.evidenceMessageIds.append(evidenceMessageId)
        }

        updated.confidence = clamped(updated.confidence + 0.06)
        updated.weight = clamped(updated.weight + 0.05)
        if updated.evidenceMessageIds.count >= 3 {
            updated.confidence = max(updated.confidence, 0.65)
            updated.weight = max(updated.weight, 0.30)
        }
        updated.lastSeenAt = date
        updated.lastReinforcedAt = date
        updated.status = promotedStatus(for: updated, revivedFromRetired: pattern.status == .retired)
        activateIfNeeded(&updated, previousStatus: pattern.status, at: date)

        if updated.status != .retired {
            updated.activeUntil = nil
        }

        return updated
    }

    static func afterReinforcement(
        _ pattern: ShadowLearningPattern,
        at date: Date
    ) -> ShadowLearningPattern {
        var updated = pattern

        updated.confidence = clamped(updated.confidence + 0.08)
        updated.weight = clamped(updated.weight + 0.07)

        if updated.evidenceMessageIds.count >= 3 {
            updated.confidence = max(updated.confidence, 0.70)
            updated.weight = max(updated.weight, 0.30)
        }

        updated.lastSeenAt = date
        updated.lastReinforcedAt = date
        updated.status = promotedStatus(for: updated, revivedFromRetired: pattern.status == .retired)
        activateIfNeeded(&updated, previousStatus: pattern.status, at: date)

        if updated.status != .retired {
            updated.activeUntil = nil
        }

        return updated
    }

    static func afterCorrection(
        _ pattern: ShadowLearningPattern,
        at date: Date
    ) -> ShadowLearningPattern {
        var updated = pattern

        updated.confidence = clamped(updated.confidence - 0.18)
        updated.weight = clamped(updated.weight - 0.30)
        updated.lastCorrectedAt = date

        if updated.status != .retired {
            updated.status = .fading
        }

        return updated
    }

    static func afterDecay(
        _ pattern: ShadowLearningPattern,
        at date: Date
    ) -> ShadowLearningPattern {
        guard pattern.status != .retired else {
            return pattern
        }

        let lastUsefulDate = pattern.lastReinforcedAt ?? pattern.lastSeenAt
        let age = date.timeIntervalSince(lastUsefulDate)
        var updated = pattern

        if age >= retireAfter && updated.weight < 0.20 {
            updated.status = .retired
            updated.activeUntil = date
            return updated
        }

        if age >= fadeAfter {
            updated.status = .fading
            updated.confidence = clamped(updated.confidence - 0.08)
            updated.weight = clamped(updated.weight - 0.08)
        }

        return updated
    }

    static func isPromptEligible(
        _ pattern: ShadowLearningPattern,
        now: Date
    ) -> Bool {
        guard pattern.status == .soft || pattern.status == .strong else {
            return false
        }

        guard pattern.confidence >= 0.65, pattern.weight >= 0.25 else {
            return false
        }

        if let lastCorrectedAt = pattern.lastCorrectedAt,
           now.timeIntervalSince(lastCorrectedAt) < correctionSuppressionWindow {
            return false
        }

        return true
    }

    private static func promotedStatus(
        for pattern: ShadowLearningPattern,
        revivedFromRetired: Bool
    ) -> ShadowPatternStatus {
        let evidenceCount = pattern.evidenceMessageIds.count
        let qualifiesStrong = evidenceCount >= 5 && pattern.confidence >= 0.82 && pattern.weight >= 0.55
        let qualifiesSoft = evidenceCount >= 3 && pattern.confidence >= 0.65 && pattern.weight >= 0.30

        if qualifiesStrong && !revivedFromRetired {
            return .strong
        }

        if qualifiesSoft || (qualifiesStrong && revivedFromRetired) {
            return .soft
        }

        if pattern.status == .retired {
            return .retired
        }

        return pattern.status
    }

    private static func activateIfNeeded(
        _ pattern: inout ShadowLearningPattern,
        previousStatus: ShadowPatternStatus,
        at date: Date
    ) {
        let isActive = pattern.status == .soft || pattern.status == .strong
        let wasActive = previousStatus == .soft || previousStatus == .strong

        if isActive && (!wasActive || pattern.activeFrom == nil) {
            pattern.activeFrom = date
        }
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
