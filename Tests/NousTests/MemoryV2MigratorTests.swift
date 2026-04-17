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

    // MARK: - T1b: fault-injection rollback

    /// P1 fix from post-commit /plan-eng-review: T1 proves the happy path is
    /// idempotent but never exercises the ROLLBACK branch. If the migration
    /// throws mid-way (partial migrate, then boom before schema_meta is
    /// stamped), the BEGIN/COMMIT transaction MUST undo the copy-and-drop so
    /// Alex isn't left with a half-migrated DB. This test forces a throw
    /// immediately after `migrateFromUserMemory` runs inside the transaction
    /// and verifies:
    ///  - `user_memory` table still exists (DROP TABLE was rolled back)
    ///  - `user_memory.summary` is the original seed (row untouched)
    ///  - `global_memory` has no row (INSERT was rolled back)
    ///  - `schema_meta.memory_version` is absent (stamp never ran)
    ///  - A subsequent run with no fault completes cleanly — the DB is a
    ///    valid pre-migration state, not a corrupted half-state.
    func testMigrationRollbackOnFaultRestoresPreMigrationState() throws {
        let db = store.rawDatabase

        try db.exec("""
            CREATE TABLE IF NOT EXISTS user_memory (
                id        INTEGER PRIMARY KEY CHECK (id = 1),
                summary   TEXT NOT NULL DEFAULT '',
                updatedAt REAL NOT NULL
            );
        """)
        let seed = "## Identity\n- Alex\n\n## Constraints\n- macOS only"
        let seedTimestamp = 1_700_000_000.0
        let seedStmt = try db.prepare("""
            INSERT OR REPLACE INTO user_memory (id, summary, updatedAt) VALUES (1, ?, ?);
        """)
        try seedStmt.bind(seed, at: 1)
        try seedStmt.bind(seedTimestamp, at: 2)
        try seedStmt.step()

        struct InjectedFault: Error {}

        XCTAssertThrowsError(
            try MemoryV2Migrator.runIfNeeded(
                db: db,
                faultInjectAfterMigrate: { throw InjectedFault() }
            )
        ) { error in
            XCTAssertTrue(error is InjectedFault, "wrapper must propagate the fault")
        }

        // Scope each prepared statement into a `do` block so the underlying
        // sqlite3_stmt is finalised (via Statement.deinit) before the next
        // query runs. Otherwise an open read cursor holds a lock on the DB
        // and the retry-migration at the bottom fails with "table is locked".

        // user_memory table must still exist — DROP TABLE was rolled back.
        do {
            let stmt = try db.prepare("""
                SELECT name FROM sqlite_master WHERE type='table' AND name='user_memory';
            """)
            XCTAssertTrue(
                try stmt.step(),
                "user_memory must survive rollback — otherwise retry has nothing to migrate"
            )
        }

        // user_memory row content must be unchanged.
        do {
            let stmt = try db.prepare("SELECT summary, updatedAt FROM user_memory WHERE id = 1;")
            XCTAssertTrue(try stmt.step())
            XCTAssertEqual(stmt.text(at: 0), seed, "user_memory.summary mutated despite rollback")
            XCTAssertEqual(stmt.double(at: 1), seedTimestamp, "user_memory.updatedAt mutated despite rollback")
        }

        // global_memory must have no row — INSERT was rolled back.
        XCTAssertNil(
            try store.fetchGlobalMemory(),
            "global_memory row was committed despite fault — transaction leaked"
        )

        // schema_meta must NOT be stamped — write happens after fault point.
        do {
            let stmt = try db.prepare("SELECT value FROM schema_meta WHERE key='memory_version';")
            XCTAssertFalse(
                try stmt.step(),
                "schema_meta.memory_version was stamped despite rollback — retry would silently skip"
            )
        }

        // The DB should be a valid pre-migration state, so a clean retry works.
        try MemoryV2Migrator.runIfNeeded(db: db)
        let finalMemory = try store.fetchGlobalMemory()
        XCTAssertNotNil(finalMemory, "retry after rollback should successfully migrate")
        XCTAssertTrue(finalMemory!.content.contains("## Identity"))
        XCTAssertTrue(finalMemory!.content.contains("## Constraints"))

        do {
            let stmt = try db.prepare("""
                SELECT name FROM sqlite_master WHERE type='table' AND name='user_memory';
            """)
            XCTAssertFalse(try stmt.step(), "user_memory should be dropped after successful retry")
        }
    }

    /// Codex #5: destructive DROP TABLE guard. If user_memory.summary has real
    /// content but parseGlobalContent returns empty (e.g. a future release added
    /// headings we don't yet recognise), the migration MUST abort and leave the
    /// old table intact so Alex can recover. Without this guard the DROP fires
    /// and the data is unrecoverable.
    func testMigrationAbortsWhenRawHasContentButParseReturnsEmpty() throws {
        let db = store.rawDatabase

        try db.exec("""
            CREATE TABLE IF NOT EXISTS user_memory (
                id        INTEGER PRIMARY KEY CHECK (id = 1),
                summary   TEXT NOT NULL DEFAULT '',
                updatedAt REAL NOT NULL
            );
        """)
        // Real content but NO ## headings → parseGlobalContent returns empty.
        let unrecognised = "Alex prefers Cantonese. Runs macOS. No SSN right now."
        let seedTimestamp = 1_700_000_000.0
        let seedStmt = try db.prepare("""
            INSERT OR REPLACE INTO user_memory (id, summary, updatedAt) VALUES (1, ?, ?);
        """)
        try seedStmt.bind(unrecognised, at: 1)
        try seedStmt.bind(seedTimestamp, at: 2)
        try seedStmt.step()

        XCTAssertThrowsError(try MemoryV2Migrator.runIfNeeded(db: db)) { error in
            guard case MemoryV2Migrator.MigrationError.unrecognisedUserMemoryContent = error else {
                XCTFail("expected unrecognisedUserMemoryContent, got \(error)")
                return
            }
        }

        // user_memory table must still exist — DROP was rolled back.
        do {
            let stmt = try db.prepare("""
                SELECT name FROM sqlite_master WHERE type='table' AND name='user_memory';
            """)
            XCTAssertTrue(try stmt.step(), "user_memory must survive the abort")
        }

        // Row content must be untouched.
        do {
            let stmt = try db.prepare("SELECT summary FROM user_memory WHERE id = 1;")
            XCTAssertTrue(try stmt.step())
            XCTAssertEqual(stmt.text(at: 0), unrecognised,
                           "user_memory.summary mutated despite abort")
        }

        // global_memory must have no row and schema_meta must NOT be stamped.
        XCTAssertNil(try store.fetchGlobalMemory())
        do {
            let stmt = try db.prepare("SELECT value FROM schema_meta WHERE key='memory_version';")
            XCTAssertFalse(try stmt.step(),
                           "memory_version stamped despite abort — retry would silently skip")
        }
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
