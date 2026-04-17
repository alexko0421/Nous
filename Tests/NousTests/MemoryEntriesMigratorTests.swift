import XCTest
@testable import Nous

final class MemoryEntriesMigratorTests: XCTestCase {

    func testBootstrapsOneEntryPerScopeBlob() throws {
        let store = try NodeStore(path: ":memory:")
        let project = Project(title: "P")
        try store.insertProject(project)
        let node = NousNode(type: .conversation, title: "C", projectId: project.id)
        try store.insertNode(node)

        try store.saveGlobalMemory(GlobalMemory(content: "global blob", updatedAt: Date()))
        try store.saveProjectMemory(ProjectMemory(projectId: project.id, content: "project blob", updatedAt: Date()))
        try store.saveConversationMemory(ConversationMemory(nodeId: node.id, content: "convo blob", updatedAt: Date()))

        try MemoryEntriesMigrator.runIfNeeded(store: store)

        let entries = try store.fetchMemoryEntries()
        XCTAssertEqual(entries.count, 3)

        let global = try store.fetchActiveMemoryEntry(scope: .global, scopeRefId: nil)
        XCTAssertEqual(global?.content, "global blob")
        XCTAssertEqual(global?.kind, .identity)
        XCTAssertEqual(global?.stability, .stable)

        let proj = try store.fetchActiveMemoryEntry(scope: .project, scopeRefId: project.id)
        XCTAssertEqual(proj?.content, "project blob")
        XCTAssertEqual(proj?.stability, .stable)

        let convo = try store.fetchActiveMemoryEntry(scope: .conversation, scopeRefId: node.id)
        XCTAssertEqual(convo?.content, "convo blob")
        XCTAssertEqual(convo?.stability, .temporary)
        XCTAssertEqual(convo?.sourceNodeIds, [node.id])
    }

    func testIsIdempotent() throws {
        let store = try NodeStore(path: ":memory:")
        try store.saveGlobalMemory(GlobalMemory(content: "g", updatedAt: Date()))

        try MemoryEntriesMigrator.runIfNeeded(store: store)
        let afterFirst = try store.fetchMemoryEntries().count
        XCTAssertEqual(afterFirst, 1)

        try MemoryEntriesMigrator.runIfNeeded(store: store)
        let afterSecond = try store.fetchMemoryEntries().count
        XCTAssertEqual(afterSecond, 1, "second run must not duplicate entries")
    }

    func testEmptyDatabaseStampsVersion() throws {
        let store = try NodeStore(path: ":memory:")

        try MemoryEntriesMigrator.runIfNeeded(store: store)
        XCTAssertTrue(try store.fetchMemoryEntries().isEmpty)

        // Second call must also be a no-op, proving the version row was stamped
        // even though no blobs existed — no infinite retry on every boot.
        try store.saveGlobalMemory(GlobalMemory(content: "added-after-first-migration", updatedAt: Date()))
        try MemoryEntriesMigrator.runIfNeeded(store: store)
        XCTAssertTrue(
            try store.fetchMemoryEntries().isEmpty,
            "migrator must not re-bootstrap after version is stamped"
        )
    }

    func testSkipsBlankScopeBlobs() throws {
        let store = try NodeStore(path: ":memory:")
        try store.saveGlobalMemory(GlobalMemory(content: "   \n\t ", updatedAt: Date()))

        try MemoryEntriesMigrator.runIfNeeded(store: store)
        XCTAssertTrue(try store.fetchMemoryEntries().isEmpty)
    }
}
