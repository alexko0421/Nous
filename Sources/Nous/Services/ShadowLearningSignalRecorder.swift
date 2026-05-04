import Foundation

final class ShadowLearningSignalRecorder {
    private let store: any ShadowLearningStoring
    private let lexicon: ShadowPatternLexicon

    init(store: any ShadowLearningStoring, lexicon: ShadowPatternLexicon = .shared) {
        self.store = store
        self.lexicon = lexicon
    }

    func recordSignals(
        from message: Message,
        userId: String = "alex",
        maxSignals: Int? = nil
    ) throws {
        guard message.role == .user else { return }
        if let maxSignals, maxSignals <= 0 { return }

        let text = message.content.lowercased()
        let now = message.timestamp

        if isCorrection(text, for: "first_principles_decision_frame") {
            if let existing = try store.fetchPattern(
                userId: userId,
                kind: .thinkingMove,
                label: "first_principles_decision_frame"
            ) {
                if try store.hasEvent(
                    userId: userId,
                    patternId: existing.id,
                    sourceMessageId: message.id,
                    eventType: .corrected
                ) {
                    return
                }

                let updated = ShadowPatternLifecycle.afterCorrection(existing, at: now)
                try store.upsertPattern(updated)
                try store.appendEvent(LearningEvent(
                    id: UUID(),
                    userId: userId,
                    patternId: updated.id,
                    sourceMessageId: message.id,
                    eventType: .corrected,
                    note: "User asked not to use first-principles framing in this context.",
                    createdAt: now
                ))
            }
            return
        }

        var recordedCount = 0
        for definition in Self.definitions where lexicon.matchesObservation(label: definition.label, text: text) {
            if let maxSignals, recordedCount >= maxSignals {
                break
            }
            let didRecord = try recordObservation(definition, message: message, userId: userId, now: now)
            if didRecord {
                recordedCount += 1
            }
        }
    }

    func recordFeedbackSignal(
        feedback: JudgeFeedback,
        reason: JudgeFeedbackReason? = nil,
        note: String? = nil,
        sourceMessageId: UUID,
        userId: String = "alex",
        now: Date = Date()
    ) throws {
        let definition = Self.feedbackDefinition(feedback: feedback, reason: reason)
        try clearConflictingFeedbackSignals(
            keeping: definition,
            sourceMessageId: sourceMessageId,
            userId: userId,
            now: now
        )
        let existing = try store.fetchPattern(
            userId: userId,
            kind: .responseBehavior,
            label: definition.label
        )
        let eventType = feedback == .up ? LearningEventType.reinforced : .corrected
        if let existing,
           existing.evidenceMessageIds.contains(sourceMessageId),
           try store.hasEvent(
               userId: userId,
               patternId: existing.id,
               sourceMessageId: sourceMessageId,
               eventType: eventType
           ) {
            return
        }

        var pattern = existing ?? ShadowLearningPattern(
            id: UUID(),
            userId: userId,
            kind: .responseBehavior,
            label: definition.label,
            summary: definition.summary,
            promptFragment: definition.promptFragment,
            triggerHint: definition.triggerHint,
            confidence: 0.62,
            weight: 0.27,
            status: .observed,
            evidenceMessageIds: [],
            firstSeenAt: now,
            lastSeenAt: now,
            lastReinforcedAt: nil,
            lastCorrectedAt: nil,
            activeFrom: nil,
            activeUntil: nil
        )

        pattern.summary = definition.summary
        pattern.promptFragment = definition.promptFragment
        pattern.triggerHint = definition.triggerHint
        if !pattern.evidenceMessageIds.contains(sourceMessageId) {
            pattern.evidenceMessageIds.append(sourceMessageId)
        }
        pattern.confidence = min(1, max(pattern.confidence, 0.62) + definition.confidenceBoost)
        pattern.weight = min(1, max(pattern.weight, 0.27) + definition.weightBoost)
        pattern.status = Self.feedbackStatus(for: pattern)
        pattern.lastSeenAt = now
        pattern.lastReinforcedAt = now
        pattern.activeFrom = pattern.activeFrom ?? now
        pattern.activeUntil = nil

        try store.upsertPattern(pattern)
        try store.appendEvent(LearningEvent(
            id: UUID(),
            userId: userId,
            patternId: pattern.id,
            sourceMessageId: sourceMessageId,
            eventType: eventType,
            note: definition.eventNote(feedbackNote: note),
            createdAt: now
        ))
    }

    private func clearConflictingFeedbackSignals(
        keeping definition: FeedbackPatternDefinition,
        sourceMessageId: UUID,
        userId: String,
        now: Date
    ) throws {
        for conflictingDefinition in Self.allFeedbackDefinitions where conflictingDefinition.label != definition.label {
            try clearFeedbackSignal(
                definition: conflictingDefinition,
                sourceMessageId: sourceMessageId,
                userId: userId,
                now: now,
                eventNote: "User changed feedback reason; weakened the previous response-behavior signal."
            )
        }
    }

