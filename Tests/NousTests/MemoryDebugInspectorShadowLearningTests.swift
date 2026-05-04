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
        XCTAssertEqual(rows.first?.confidence, "88%")
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

    func testMemoryFactRowsExposeScopeSourceConfidenceAndSortByTrustRisk() {
        let projectId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let threadId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let sourceId = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let now = Date(timeIntervalSince1970: 30_000)
        let activeFact = MemoryFactEntry(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            scope: .conversation,
            scopeRefId: threadId,
            kind: .boundary,
            content: "Do not store private throwaway details.",
            confidence: 0.91,
            status: .active,
            stability: .stable,
            sourceNodeIds: [sourceId],
            createdAt: now,
            updatedAt: now
        )
        let conflictedFact = MemoryFactEntry(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            scope: .project,
            scopeRefId: projectId,
            kind: .decision,
            content: "Old project direction.",
            confidence: 0.99,
            status: .conflicted,
            stability: .temporary,
            sourceNodeIds: [],
            createdAt: now.addingTimeInterval(-10),
            updatedAt: now.addingTimeInterval(10)
        )

        let rows = MemoryFactDebugFormatting.rows(
            from: [conflictedFact, activeFact],
            nodeTitles: [threadId: "Arc 3 Thread", sourceId: "Opt-out Source"],
            projectTitles: [projectId: "QA Project"]
        )

        XCTAssertEqual(rows.map(\.id), [activeFact.id, conflictedFact.id])
        XCTAssertEqual(rows.first?.kind, "Boundary")
        XCTAssertEqual(rows.first?.status, "Active")
        XCTAssertEqual(rows.first?.stability, "Stable")
        XCTAssertEqual(rows.first?.confidence, "91%")
        XCTAssertEqual(rows.first?.scope, "Thread · Arc 3 Thread")
        XCTAssertEqual(rows.first?.source, "Opt-out Source")
        XCTAssertEqual(rows.last?.scope, "Project · QA Project")
        XCTAssertEqual(rows.last?.source, "No linked source")
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
