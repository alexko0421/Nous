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
}