    func clearFeedbackSignal(
        feedback: JudgeFeedback,
        reason: JudgeFeedbackReason? = nil,
        sourceMessageId: UUID,
        userId: String = "alex",
        now: Date = Date()
    ) throws {
        let definition = Self.feedbackDefinition(feedback: feedback, reason: reason)
        try clearFeedbackSignal(
            definition: definition,
            sourceMessageId: sourceMessageId,
            userId: userId,
            now: now,
            eventNote: "User cleared feedback; weakened the derived response-behavior signal."
        )
    }

    private func clearFeedbackSignal(
        definition: FeedbackPatternDefinition,
        sourceMessageId: UUID,
        userId: String,
        now: Date,
        eventNote: String
    ) throws {
        guard var pattern = try store.fetchPattern(
            userId: userId,
            kind: .responseBehavior,
            label: definition.label
        ) else {
            return
        }

        guard pattern.evidenceMessageIds.contains(sourceMessageId) else {
            return
        }

        pattern.evidenceMessageIds.removeAll { $0 == sourceMessageId }
        pattern.confidence = max(0, pattern.confidence - definition.confidenceBoost)
        pattern.weight = max(0, pattern.weight - definition.weightBoost)
        pattern.lastSeenAt = now
        pattern.status = Self.feedbackStatus(for: pattern)
        if pattern.status == .fading {
            pattern.activeUntil = now
        } else {
            pattern.activeUntil = nil
        }

        try store.upsertPattern(pattern)
        try store.appendEvent(LearningEvent(
            id: UUID(),
            userId: userId,
            patternId: pattern.id,
            sourceMessageId: sourceMessageId,
            eventType: .weakened,
            note: eventNote,
            createdAt: now
        ))
    }

    func feedbackSignalLabel(
        feedback: JudgeFeedback,
        reason: JudgeFeedbackReason? = nil
    ) -> String {
        Self.feedbackDefinition(feedback: feedback, reason: reason).label
    }

    @discardableResult
    private func recordObservation(
        _ definition: ShadowPatternDefinition,
        message: Message,
        userId: String,
        now: Date
    ) throws -> Bool {
        let existing = try store.fetchPattern(
            userId: userId,
            kind: definition.kind,
            label: definition.label
        )
        if existing?.evidenceMessageIds.contains(message.id) == true {
            return false
        }

        let base = existing ?? ShadowLearningPattern(
            id: UUID(),
            userId: userId,
            kind: definition.kind,
            label: definition.label,
            summary: definition.summary,
            promptFragment: definition.promptFragment,
            triggerHint: definition.triggerHint,
            confidence: 0.45,
            weight: 0.12,
            status: .observed,
            evidenceMessageIds: [],
            firstSeenAt: now,
            lastSeenAt: now,
            lastReinforcedAt: nil,
            lastCorrectedAt: nil,
            activeFrom: nil,
            activeUntil: nil
        )
        let updated = ShadowPatternLifecycle.afterObservation(
            base,
            evidenceMessageId: message.id,
            at: now
        )

        try store.upsertPattern(updated)
        try store.appendEvent(LearningEvent(
            id: UUID(),
            userId: userId,
            patternId: updated.id,
            sourceMessageId: message.id,
            eventType: existing == nil ? .observed : .reinforced,
            note: definition.eventNote,
            createdAt: now
        ))
        return true
    }

    private func isCorrection(_ text: String, for label: String) -> Bool {
        switch label {
        case "first_principles_decision_frame":
            let negates = text.contains("别用")
                || text.contains("不要")
                || text.contains("not use")
                || text.contains("don't use")
            let namesPattern = lexicon.matchesObservation(label: label, text: text)
            return negates && namesPattern
        default:
            return false
        }
    }

    private static let definitions: [ShadowPatternDefinition] = [
        ShadowPatternDefinition(
            kind: .thinkingMove,
            label: "first_principles_decision_frame",
            summary: "Use first principles for product and architecture judgment.",
            promptFragment: "For product or architecture judgment, start from the base constraint before comparing existing patterns.",
            triggerHint: "product architecture decision first principles",
            eventNote: "Detected first-principles wording."
        ),
        ShadowPatternDefinition(
            kind: .thinkingMove,
            label: "inversion_before_recommendation",
            summary: "Use inversion before recommending a path.",
            promptFragment: "Before recommending, name the worst version of the decision and avoid it.",
            triggerHint: "decision recommendation inversion worst version",
            eventNote: "Detected inversion wording."
        ),
        ShadowPatternDefinition(
            kind: .thinkingMove,
            label: "pain_test_for_product_scope",
            summary: "Use the pain test before adding product scope.",
            promptFragment: "For product scope, ask whether absence would genuinely hurt before expanding the feature.",
            triggerHint: "product scope feature pain test",
            eventNote: "Detected pain-test wording."
        ),
        ShadowPatternDefinition(
            kind: .responseBehavior,
            label: "concrete_over_generic",
            summary: "Prefer concrete references over generic guidance.",
            promptFragment: "Prefer concrete tradeoffs, files, decisions, and examples over generic encouragement.",
            triggerHint: "concrete specific generic advice",
            eventNote: "Detected concrete-over-generic feedback."
        ),
        ShadowPatternDefinition(
            kind: .responseBehavior,
            label: "direct_pushback_when_wrong",
            summary: "Push back plainly when the user's framing is wrong.",
            promptFragment: "If the framing is wrong, say so plainly and name the missing distinction.",
            triggerHint: "push back disagree direct wrong framing",
            eventNote: "Detected direct-pushback preference."
        ),
        ShadowPatternDefinition(
            kind: .responseBehavior,
            label: "organize_before_judging",
            summary: "Organize messy thinking before giving judgment.",
            promptFragment: "When the user's thought is tangled, first organize the pieces, then give judgment.",
            triggerHint: "organize messy thought clarify before judgment",
            eventNote: "Detected organize-before-judging preference."
        )
    ]

