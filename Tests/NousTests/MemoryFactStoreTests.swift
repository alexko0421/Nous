import XCTest
@testable import Nous

final class MemoryFactStoreTests: XCTestCase {

    var store: NodeStore!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    func testMemoryKindJSONRoundTripsNewCases() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let decisionData = try encoder.encode(MemoryKind.decision)
        let boundaryData = try encoder.encode(MemoryKind.boundary)
        let legacyData = try encoder.encode(MemoryKind.thread)

        XCTAssertEqual(String(data: decisionData, encoding: .utf8), "\"decision\"")
        XCTAssertEqual(String(data: boundaryData, encoding: .utf8), "\"boundary\"")
        XCTAssertEqual(try decoder.decode(MemoryKind.self, from: decisionData), .decision)
        XCTAssertEqual(try decoder.decode(MemoryKind.self, from: boundaryData), .boundary)
        XCTAssertEqual(try decoder.decode(MemoryKind.self, from: legacyData), .thread,
                       "existing rows must still decode after adding new kinds")
    }

    func testInsertAndFetchMemoryFactEntriesRoundTrips() throws {
        let projectId = UUID()
        let createdAt = Date(timeIntervalSince1970: 100)
        let updatedAt = Date(timeIntervalSince1970: 200)

        let fact = MemoryFactEntry(
            scope: .project,
            scopeRefId: projectId,
            kind: .decision,
            content: "Do not compete on price.",
            confidence: 0.91,
            status: .active,
            stability: .stable,
            sourceNodeIds: [UUID(), UUID()],
            createdAt: createdAt,
            updatedAt: updatedAt
        )

        try store.insertMemoryFactEntry(fact)

        let fetched = try store.fetchMemoryFactEntries()
        XCTAssertEqual(fetched, [fact])
    }

    func testUpdateMemoryFactEntryPersistsMutations() throws {
        let id = UUID()
        let original = MemoryFactEntry(
            id: id,
            scope: .conversation,
            scopeRefId: UUID(),
            kind: .boundary,
            content: "Do not auto-commit.",
            confidence: 0.75,
            status: .active,
            stability: .temporary,
            sourceNodeIds: [UUID()],
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        try store.insertMemoryFactEntry(original)

        var updated = original
        updated.content = "Do not auto-commit code without approval."
        updated.confidence = 0.95
        updated.status = .conflicted
        updated.sourceNodeIds.append(UUID())
        updated.updatedAt = Date(timeIntervalSince1970: 20)

        try store.updateMemoryFactEntry(updated)

        let fetched = try store.fetchMemoryFactEntries()
        XCTAssertEqual(fetched, [updated])
    }

    func testFetchAndDeleteMemoryFactEntryById() throws {
        let kept = MemoryFactEntry(
            scope: .global,
            kind: .constraint,
            content: "Keep this fact.",
            status: .active,
            stability: .stable,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let removed = MemoryFactEntry(
            scope: .conversation,
            scopeRefId: UUID(),
            kind: .boundary,
            content: "Remove this fact.",
            status: .active,
            stability: .temporary,
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        try store.insertMemoryFactEntry(kept)
        try store.insertMemoryFactEntry(removed)

        XCTAssertEqual(try store.fetchMemoryFactEntry(id: removed.id), removed)
        try store.deleteMemoryFactEntry(id: removed.id)

        XCTAssertNil(try store.fetchMemoryFactEntry(id: removed.id))
        XCTAssertEqual(try store.fetchMemoryFactEntries(), [kept])
    }

    func testFetchActiveMemoryFactEntriesFiltersByScopeRefAndKinds() throws {
        let projectId = UUID()
        let otherProjectId = UUID()
        let globalDecision = MemoryFactEntry(
            scope: .global,
            scopeRefId: nil,
            kind: .decision,
            content: "Global decision",
            status: .active,
            stability: .stable,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let matchingDecision = MemoryFactEntry(
            scope: .project,
            scopeRefId: projectId,
            kind: .decision,
            content: "Matching project decision",
            status: .active,
            stability: .stable,
            createdAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let matchingConstraint = MemoryFactEntry(
            scope: .project,
            scopeRefId: projectId,
            kind: .constraint,
            content: "Matching project constraint",
            status: .active,
            stability: .temporary,
            createdAt: Date(timeIntervalSince1970: 3),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let filteredByStatus = MemoryFactEntry(
            scope: .project,
            scopeRefId: projectId,
            kind: .boundary,
            content: "Archived boundary",
            status: .archived,
            stability: .stable,
            createdAt: Date(timeIntervalSince1970: 4),
            updatedAt: Date(timeIntervalSince1970: 40)
        )
        let filteredByScopeRef = MemoryFactEntry(
            scope: .project,
            scopeRefId: otherProjectId,
            kind: .decision,
            content: "Other project decision",
            status: .active,
            stability: .stable,
            createdAt: Date(timeIntervalSince1970: 5),
            updatedAt: Date(timeIntervalSince1970: 50)
        )

        try store.insertMemoryFactEntry(globalDecision)
        try store.insertMemoryFactEntry(matchingDecision)
        try store.insertMemoryFactEntry(matchingConstraint)
        try store.insertMemoryFactEntry(filteredByStatus)
        try store.insertMemoryFactEntry(filteredByScopeRef)

        let projectFacts = try store.fetchActiveMemoryFactEntries(
            scope: .project,
            scopeRefId: projectId,
            kinds: [.decision, .constraint]
        )
        XCTAssertEqual(projectFacts, [matchingDecision, matchingConstraint],
                       "active facts should be filtered by scope/ref/kind and sorted newest-first")

        let globalFacts = try store.fetchActiveMemoryFactEntries(
            scope: .global,
            scopeRefId: nil,
            kinds: [.decision]
        )
        XCTAssertEqual(globalFacts, [globalDecision])
    }

    func testFetchMemoryFactEntriesSkipsUnknownKindsFromOlderOrFutureRows() throws {
        let valid = MemoryFactEntry(
            scope: .project,
            scopeRefId: UUID(),
            kind: .decision,
            content: "Valid fact",
            status: .active,
            stability: .stable,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        try store.insertMemoryFactEntry(valid)

        let db = store.rawDatabase
        let stmt = try db.prepare("""
            INSERT INTO memory_fact_entries
              (id, scope, scopeRefId, kind, content, confidence, status, stability,
               sourceNodeIds, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        try stmt.bind(UUID().uuidString, at: 1)
        try stmt.bind(MemoryScope.project.rawValue, at: 2)
        try stmt.bind(UUID().uuidString, at: 3)
        try stmt.bind("future_kind", at: 4)
        try stmt.bind("Unknown future fact", at: 5)
        try stmt.bind(0.4, at: 6)
        try stmt.bind(MemoryStatus.active.rawValue, at: 7)
        try stmt.bind(MemoryStability.temporary.rawValue, at: 8)
        try stmt.bind("[]", at: 9)
        try stmt.bind(Date(timeIntervalSince1970: 20).timeIntervalSince1970, at: 10)
        try stmt.bind(Date(timeIntervalSince1970: 20).timeIntervalSince1970, at: 11)
        try stmt.step()

        let fetched = try store.fetchMemoryFactEntries()
        XCTAssertEqual(fetched, [valid],
                       "unknown fact kinds should be skipped instead of breaking the whole fetch")
    }
}
