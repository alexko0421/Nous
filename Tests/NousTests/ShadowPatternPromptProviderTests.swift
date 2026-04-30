import XCTest
@testable import Nous

final class ShadowPatternPromptProviderTests: XCTestCase {
    func testProviderReturnsTopThreeRelevantPromptFragmentsAndExcludesVoicePattern() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let now = Date(timeIntervalSince1970: 10_000)
        try store.upsertPattern(pattern(
            label: "irrelevant_voice",
            kind: .thinkingMove,
            trigger: "voice transcript microphone",
            fragment: "Use microphone voice transcript habits.",
            weight: 0.95,
            now: now
        ))
        try store.upsertPattern(pattern(
            label: "first_principles_decision_frame",
            kind: .thinkingMove,
            trigger: "product architecture decision",
            fragment: "Start product decisions from base constraints.",
            weight: 0.80,
            now: now
        ))
        try store.upsertPattern(pattern(
            label: "pain_test_for_product_scope",
            kind: .thinkingMove,
            trigger: "product scope feature pain test",
            fragment: "Ask whether absence would genuinely hurt.",
            weight: 0.70,
            now: now
        ))
        try store.upsertPattern(pattern(
            label: "inversion_before_recommendation",
            kind: .thinkingMove,
            trigger: "feature decision worst version",
            fragment: "Name the worst version before recommending.",
            weight: 0.60,
            now: now
        ))
        try store.upsertPattern(pattern(
            label: "concrete_over_generic",
            kind: .responseBehavior,
            trigger: "concrete generic answer",
            fragment: "Prefer concrete tradeoffs over generic encouragement.",
            weight: 0.50,
            now: now
        ))

        let provider = ShadowPatternPromptProvider(store: store)
        let hints = try provider.promptHints(
            userId: "alex",
            currentInput: "Should we build this product feature?",
            activeQuickActionMode: .plan,
            now: now
        )

        XCTAssertEqual(hints.count, 3)
        XCTAssertTrue(hints.contains("Start product decisions from base constraints."))
        XCTAssertTrue(hints.contains("Ask whether absence would genuinely hurt."))
        XCTAssertTrue(hints.contains("Name the worst version before recommending."))
        XCTAssertFalse(hints.joined(separator: "\n").contains("microphone"))
    }

    func testProviderReturnsEmptyWhenNoRelevantHints() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let now = Date(timeIntervalSince1970: 10_000)
        try store.upsertPattern(pattern(
            label: "voice_only",
            kind: .thinkingMove,
            trigger: "voice transcript microphone",
            fragment: "Use microphone voice transcript habits.",
            weight: 0.95,
            now: now
        ))

        let provider = ShadowPatternPromptProvider(store: store)
        let hints = try provider.promptHints(
            userId: "alex",
            currentInput: "hello",
            activeQuickActionMode: nil,
            now: now
        )

        XCTAssertTrue(hints.isEmpty)
    }

    func testProviderDoesNotInjectResponseBehaviorWithoutRelevance() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let now = Date(timeIntervalSince1970: 10_000)
        try store.upsertPattern(pattern(
            label: "concrete_over_generic",
            kind: .responseBehavior,
            trigger: "concrete generic answer",
            fragment: "Prefer concrete tradeoffs over generic encouragement.",
            weight: 0.95,
            now: now
        ))

        let provider = ShadowPatternPromptProvider(store: store)
        let hints = try provider.promptHints(
            userId: "alex",
            currentInput: "Should we build this product feature?",
            activeQuickActionMode: .plan,
            now: now
        )

        XCTAssertTrue(hints.isEmpty)
    }

    private func pattern(
        label: String,
        kind: ShadowPatternKind,
        trigger: String,
        fragment: String,
        weight: Double,
        now: Date
    ) -> ShadowLearningPattern {
        ShadowLearningPattern(
            id: UUID(),
            userId: "alex",
            kind: kind,
            label: label,
            summary: label,
            promptFragment: fragment,
            triggerHint: trigger,
            confidence: 0.86,
            weight: weight,
            status: .strong,
            evidenceMessageIds: [],
            firstSeenAt: now,
            lastSeenAt: now,
            lastReinforcedAt: now,
            lastCorrectedAt: nil,
            activeFrom: now,
            activeUntil: nil
        )
    }
}
