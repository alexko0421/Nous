import XCTest
@testable import Nous

final class MemoryCuratorReviewServiceTests: XCTestCase {
    private var store: NodeStore!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    func testBuildsReviewPlanFromNodeStoreEntries() throws {
        let now = Date(timeIntervalSince1970: 90 * 24 * 60 * 60)
        let source = NousNode(
            type: .conversation,
            title: "Source chat",
            content: "Alex prefers short implementation plans.",
            createdAt: now,
            updatedAt: now
        )
        try store.insertNode(source)
        let stale = MemoryEntry(
            scope: .global,
            kind: .preference,
            stability: .stable,
            content: "- Alex prefers short implementation plans.",
            sourceNodeIds: [source.id],
            createdAt: now.addingTimeInterval(-80 * 24 * 60 * 60),
            updatedAt: now.addingTimeInterval(-80 * 24 * 60 * 60),
            lastConfirmedAt: now.addingTimeInterval(-80 * 24 * 60 * 60)
        )
        try store.insertMemoryEntry(stale)
        let service = MemoryCuratorReviewService(
            nodeStore: store,
            planner: MemoryCuratorReviewPlanner(now: { now })
        )

        let plan = try service.makePlan()

        XCTAssertEqual(plan.generatedAt, now)
        XCTAssertEqual(plan.items.map(\.entry.id), [stale.id])
        XCTAssertEqual(plan.items.first?.issue, .staleConfirmation)
    }

    func testArchivedEntriesStayOutOfReviewPlan() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let activeExpired = MemoryEntry(
            scope: .conversation,
            scopeRefId: UUID(),
            kind: .temporaryContext,
            stability: .temporary,
            content: "- Review active temporary context.",
            createdAt: now.addingTimeInterval(-3_600),
            updatedAt: now.addingTimeInterval(-3_600),
            expiresAt: now.addingTimeInterval(-60)
        )
        let archivedExpired = MemoryEntry(
            scope: .conversation,
            scopeRefId: UUID(),
            kind: .temporaryContext,
            stability: .temporary,
            status: .archived,
            content: "- Old archived temporary context.",
            createdAt: now.addingTimeInterval(-3_600),
            updatedAt: now.addingTimeInterval(-3_600),
            expiresAt: now.addingTimeInterval(-60)
        )
        try store.insertMemoryEntry(activeExpired)
        try store.insertMemoryEntry(archivedExpired)
        let service = MemoryCuratorReviewService(
            nodeStore: store,
            planner: MemoryCuratorReviewPlanner(now: { now })
        )

        let plan = try service.makePlan()

        XCTAssertEqual(plan.items.map(\.entry.id), [activeExpired.id])
        XCTAssertFalse(plan.items.contains { $0.entry.id == archivedExpired.id })
    }

    func testBrokenSourceLinksAreTreatedAsMissingEvidence() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let entry = MemoryEntry(
            scope: .global,
            kind: .decision,
            stability: .stable,
            content: "- Alex chose to keep memory writes evidence-gated.",
            confidence: 0.95,
            sourceNodeIds: [UUID()],
            createdAt: now,
            updatedAt: now,
            lastConfirmedAt: now
        )
        try store.insertMemoryEntry(entry)
        let service = MemoryCuratorReviewService(
            nodeStore: store,
            planner: MemoryCuratorReviewPlanner(now: { now })
        )

        let plan = try service.makePlan()

        XCTAssertEqual(plan.items.map(\.entry.id), [entry.id])
        XCTAssertEqual(plan.items.first?.issue, .missingSourceEvidence)
    }

    func testEmptySourceNodesAreTreatedAsMissingEvidence() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let source = NousNode(
            type: .source,
            title: "Empty source",
            content: "   ",
            createdAt: now,
            updatedAt: now
        )
        try store.insertNode(source)
        let entry = MemoryEntry(
            scope: .global,
            kind: .decision,
            stability: .stable,
            content: "- Alex chose source-backed memory review.",
            confidence: 0.95,
            sourceNodeIds: [source.id],
            createdAt: now,
            updatedAt: now,
            lastConfirmedAt: now
        )
        try store.insertMemoryEntry(entry)
        let service = MemoryCuratorReviewService(
            nodeStore: store,
            planner: MemoryCuratorReviewPlanner(now: { now })
        )

        let plan = try service.makePlan()

        XCTAssertEqual(plan.items.map(\.entry.id), [entry.id])
        XCTAssertEqual(plan.items.first?.issue, .missingSourceEvidence)
    }

    func testSourceChunksCountAsInspectableEvidence() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let source = NousNode(
            type: .source,
            title: "Chunked source",
            content: "",
            createdAt: now,
            updatedAt: now
        )
        try store.insertNode(source)
        try store.replaceSourceChunks([
            SourceChunk(
                sourceNodeId: source.id,
                ordinal: 0,
                text: "Alex chose source-backed memory review.",
                createdAt: now
            )
        ], for: source.id)
        let entry = MemoryEntry(
            scope: .global,
            kind: .decision,
            stability: .stable,
            content: "- Alex chose source-backed memory review.",
            confidence: 0.95,
            sourceNodeIds: [source.id],
            createdAt: now,
            updatedAt: now,
            lastConfirmedAt: now
        )
        try store.insertMemoryEntry(entry)
        let service = MemoryCuratorReviewService(
            nodeStore: store,
            planner: MemoryCuratorReviewPlanner(now: { now })
        )

        let plan = try service.makePlan()

        XCTAssertFalse(plan.items.contains { $0.entry.id == entry.id })
    }
}