    private static func feedbackDefinition(
        feedback: JudgeFeedback,
        reason: JudgeFeedbackReason?
    ) -> FeedbackPatternDefinition {
        if feedback == .up {
            return FeedbackPatternDefinition(
                label: "feedback_reinforce_useful_directness",
                summary: "Preserve the concrete and useful response behavior Alex marked helpful.",
                promptFragment: "Preserve the concrete, direct, and proportionate answer style Alex marked useful.",
                triggerHint: "useful concrete direct answer plan decision feedback",
                baseNote: "User marked a reply useful.",
                confidenceBoost: 0.07,
                weightBoost: 0.06
            )
        }

        switch reason {
        case .wrongMemory:
            return FeedbackPatternDefinition(
                label: "feedback_memory_precision",
                summary: "Use memory only when it directly fits the current message.",
                promptFragment: "Use memory only when it directly fits the current message; if the fit is uncertain, avoid citing or challenging from it.",
                triggerHint: "memory recall cite evidence contradiction",
                baseNote: "User marked memory use as wrong.",
                confidenceBoost: 0.09,
                weightBoost: 0.07
            )
        case .wrongTiming:
            return FeedbackPatternDefinition(
                label: "feedback_challenge_timing",
                summary: "Check timing before challenging Alex.",
                promptFragment: "Before challenging, check timing: if Alex is still opening up, support first and keep the challenge optional.",
                triggerHint: "challenge timing decision pushback tension",
                baseNote: "User marked the response timing as wrong.",
                confidenceBoost: 0.09,
                weightBoost: 0.07
            )
        case .tooForceful:
            return FeedbackPatternDefinition(
                label: "feedback_proportionate_pushback",
                summary: "Keep pushback proportionate when Alex marks a reply too forceful.",
                promptFragment: "Keep pushback proportionate: name tension plainly without sharpness, and give one usable next step.",
                triggerHint: "pushback challenge tension decision forceful",
                baseNote: "User marked the response as too forceful.",
                confidenceBoost: 0.09,
                weightBoost: 0.07
            )
        case .tooRepetitive:
            return FeedbackPatternDefinition(
                label: "feedback_avoid_repetitive_challenge",
                summary: "Avoid repeating the same challenge pattern.",
                promptFragment: "Avoid repeating the same challenge pattern; add new leverage or stay quiet.",
                triggerHint: "challenge repeat repetitive tension pushback",
                baseNote: "User marked the response as too repetitive.",
                confidenceBoost: 0.09,
                weightBoost: 0.07
            )
        case .notUseful, nil:
            return FeedbackPatternDefinition(
                label: "feedback_high_leverage_answer",
                summary: "Make answers concrete when Alex marks a reply not useful.",
                promptFragment: "Skip decorative analysis; answer with concrete leverage tied to Alex's current ask.",
                triggerHint: "useful concrete answer plan decision feedback",
                baseNote: "User marked the response as not useful.",
                confidenceBoost: 0.08,
                weightBoost: 0.06
            )
        }
    }

    private static var allFeedbackDefinitions: [FeedbackPatternDefinition] {
        var definitions = [
            feedbackDefinition(feedback: .up, reason: nil),
            feedbackDefinition(feedback: .down, reason: nil)
        ]
        definitions.append(contentsOf: JudgeFeedbackReason.allCases.map {
            feedbackDefinition(feedback: .down, reason: $0)
        })
        return definitions
    }

    private static func feedbackStatus(for pattern: ShadowLearningPattern) -> ShadowPatternStatus {
        guard !pattern.evidenceMessageIds.isEmpty else {
            return .fading
        }

        let qualifiesStrong = pattern.evidenceMessageIds.count >= 3
            && pattern.confidence >= 0.82
            && pattern.weight >= 0.55
        return qualifiesStrong ? .strong : .soft
    }
}

private struct ShadowPatternDefinition {
    let kind: ShadowPatternKind
    let label: String
    let summary: String
    let promptFragment: String
    let triggerHint: String
    let eventNote: String
}

private struct FeedbackPatternDefinition {
    let label: String
    let summary: String
    let promptFragment: String
    let triggerHint: String
    let baseNote: String
    let confidenceBoost: Double
    let weightBoost: Double

    func eventNote(feedbackNote: String?) -> String {
        guard let note = feedbackNote?.nonEmpty else {
            return baseNote
        }
        return "\(baseNote) Note: \(note)"
    }
}
