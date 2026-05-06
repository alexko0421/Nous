import XCTest
@testable import Nous

final class MemoryCuratorReviewDebugFormattingTests: XCTestCase {
    func testReviewEntriesStartWithCuratorPlanItemsAndAppendStatusRows() {
        let now = Date(timeIntervalSince1970: 10_000)
        let clean = memoryEntry(content: "- Active clean memory.", updatedAt: now)
        let stale = memoryEntry(content: "- Active stale memory.", updatedAt: now.addingTimeInterval(-1))
        let conflicted = memoryEntry(
            status: .conflicted,
            content: "- Conflicted memory.",
            updatedAt: now.addingTimeInterval(-2)
        )
        let expired = memoryEntry(
            status: .expired,
            content: "- Expired memory.",
            updatedAt: now.addingTimeInterval(-3)
        )
        let plan = MemoryCuratorReviewPlan(
            generatedAt: now,
            items: [
                MemoryCuratorReviewItem(
                    entry: stale,
                    issue: .staleConfirmation,
                    recommendedAction: .askForConfirmation,
                    relatedEntryIds: [],
                    reason: "stable memory has not been confirmed recently"
                )
            ]
        )

        let entries = MemoryCuratorReviewDebugFormatting.entries(
            from: [clean, conflicted, stale, expired],
            plan: plan
        )

        XCTAssertEqual(entries.map(\.id), [stale.id, conflicted.id, expired.id])
    }

    func testReviewEntriesDoNotDuplicateStatusRowsAlreadyInPlan() {
        let now = Date(timeIntervalSince1970: 10_000)
        let conflicted = memoryEntry(
            status: .conflicted,
            content: "- Conflicted memory.",
            updatedAt: now
        )
        let plan = MemoryCuratorReviewPlan(
            generatedAt: now,
            items: [
                MemoryCuratorReviewItem(
                    entry: conflicted,
                    issue: .lowConfidence,
                    recommendedAction: .reviewConfidence,
                    relatedEntryIds: [],
                    reason: "confidence is below curator review threshold"
                )
            ]
        )

        let entries = MemoryCuratorReviewDebugFormatting.entries(
            from: [conflicted],
            plan: plan
        )

        XCTAssertEqual(entries.map(\.id), [conflicted.id])
    }

    func testReviewNoteUsesCuratorIssueAndReason() {
        let entry = memoryEntry(content: "- Unsourced memory.", updatedAt: Date(timeIntervalSince1970: 10_000))
        let item = MemoryCuratorReviewItem(
            entry: entry,
            issue: .missingSourceEvidence,
            recommendedAction: .findEvidenceOrQuarantine,
            relatedEntryIds: [],
            reason: "durable memory has no source node evidence"
        )

        let note = MemoryCuratorReviewDebugFormatting.note(for: item)

        XCTAssertEqual(note, "Missing source evidence: durable memory has no source node evidence")
    }

    func testConfirmIsOnlyAllowedForIssuesConfirmationCanResolve() {
        XCTAssertTrue(allowsConfirm(for: .staleConfirmation))
        XCTAssertTrue(allowsConfirm(for: .lowConfidence))
        XCTAssertFalse(allowsConfirm(for: .missingSourceEvidence))
        XCTAssertFalse(allowsConfirm(for: .possibleDuplicate))
        XCTAssertFalse(allowsConfirm(for: .expiredStillActive))
    }

    private func allowsConfirm(for issue: MemoryCuratorReviewIssue) -> Bool {
        let entry = memoryEntry(content: "- Review memory.", updatedAt: Date(timeIntervalSince1970: 10_000))
        let item = MemoryCuratorReviewItem(
            entry: entry,
            issue: issue,
            recommendedAction: .reviewConfidence,
            relatedEntryIds: [],
            reason: "test"
        )
        return MemoryCuratorReviewDebugFormatting.allowsConfirm(for: item)
    }

    private func memoryEntry(
        status: MemoryStatus = .active,
        content: String,
        updatedAt: Date
    ) -> MemoryEntry {
        MemoryEntry(
            scope: .global,
            kind: .preference,
            stability: .stable,
            status: status,
            content: content,
            sourceNodeIds: [UUID()],
            createdAt: updatedAt,
            updatedAt: updatedAt,
            lastConfirmedAt: updatedAt
        )
    }
}
