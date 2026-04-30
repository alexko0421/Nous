import XCTest
@testable import Nous

final class MemoryDebugInspectorShadowLearningTests: XCTestCase {
    func testShadowPatternRowsSortByStatusAndWeight() {
        let now = Date(timeIntervalSince1970: 20_000)
        let rows = ShadowPatternDebugFormatting.rows(from: [
            pattern(label: "retired", status: .retired, weight: 0.99, confidence: 0.44, now: now),
            pattern(label: "soft_low", status: .soft, weight: 0.20, confidence: 0.66, now: now),
            pattern(label: "strong_high", status: .strong, weight: 0.90, confidence: 0.88, now: now)
        ])

        XCTAssertEqual(rows.map(\.label), ["strong_high", "soft_low", "retired"])
        XCTAssertEqual(rows.first?.status, "strong")
        XCTAssertEqual(rows.first?.weight, "0.90")
        XCTAssertEqual(rows.first?.confidence, "0.88")
        XCTAssertEqual(rows.first?.evidenceCount, "2")
        XCTAssertEqual(rows.first?.summary, "Summary for strong_high")
    }

    func testShadowPatternRowsKeepStableIdsWhenLabelsRepeat() {
        let now = Date(timeIntervalSince1970: 20_000)
        let thinkingId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let behaviorId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let rows = ShadowPatternDebugFormatting.rows(from: [
            pattern(
                id: thinkingId,
                label: "shared_label",
                kind: .thinkingMove,
                status: .strong,
                weight: 0.90,
                confidence: 0.88,
                now: now
            ),
            pattern(
                id: behaviorId,
                label: "shared_label",
                kind: .responseBehavior,
                status: .strong,
                weight: 0.80,
                confidence: 0.77,
                now: now
            )
        ])

        XCTAssertEqual(rows.map(\.id), [thinkingId, behaviorId])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertEqual(rows.map(\.label), ["shared_label", "shared_label"])
    }

    private func pattern(
        id: UUID = UUID(),
        label: String,
        kind: ShadowPatternKind = .thinkingMove,
        status: ShadowPatternStatus,
        weight: Double,
        confidence: Double,
        now: Date
    ) -> ShadowLearningPattern {
        ShadowLearningPattern(
            id: id,
            userId: "alex",
            kind: kind,
            label: label,
            summary: "Summary for \(label)",
            promptFragment: "Prompt fragment for \(label)",
            triggerHint: "trigger \(label)",
            confidence: confidence,
            weight: weight,
            status: status,
            evidenceMessageIds: [UUID(), UUID()],
            firstSeenAt: now,
            lastSeenAt: now,
            lastReinforcedAt: now,
            lastCorrectedAt: nil,
            activeFrom: now,
            activeUntil: nil
        )
    }
}
