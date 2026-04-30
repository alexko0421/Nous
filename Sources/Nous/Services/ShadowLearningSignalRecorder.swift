import Foundation

final class ShadowLearningSignalRecorder {
    private let store: any ShadowLearningStoring

    init(store: any ShadowLearningStoring) {
        self.store = store
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
        for definition in Self.definitions where definition.matches(text) {
            if let maxSignals, recordedCount >= maxSignals {
                break
            }
            let didRecord = try recordObservation(definition, message: message, userId: userId, now: now)
            if didRecord {
                recordedCount += 1
            }
        }
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
            let namesPattern = text.contains("第一性原理")
                || text.contains("first principle")
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
            keywords: ["first principles", "first-principles", "第一性原理", "底层", "本质", "从根上"],
            eventNote: "Detected first-principles wording."
        ),
        ShadowPatternDefinition(
            kind: .thinkingMove,
            label: "inversion_before_recommendation",
            summary: "Use inversion before recommending a path.",
            promptFragment: "Before recommending, name the worst version of the decision and avoid it.",
            triggerHint: "decision recommendation inversion worst version",
            keywords: ["反过来", "inversion", "worst version", "最坏"],
            eventNote: "Detected inversion wording."
        ),
        ShadowPatternDefinition(
            kind: .thinkingMove,
            label: "pain_test_for_product_scope",
            summary: "Use the pain test before adding product scope.",
            promptFragment: "For product scope, ask whether absence would genuinely hurt before expanding the feature.",
            triggerHint: "product scope feature pain test",
            keywords: ["会痛", "痛不痛", "pain test", "absence"],
            eventNote: "Detected pain-test wording."
        ),
        ShadowPatternDefinition(
            kind: .responseBehavior,
            label: "concrete_over_generic",
            summary: "Prefer concrete references over generic guidance.",
            promptFragment: "Prefer concrete tradeoffs, files, decisions, and examples over generic encouragement.",
            triggerHint: "concrete specific generic advice",
            keywords: ["generic", "太泛", "具体", "concrete"],
            eventNote: "Detected concrete-over-generic feedback."
        ),
        ShadowPatternDefinition(
            kind: .responseBehavior,
            label: "direct_pushback_when_wrong",
            summary: "Push back plainly when the user's framing is wrong.",
            promptFragment: "If the framing is wrong, say so plainly and name the missing distinction.",
            triggerHint: "push back disagree direct wrong framing",
            keywords: ["push back", "直接说", "不要顺着我"],
            eventNote: "Detected direct-pushback preference."
        ),
        ShadowPatternDefinition(
            kind: .responseBehavior,
            label: "organize_before_judging",
            summary: "Organize messy thinking before giving judgment.",
            promptFragment: "When the user's thought is tangled, first organize the pieces, then give judgment.",
            triggerHint: "organize messy thought clarify before judgment",
            keywords: ["我说不清", "帮我整理", "organize", "梳理"],
            eventNote: "Detected organize-before-judging preference."
        )
    ]
}

private struct ShadowPatternDefinition {
    let kind: ShadowPatternKind
    let label: String
    let summary: String
    let promptFragment: String
    let triggerHint: String
    let keywords: [String]
    let eventNote: String

    func matches(_ lowercasedText: String) -> Bool {
        keywords.contains { lowercasedText.contains($0.lowercased()) }
    }
}
