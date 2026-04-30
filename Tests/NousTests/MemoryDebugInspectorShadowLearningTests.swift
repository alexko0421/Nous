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

    private func pattern(
        label: String,
        status: ShadowPatternStatus,
        weight: Double,
        confidence: Double,
        now: Date
    ) -> ShadowLearningPattern {
        ShadowLearningPattern(
            id: UUID(),
            userId: "alex",
            kind: .thinkingMove,
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
