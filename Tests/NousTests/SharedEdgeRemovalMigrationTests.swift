import XCTest
@testable import Nous

final class SharedEdgeRemovalMigrationTests: XCTestCase {
    func test_migrationDeletesSharedRows_andIsIdempotent() throws {
        let store = try NodeStore.inMemoryForTesting()

        let srcId = UUID()
        let tgtId = UUID()
        try store.insertNodeForTest(id: srcId)
        try store.insertNodeForTest(id: tgtId)

        try store.executeRawForTest("""
            INSERT INTO edges (id, sourceId, targetId, strength, type)
            VALUES ('\(UUID().uuidString)', '\(srcId.uuidString)', '\(tgtId.uuidString)', 0.3, 'shared');
        """)
        XCTAssertEqual(try store.countRowsForTest(table: "edges"), 1)

        try store.runSharedEdgeRemovalMigrationForTest()
        XCTAssertEqual(try store.countRowsForTest(table: "edges"), 0)

        // Idempotent: rerun is no-op
        try store.runSharedEdgeRemovalMigrationForTest()
        XCTAssertEqual(try store.countRowsForTest(table: "edges"), 0)
    }

    func test_migrationCreatesEvidenceIndex() throws {
        let store = try NodeStore.inMemoryForTesting()
        try store.runSharedEdgeRemovalMigrationForTest()

        let exists = try store.indexExistsForTest(name: "idx_reflection_evidence_message")
        XCTAssertTrue(exists, "Migration should create idx_reflection_evidence_message")
    }
}
