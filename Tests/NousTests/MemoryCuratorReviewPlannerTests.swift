import XCTest
@testable import Nous

final class MemoryCuratorReviewPlannerTests: XCTestCase {
    func testFlagsActiveExpiredTemporaryMemoryWithoutMutatingIt() {
        let now = Date(timeIntervalSince1970: 10_000)
        let expired = memoryEntry(
            kind: .temporaryContext,
            stability: .temporary,
            content: "- compare shoe options after class",
            updatedAt: now.addingTimeInterval(-3_600),
            expiresAt: now.addingTimeInterval(-60)
        )
        let planner = MemoryCuratorReviewPlanner(now: { now })

        let plan = planner.plan(entries: [expired])

        XCTAssertEqual(plan.items.map(\.entry.id), [expired.id])
        XCTAssertEqual(plan.items.first?.issue, .expiredStillActive)
        XCTAssertEqual(plan.items.first?.recommendedAction, .archiveOrRefresh)
        XCTAssertEqual(expired.status, .active)
    }

    func testFlagsOldDurableMemoryThatHasNotBeenConfirmedRecently() {
        let now = Date(timeIntervalSince1970: 90 * 24 * 60 * 60)
        let source = UUID()
        let oldPreference = memoryEntry(
            kind: .preference,
            stability: .stable,
            content: "- Alex prefers concise implementation plans.",
            sourceNodeIds: [source],
            updatedAt: now.addingTimeInterval(-80 * 24 * 60 * 60),
            lastConfirmedAt: now.addingTimeInterval(-75 * 24 * 60 * 60)
        )
        let recentPreference = memoryEntry(
            kind: .preference,
            stability: .stable,
            content: "- Alex prefers focused verification.",
            sourceNodeIds: [source],
            updatedAt: now.addingTimeInterval(-10 * 24 * 60 * 60),
            lastConfirmedAt: now.addingTimeInterval(-10 * 24 * 60 * 60)
        )
        let planner = MemoryCuratorReviewPlanner(now: { now })

        let plan = planner.plan(entries: [oldPreference, recentPreference])

        XCTAssertEqual(plan.items.map(\.entry.id), [oldPreference.id])
        XCTAssertEqual(plan.items.first?.issue, .staleConfirmation)
        XCTAssertEqual(plan.items.first?.recommendedAction, .askForConfirmation)
    }

    func testFlagsMissingSourceEvidenceBeforeLowConfidence() {
        let now = Date(timeIntervalSince1970: 10_000)
        let unsourced = memoryEntry(
            scope: .global,
            kind: .identity,
            content: "- Alex is a solo founder.",
            confidence: 0.42,
            updatedAt: now
        )
        let planner = MemoryCuratorReviewPlanner(now: { now })

        let plan = planner.plan(entries: [unsourced])

        XCTAssertEqual(plan.items.first?.issue, .missingSourceEvidence)
        XCTAssertEqual(plan.items.first?.recommendedAction, .findEvidenceOrQuarantine)
    }

    func testFlagsPossibleDuplicatesWithinSameScopeAndKind() {
        let now = Date(timeIntervalSince1970: 10_000)
        let source = UUID()
        let first = memoryEntry(
            kind: .decision,
            content: "- Alex decided not to add write tools in phase one.",
            sourceNodeIds: [source],
            updatedAt: now.addingTimeInterval(-20)
        )
        let duplicate = memoryEntry(
            kind: .decision,
            content: "Alex decided not to add write tools in phase 1",
            sourceNodeIds: [source],
            updatedAt: now.addingTimeInterval(-10)
        )
        let differentScope = memoryEntry(
            scope: .project,
            kind: .decision,
            content: "Alex decided not to add write tools in phase 1",
            sourceNodeIds: [source],
            updatedAt: now
        )
        let planner = MemoryCuratorReviewPlanner(now: { now })

        let plan = planner.plan(entries: [first, duplicate, differentScope])

        XCTAssertEqual(plan.items.map(\.entry.id), [duplicate.id])
        XCTAssertEqual(plan.items.first?.issue, .possibleDuplicate)
        XCTAssertEqual(plan.items.first?.relatedEntryIds, [first.id])
        XCTAssertEqual(plan.items.first?.recommendedAction, .mergeOrArchiveDuplicate)
    }

    private func memoryEntry(
        scope: MemoryScope = .global,
        scopeRefId: UUID? = nil,
        kind: MemoryKind,
        stability: MemoryStability = .stable,
        status: MemoryStatus = .active,
        content: String,
        confidence: Double = 0.8,
        sourceNodeIds: [UUID] = [],
        updatedAt: Date,
        lastConfirmedAt: Date? = nil,
        expiresAt: Date? = nil
    ) -> MemoryEntry {
        MemoryEntry(
            scope: scope,
            scopeRefId: scopeRefId,
            kind: kind,
            stability: stability,
            status: status,
            content: content,
            confidence: confidence,
            sourceNodeIds: sourceNodeIds,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            lastConfirmedAt: lastConfirmedAt,
            expiresAt: expiresAt
        )
    }
}
