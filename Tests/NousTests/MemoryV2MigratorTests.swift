import XCTest
@testable import Nous

final class MemoryV2MigratorTests: XCTestCase {

    var store: NodeStore!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    // MARK: - Parser

    func testParseKeepsAllowedHeadingsOnly() {
        let raw = """
        ## Identity
        - Alex builds Nous

        ## Constraints
        - macOS only

        ## Preferences
        - Cantonese replies

        ## Relationships
        - works with no one full-time

        ## Ongoing Threads
        - ship the memory refactor

        ## Open Questions
        - whether to embed memory
        """

        let parsed = MemoryV2Migrator.parseGlobalContent(from: raw)

        XCTAssertTrue(parsed.contains("## Identity"))
        XCTAssertTrue(parsed.contains("Alex builds Nous"))
        XCTAssertTrue(parsed.contains("## Constraints"))
        XCTAssertTrue(parsed.contains("macOS only"))
        XCTAssertTrue(parsed.contains("## Preferences"))
        XCTAssertTrue(parsed.contains("## Relationships"))

        XCTAssertFalse(parsed.contains("Ongoing Threads"),
                       "Ongoing Threads must be discarded (cannot attribute to scope)")
        XCTAssertFalse(parsed.contains("ship the memory refactor"))
        XCTAssertFalse(parsed.contains("Open Questions"))
        XCTAssertFalse(parsed.contains("whether to embed memory"))
    }

    func testParseEmptyBlobReturnsEmpty() {
        XCTAssertEqual(MemoryV2Migrator.parseGlobalContent(from: ""), "")
    }

    func testParseMalformedMarkdownStillSafe() {
        // No ## headings at all — parser should return empty, not crash.
        let raw = "just a paragraph with no structure"
        XCTAssertEqual(MemoryV2Migrator.parseGlobalContent(from: raw), "")
    }

    // MARK: - T1: double-run idempotency

    /// Writing regression test for plan §4 / §9 T1:
    /// second call to runIfNeeded must be a no-op — no re-parse, no user_memory
    /// resurrected, no global_memory overwrite.
    func testMigrationDoubleRunIsIdempotent() throws {
        let db = store.rawDatabase

        // Simulate pre-v2.1 state: create old user_memory, seed a summary.
        try db.exec("""
            CREATE TABLE IF NOT EXISTS user_memory (
                id        INTEGER PRIMARY KEY CHECK (id = 1),
                summary   TEXT NOT NULL DEFAULT '',
                updatedAt REAL NOT NULL
            );
        """)
        let seed = "## Identity\n- Alex\n\n## Ongoing Threads\n- old thread"
        let seedStmt = try db.prepare("""
            INSERT OR REPLACE INTO user_memory (id, summary, updatedAt) VALUES (1, ?, ?);
        """)
        try seedStmt.bind(seed, at: 1)
        try seedStmt.bind(Date().timeIntervalSince1970, at: 2)
        try seedStmt.step()

        // --- First run ---
        try MemoryV2Migrator.runIfNeeded(db: db)

        let afterFirst = try store.fetchGlobalMemory()
        XCTAssertNotNil(afterFirst)
        XCTAssertTrue(afterFirst!.content.contains("## Identity"))
        XCTAssertTrue(afterFirst!.content.contains("Alex"))
        XCTAssertFalse(afterFirst!.content.contains("Ongoing Threads"),
                       "Ongoing Threads should have been dropped on migration")
        let firstRunTimestamp = afterFirst!.updatedAt
        let firstRunContent = afterFirst!.content

        // user_memory table should be dropped
        let existsStmt = try db.prepare("""
            SELECT name FROM sqlite_master WHERE type='table' AND name='user_memory';
        """)
        XCTAssertFalse(try existsStmt.step(), "user_memory must be dropped after migration")

        // schema_meta should be stamped
        let versionStmt = try db.prepare("""
            SELECT value FROM schema_meta WHERE key='memory_version';
        """)
        XCTAssertTrue(try versionStmt.step())
        XCTAssertEqual(versionStmt.text(at: 0), "2")

        // --- Second run ---
        try MemoryV2Migrator.runIfNeeded(db: db)

        let afterSecond = try store.fetchGlobalMemory()
        XCTAssertEqual(afterSecond?.content, firstRunContent,
                       "Second run must not re-parse or mutate global_memory content")
        XCTAssertEqual(afterSecond?.updatedAt, firstRunTimestamp,
                       "Second run must not touch global_memory updatedAt")
    }

    func testMigrationOnFreshInstallStampsVersionOnly() throws {
        let db = store.rawDatabase

        // No user_memory table exists on fresh install.
        try MemoryV2Migrator.runIfNeeded(db: db)

        // schema_meta should be stamped
        let versionStmt = try db.prepare("""
            SELECT value FROM schema_meta WHERE key='memory_version';
        """)
        XCTAssertTrue(try versionStmt.step())
        XCTAssertEqual(versionStmt.text(at: 0), "2")

        // global_memory should have no row (nothing to migrate)
        XCTAssertNil(try store.fetchGlobalMemory())
    }
}
