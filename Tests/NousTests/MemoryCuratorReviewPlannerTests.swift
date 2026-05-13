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

    func testAtomPlanFlagsActiveExpiredAtomWithoutMutatingIt() {
        let now = Date(timeIntervalSince1970: 20_000)
        let expired = memoryAtom(
            type: .task,
            statement: "Compare launch checklist options after class.",
            confidence: 0.8,
            updatedAt: now.addingTimeInterval(-3_600),
            validUntil: now.addingTimeInterval(-60)
        )
        let planner = MemoryCuratorReviewPlanner(now: { now })

        let plan = planner.plan(atoms: [expired])

        XCTAssertEqual(plan.items.map(\.atom.id), [expired.id])
        XCTAssertEqual(plan.items.first?.issue, .expiredStillActive)
        XCTAssertEqual(plan.items.first?.recommendedAction, .archiveOrRefresh)
        XCTAssertEqual(expired.status, .active)
    }

    func testAtomPlanFlagsMissingSourceEvidenceBeforeLowConfidence() {
        let now = Date(timeIntervalSince1970: 20_000)
        let unsourced = memoryAtom(
            type: .preference,
            statement: "Alex prefers memory answers with source evidence.",
            confidence: 0.42,
            updatedAt: now
        )
        let planner = MemoryCuratorReviewPlanner(now: { now })

        let plan = planner.plan(atoms: [unsourced])

        XCTAssertEqual(plan.items.first?.issue, .missingSourceEvidence)
        XCTAssertEqual(plan.items.first?.recommendedAction, .findEvidenceOrQuarantine)
    }

    func testAtomPlanFlagsPossibleDuplicatesWithinSameScopeAndType() {
        let now = Date(timeIntervalSince1970: 20_000)
        let conversation = UUID()
        let first = memoryAtom(
            type: .decision,
            statement: "Alex decided not to add write tools in phase one.",
            scope: .conversation,
            scopeRefId: conversation,
            normalizedKey: "decision|alex decided not to add write tools in phase one",
            updatedAt: now.addingTimeInterval(-20)
        )
        let duplicate = memoryAtom(
            type: .decision,
            statement: "Alex decided not to add write tools in phase 1.",
            scope: .conversation,
            scopeRefId: conversation,
            normalizedKey: "decision|alex decided not to add write tools in phase 1",
            updatedAt: now.addingTimeInterval(-10)
        )
        let differentType = memoryAtom(
            type: .belief,
            statement: "Alex decided not to add write tools in phase 1.",
            scope: .conversation,
            scopeRefId: conversation,
            updatedAt: now
        )
        let planner = MemoryCuratorReviewPlanner(now: { now })

        let plan = planner.plan(atoms: [first, duplicate, differentType])

        XCTAssertEqual(plan.items.map(\.atom.id), [duplicate.id])
        XCTAssertEqual(plan.items.first?.issue, .possibleDuplicate)
        XCTAssertEqual(plan.items.first?.relatedAtomIds, [first.id])
        XCTAssertEqual(plan.items.first?.recommendedAction, .mergeOrArchiveDuplicate)
    }

    func testAtomPlanFlagsStaleDurableAtomAfterInteractionWindow() {
        let now = Date(timeIntervalSince1970: 90 * 24 * 60 * 60)
        let source = UUID()
        let stale = memoryAtom(
            type: .rule,
            statement: "Memory claims should cite source evidence.",
            confidence: 0.82,
            sourceNodeId: source,
            updatedAt: now.addingTimeInterval(-70 * 24 * 60 * 60),
            lastSeenAt: now.addingTimeInterval(-60 * 24 * 60 * 60)
        )
        let recentlySeen = memoryAtom(
            type: .rule,
            statement: "Pending memory must not affect active recall.",
            confidence: 0.82,
            sourceNodeId: source,
            updatedAt: now.addingTimeInterval(-70 * 24 * 60 * 60),
            lastSeenAt: now.addingTimeInterval(-5 * 24 * 60 * 60)
        )
        let pending = memoryAtom(
            type: .rule,
            statement: "Pending atoms are ignored by curator maintenance.",
            status: .pending,
            confidence: 0.2,
            updatedAt: now.addingTimeInterval(-80 * 24 * 60 * 60)
        )
        let planner = MemoryCuratorReviewPlanner(now: { now })

        let plan = planner.plan(atoms: [stale, recentlySeen, pending])

        XCTAssertEqual(plan.items.map(\.atom.id), [stale.id])
        XCTAssertEqual(plan.items.first?.issue, .staleConfirmation)
        XCTAssertEqual(plan.items.first?.recommendedAction, .askForConfirmation)
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

    private func memoryAtom(
        type: MemoryAtomType,
        statement: String,
        scope: MemoryScope = .global,
        scopeRefId: UUID? = nil,
        status: MemoryStatus = .active,
        normalizedKey: String? = nil,
        confidence: Double = 0.8,
        sourceNodeId: UUID? = nil,
        updatedAt: Date,
        lastSeenAt: Date? = nil,
        validUntil: Date? = nil
    ) -> MemoryAtom {
        MemoryAtom(
            type: type,
            statement: statement,
            normalizedKey: normalizedKey,
            scope: scope,
            scopeRefId: scopeRefId,
            status: status,
            confidence: confidence,
            eventTime: updatedAt,
            validUntil: validUntil,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            lastSeenAt: lastSeenAt,
            sourceNodeId: sourceNodeId
        )
    }
}
