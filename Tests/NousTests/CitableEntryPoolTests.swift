import XCTest
@testable import Nous

final class CitableEntryPoolTests: XCTestCase {

    var store: NodeStore!
    var service: UserMemoryService!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
        service = UserMemoryService(
            nodeStore: store,
            llmServiceProvider: { nil }
        )
    }

    override func tearDown() {
        service = nil
        store = nil
        super.tearDown()
    }

    func testPoolBridgesNodeHitsToEntries() throws {
        let nodeA = UUID()
        let entry = MemoryEntry(
            scope: .global, kind: .preference, stability: .stable,
            content: "Alex prefers not to compete on price.",
            sourceNodeIds: [nodeA]
        )
        try store.insertMemoryEntry(entry)

        let pool = try service.citableEntryPool(
            projectId: nil,
            conversationId: UUID(),
            nodeHits: [nodeA],
            capacity: 10
        )

        XCTAssertEqual(pool.count, 1)
        XCTAssertEqual(pool.first?.id, entry.id.uuidString)
        XCTAssertEqual(pool.first?.scope, .global)
        XCTAssertTrue(pool.first!.text.contains("price"))
    }

    func testPoolDedupesAcrossHits() throws {
        let nodeA = UUID()
        let nodeB = UUID()
        let entry = MemoryEntry(
            scope: .global, kind: .preference, stability: .stable,
            content: "E", sourceNodeIds: [nodeA, nodeB]
        )
        try store.insertMemoryEntry(entry)

        let pool = try service.citableEntryPool(
            projectId: nil, conversationId: UUID(),
            nodeHits: [nodeA, nodeB], capacity: 10
        )
        XCTAssertEqual(pool.count, 1)
    }

    func testPoolAddsRecencySeedWhenNoNodeHits() throws {
        let globalEntry = MemoryEntry(
            scope: .global, kind: .preference, stability: .stable,
            content: "Recent global", sourceNodeIds: []
        )
        try store.insertMemoryEntry(globalEntry)

        let pool = try service.citableEntryPool(
            projectId: nil, conversationId: UUID(),
            nodeHits: [], capacity: 10
        )
        XCTAssertEqual(pool.map(\.id), [globalEntry.id.uuidString])
    }

    func testPoolRespectsCapacityCap() throws {
        for i in 0..<30 {
            try store.insertMemoryEntry(MemoryEntry(
                scope: .global, kind: .thread, stability: .temporary,
                content: "E\(i)", sourceNodeIds: []
            ))
        }
        let pool = try service.citableEntryPool(
            projectId: nil, conversationId: UUID(),
            nodeHits: [], capacity: 10
        )
        XCTAssertLessThanOrEqual(pool.count, 10)
    }

    func testPoolRespectsScopeForProject() throws {
        let projectId = UUID()
        let otherProjectId = UUID()
        let inProject = MemoryEntry(
            scope: .project, scopeRefId: projectId,
            kind: .thread, stability: .temporary,
            content: "in-project", sourceNodeIds: []
        )
        let otherProject = MemoryEntry(
            scope: .project, scopeRefId: otherProjectId,
            kind: .thread, stability: .temporary,
            content: "other-project", sourceNodeIds: []
        )
        try store.insertMemoryEntry(inProject)
        try store.insertMemoryEntry(otherProject)

        let pool = try service.citableEntryPool(
            projectId: projectId, conversationId: UUID(),
            nodeHits: [], capacity: 10
        )
        XCTAssertTrue(pool.contains { $0.id == inProject.id.uuidString })
        XCTAssertFalse(pool.contains { $0.id == otherProject.id.uuidString })
    }

    func testPoolPrependsHardRecallFactsAndCarriesPromptAnnotation() throws {
        let conversationId = UUID()
        let globalEntry = MemoryEntry(
            scope: .global, kind: .preference, stability: .stable,
            content: "Recent global", sourceNodeIds: []
        )
        try store.insertMemoryEntry(globalEntry)

        let fact = MemoryFactEntry(
            scope: .conversation,
            scopeRefId: conversationId,
            kind: .decision,
            content: "Do not compete on price.",
            confidence: 0.9,
            status: .active,
            stability: .stable,
            sourceNodeIds: [conversationId],
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        let pool = try service.citableEntryPool(
            projectId: nil,
            conversationId: conversationId,
            nodeHits: [],
            hardRecallFacts: [fact],
            contradictionCandidateIds: Set([fact.id.uuidString]),
            capacity: 10
        )

        XCTAssertEqual(pool.first?.id, fact.id.uuidString)
        XCTAssertEqual(pool.first?.kind, .decision)
        XCTAssertEqual(pool.first?.promptAnnotation, "contradiction-candidate")
        XCTAssertTrue(pool.contains { $0.id == globalEntry.id.uuidString },
                      "hard recall should prepend contradiction facts without removing the normal recency seed path")
    }

    // MARK: - R2: weekly reflection claims

    func testPoolAdmitsActiveReflectionWithWeeklyReflectionAnnotation() throws {
        let (_, claim) = try seedReflection(
            projectId: nil,
            claim: "Across four conversations this week, you grounded decisions in environment first.",
            status: .active
        )

        let pool = try service.citableEntryPool(
            projectId: nil,
            conversationId: UUID(),
            nodeHits: [],
            capacity: 10
        )

        let match = try XCTUnwrap(pool.first { $0.id == claim.id.uuidString })
        XCTAssertEqual(match.scope, .selfReflection)
        XCTAssertEqual(match.promptAnnotation, "weekly-reflection")
        XCTAssertTrue(match.text.contains("environment first"))
        XCTAssertNil(match.kind, "reflection claims don't have a MemoryKind")
    }

    func testPoolSkipsOrphanedReflectionClaims() throws {
        let (_, orphaned) = try seedReflection(
            projectId: nil,
            claim: "Dropped trait-style claim.",
            status: .orphaned
        )

        let pool = try service.citableEntryPool(
            projectId: nil,
            conversationId: UUID(),
            nodeHits: [],
            capacity: 10
        )

        XCTAssertFalse(pool.contains { $0.id == orphaned.id.uuidString },
                       "orphaned reflections must NOT enter the retrieval pool")
    }

    func testReflectionSeedCapsHowManyClaimsEnter() throws {
        // Three active claims; cap at 2 → only the 2 most recent land.
        let now = Date()
        let (_, older) = try seedReflection(
            projectId: nil,
            claim: "older claim",
            status: .active,
            createdAt: now.addingTimeInterval(-3 * 86400)
        )
        let (_, middle) = try seedReflection(
            projectId: nil,
            claim: "middle claim",
            status: .active,
            createdAt: now.addingTimeInterval(-2 * 86400)
        )
        let (_, newest) = try seedReflection(
            projectId: nil,
            claim: "newest claim",
            status: .active,
            createdAt: now
        )

        let pool = try service.citableEntryPool(
            projectId: nil,
            conversationId: UUID(),
            nodeHits: [],
            capacity: 10,
            reflectionSeed: 2
        )

        let poolIds = Set(pool.map { $0.id })
        XCTAssertTrue(poolIds.contains(newest.id.uuidString))
        XCTAssertTrue(poolIds.contains(middle.id.uuidString))
        XCTAssertFalse(poolIds.contains(older.id.uuidString),
                       "older claim must be dropped when reflectionSeed=2")
    }

    func testReflectionSeedZeroSkipsReflectionPassEntirely() throws {
        _ = try seedReflection(projectId: nil, claim: "c", status: .active)

        let pool = try service.citableEntryPool(
            projectId: nil,
            conversationId: UUID(),
            nodeHits: [],
            capacity: 10,
            reflectionSeed: 0
        )

        XCTAssertFalse(pool.contains { $0.scope == .selfReflection },
                       "reflectionSeed=0 is the opt-out for the reflection pass")
    }

    func testProjectScopedCallOnlySeesProjectReflections() throws {
        let projectId = UUID()
        let (_, inProject) = try seedReflection(
            projectId: projectId,
            claim: "project-scoped reflection",
            status: .active
        )
        let (_, freeChat) = try seedReflection(
            projectId: nil,
            claim: "free-chat reflection",
            status: .active
        )

        let pool = try service.citableEntryPool(
            projectId: projectId,
            conversationId: UUID(),
            nodeHits: [],
            capacity: 10
        )

        XCTAssertTrue(pool.contains { $0.id == inProject.id.uuidString })
        XCTAssertFalse(pool.contains { $0.id == freeChat.id.uuidString },
                       "free-chat reflections must not leak into a project's pool")
    }

    // MARK: - Helpers

    @discardableResult
    private func seedReflection(
        projectId: UUID?,
        claim claimText: String,
        status: ReflectionClaimStatus,
        createdAt: Date = Date()
    ) throws -> (run: ReflectionRun, claim: ReflectionClaim) {
        if let projectId, try store.fetchProject(id: projectId) == nil {
            try store.insertProject(Project(id: projectId, title: "Test Project"))
        }
        let weekStart = createdAt.addingTimeInterval(-7 * 86400)
        let weekEnd = createdAt
        let run = ReflectionRun(
            projectId: projectId,
            weekStart: weekStart,
            weekEnd: weekEnd,
            ranAt: createdAt,
            status: .success,
            rejectionReason: nil,
            costCents: 0
        )
        let claim = ReflectionClaim(
            runId: run.id,
            claim: claimText,
            confidence: 0.8,
            whyNonObvious: "why",
            status: status,
            createdAt: createdAt
        )
        try store.persistReflectionRun(run, claims: [claim], evidence: [])
        return (run, claim)
    }
}
