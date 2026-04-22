import Foundation

extension Notification.Name {
    static let nousNodesDidChange = Notification.Name("NousNodesDidChange")
}

// MARK: - NodeStore

final class NodeStore {

    private let db: Database
    /// Serializes multi-statement transactions on the single SQLite connection.
    /// SQLite's connection-level mutex serializes individual calls, but
    /// `BEGIN ... COMMIT` pairs are not atomic as a group: two overlapping
    /// `inTransaction` calls race at `BEGIN` and one fails with "cannot start
    /// a transaction within a transaction". This lock closes that window so
    /// v2.2b dual-writes don't silently drop entries under concurrent refreshes.
    private let transactionLock = NSLock()

    init(path: String) throws {
        db = try Database(path: path)
        try createTables()
    }

    // MARK: - Schema

    private func createTables() throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS projects (
                id        TEXT PRIMARY KEY,
                title     TEXT NOT NULL,
                goal      TEXT NOT NULL DEFAULT '',
                emoji     TEXT NOT NULL DEFAULT '📁',
                createdAt REAL NOT NULL
            );
        """)

        try db.exec("""
            CREATE TABLE IF NOT EXISTS nodes (
                id         TEXT PRIMARY KEY,
                type       TEXT NOT NULL,
                title      TEXT NOT NULL,
                content    TEXT NOT NULL DEFAULT '',
                emoji      TEXT,
                embedding  BLOB,
                projectId  TEXT REFERENCES projects(id) ON DELETE SET NULL,
                isFavorite INTEGER NOT NULL DEFAULT 0,
                createdAt  REAL NOT NULL,
                updatedAt  REAL NOT NULL
            );
        """)

        try ensureColumnExists(
            table: "nodes",
            column: "emoji",
            alterSQL: "ALTER TABLE nodes ADD COLUMN emoji TEXT;"
        )

        try db.exec("""
            CREATE TABLE IF NOT EXISTS messages (
                id               TEXT PRIMARY KEY,
                nodeId           TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
                role             TEXT NOT NULL,
                content          TEXT NOT NULL,
                timestamp        REAL NOT NULL,
                thinking_content TEXT
            );
        """)

        try ensureColumnExists(
            table: "messages",
            column: "thinking_content",
            alterSQL: "ALTER TABLE messages ADD COLUMN thinking_content TEXT;"
        )

        try db.exec("""
            CREATE TABLE IF NOT EXISTS edges (
                id       TEXT PRIMARY KEY,
                sourceId TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
                targetId TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
                strength REAL NOT NULL DEFAULT 0,
                type     TEXT NOT NULL
            );
        """)

        // Schema version tracking. Lives in SQLite so it survives app reinstall
        // and iCloud restore, unlike UserDefaults. See MemoryV2Migrator.
        try db.exec("""
            CREATE TABLE IF NOT EXISTS schema_meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
        """)

        // Three scopes for cross-chat memory (v2.1).
        // Old single `user_memory` table is created only by pre-v2.1 binaries;
        // MemoryV2Migrator copy-and-drops it during the upgrade boot.
        try db.exec("""
            CREATE TABLE IF NOT EXISTS global_memory (
                id        INTEGER PRIMARY KEY CHECK (id = 1),
                content   TEXT NOT NULL DEFAULT '',
                updatedAt REAL NOT NULL
            );
        """)

        try db.exec("""
            CREATE TABLE IF NOT EXISTS project_memory (
                projectId TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
                content   TEXT NOT NULL DEFAULT '',
                updatedAt REAL NOT NULL
            );
        """)

        try db.exec("""
            CREATE TABLE IF NOT EXISTS conversation_memory (
                nodeId    TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                content   TEXT NOT NULL DEFAULT '',
                updatedAt REAL NOT NULL
            );
        """)

        // Per-project counter of conversation refreshes since the last project
        // rollup. Incremented atomically on every refreshConversation inside a
        // project, reset to 0 when refreshProject fires. Replaces the broken
        // "count cm rows with updatedAt > project_memory.updatedAt" heuristic,
        // which always returned 1 for single-active-chat projects because
        // conversation_memory is INSERT OR REPLACE (one row per chat).
        try db.exec("""
            CREATE TABLE IF NOT EXISTS project_refresh_state (
                projectId TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
                counter   INTEGER NOT NULL DEFAULT 0
            );
        """)

        // Canonical structured memory rows. v2.2d reads and writes memory from
        // this table; the older v2.1 blob tables remain only for bootstrap /
        // rollback safety. At most one `active` entry exists per
        // `(scope, scopeRefId)`; older actives are superseded and linked via
        // `supersededBy` on each refresh.
        try db.exec("""
            CREATE TABLE IF NOT EXISTS memory_entries (
                id              TEXT PRIMARY KEY,
                scope           TEXT NOT NULL,
                scopeRefId      TEXT,
                kind            TEXT NOT NULL,
                stability       TEXT NOT NULL,
                status          TEXT NOT NULL,
                content         TEXT NOT NULL,
                confidence      REAL NOT NULL DEFAULT 0.8,
                sourceNodeIds   TEXT NOT NULL DEFAULT '[]',
                createdAt       REAL NOT NULL,
                updatedAt       REAL NOT NULL,
                lastConfirmedAt REAL,
                expiresAt       REAL,
                supersededBy    TEXT
            );
        """)

        // Contradiction-oriented sidecar facts. Unlike `memory_entries`, this
        // table does not participate in the one-active-summary-per-scope
        // invariant; it stores sibling typed facts for retrieval/judging.
        try db.exec("""
            CREATE TABLE IF NOT EXISTS memory_fact_entries (
                id            TEXT PRIMARY KEY,
                scope         TEXT NOT NULL,
                scopeRefId    TEXT,
                kind          TEXT NOT NULL,
                content       TEXT NOT NULL,
                confidence    REAL NOT NULL DEFAULT 0.8,
                status        TEXT NOT NULL,
                stability     TEXT NOT NULL,
                sourceNodeIds TEXT NOT NULL DEFAULT '[]',
                createdAt     REAL NOT NULL,
                updatedAt     REAL NOT NULL
            );
        """)

        // judge_events — append-only per-turn verdict log. Feedback columns patched
        // after the fact. verdict_json kept as a blob so adding fields to
        // JudgeVerdict doesn't require a schema migration.
        try db.exec("""
            CREATE TABLE IF NOT EXISTS judge_events (
                id              TEXT PRIMARY KEY,
                ts              REAL NOT NULL,
                nodeId          TEXT NOT NULL,
                messageId       TEXT,
                chatMode        TEXT NOT NULL,
                provider        TEXT NOT NULL,
                verdictJSON     TEXT NOT NULL,
                fallbackReason  TEXT NOT NULL,
                userFeedback    TEXT,
                feedbackTs      REAL
            );
        """)

        try ensureColumnExists(
            table: "judge_events",
            column: "feedbackReason",
            alterSQL: "ALTER TABLE judge_events ADD COLUMN feedbackReason TEXT;"
        )

        try ensureColumnExists(
            table: "judge_events",
            column: "feedbackNote",
            alterSQL: "ALTER TABLE judge_events ADD COLUMN feedbackNote TEXT;"
        )

        // Indexes
        try db.exec("CREATE INDEX IF NOT EXISTS idx_nodes_projectId  ON nodes(projectId);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_messages_nodeId  ON messages(nodeId);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_edges_sourceId   ON edges(sourceId);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_edges_targetId   ON edges(targetId);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_conversation_memory_updatedAt ON conversation_memory(updatedAt);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_memory_entries_scope_ref_status ON memory_entries(scope, scopeRefId, status);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_memory_fact_entries_scope_ref_status ON memory_fact_entries(scope, scopeRefId, status);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_memory_fact_entries_kind ON memory_fact_entries(kind);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_memory_fact_entries_updatedAt ON memory_fact_entries(updatedAt);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_judge_events_ts ON judge_events(ts);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_judge_events_fallback ON judge_events(fallbackReason);")
    }

    /// Direct access for migrator (transaction control, table-exists probing).
    var rawDatabase: Database { db }

    private func ensureColumnExists(table: String, column: String, alterSQL: String) throws {
        let stmt = try db.prepare("PRAGMA table_info(\(table));")
        while try stmt.step() {
            if stmt.text(at: 1) == column {
                return
            }
        }
        try db.exec(alterSQL)
    }

    private func notifyNodesDidChange() {
        let post = {
            NotificationCenter.default.post(name: .nousNodesDidChange, object: nil)
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    // MARK: - Binary helpers

    private func encodeFloats(_ floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
    }

    private func decodeFloats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    // MARK: - Nodes

    func insertNode(_ node: NousNode) throws {
        let stmt = try db.prepare("""
            INSERT INTO nodes (id, type, title, content, emoji, embedding, projectId, isFavorite, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        try stmt.bind(node.id.uuidString, at: 1)
        try stmt.bind(node.type.rawValue, at: 2)
        try stmt.bind(node.title, at: 3)
        try stmt.bind(node.content, at: 4)
        try stmt.bind(node.emoji, at: 5)
        let embeddingData: Data? = node.embedding.map { encodeFloats($0) }
        try stmt.bind(embeddingData, at: 6)
        try stmt.bind(node.projectId?.uuidString, at: 7)
        try stmt.bind(node.isFavorite ? 1 : 0, at: 8)
        try stmt.bind(node.createdAt.timeIntervalSince1970, at: 9)
        try stmt.bind(node.updatedAt.timeIntervalSince1970, at: 10)
        try stmt.step()
        notifyNodesDidChange()
    }

    func updateNode(_ node: NousNode) throws {
        let stmt = try db.prepare("""
            UPDATE nodes
            SET type=?, title=?, content=?, emoji=?, embedding=?, projectId=?, isFavorite=?, updatedAt=?
            WHERE id=?;
        """)
        try stmt.bind(node.type.rawValue, at: 1)
        try stmt.bind(node.title, at: 2)
        try stmt.bind(node.content, at: 3)
        try stmt.bind(node.emoji, at: 4)
        let embeddingData: Data? = node.embedding.map { encodeFloats($0) }
        try stmt.bind(embeddingData, at: 5)
        try stmt.bind(node.projectId?.uuidString, at: 6)
        try stmt.bind(node.isFavorite ? 1 : 0, at: 7)
        try stmt.bind(node.updatedAt.timeIntervalSince1970, at: 8)
        try stmt.bind(node.id.uuidString, at: 9)
        try stmt.step()
        notifyNodesDidChange()
    }

    func deleteNode(id: UUID) throws {
        try inTransaction {
            try deleteCanonicalMemory(scope: .conversation, scopeRefId: id)
            let stmt = try db.prepare("DELETE FROM nodes WHERE id=?;")
            try stmt.bind(id.uuidString, at: 1)
            try stmt.step()
        }
        notifyNodesDidChange()
    }

    func fetchNode(id: UUID) throws -> NousNode? {
        let stmt = try db.prepare("""
            SELECT id, type, title, content, emoji, embedding, projectId, isFavorite, createdAt, updatedAt
            FROM nodes WHERE id=?;
        """)
        try stmt.bind(id.uuidString, at: 1)
        guard try stmt.step() else { return nil }
        return nodeFrom(stmt)
    }

    func fetchAllNodes() throws -> [NousNode] {
        let stmt = try db.prepare("""
            SELECT id, type, title, content, emoji, embedding, projectId, isFavorite, createdAt, updatedAt
            FROM nodes ORDER BY updatedAt DESC;
        """)
        var results: [NousNode] = []
        while try stmt.step() {
            results.append(nodeFrom(stmt))
        }
        return results
    }

    /// Lightweight title lookup for inspector/debug UIs that should not decode
    /// full node bodies or embedding blobs just to render labels.
    func fetchAllNodeTitles() throws -> [UUID: String] {
        let stmt = try db.prepare("""
            SELECT id, title
            FROM nodes
            ORDER BY updatedAt DESC;
        """)
        var results: [UUID: String] = [:]
        while try stmt.step() {
            guard let rawId = stmt.text(at: 0),
                  let id = UUID(uuidString: rawId) else { continue }
            let title = stmt.text(at: 1) ?? ""
            results[id] = title.isEmpty ? "Untitled" : title
        }
        return results
    }

    func fetchNodes(projectId: UUID) throws -> [NousNode] {
        let stmt = try db.prepare("""
            SELECT id, type, title, content, emoji, embedding, projectId, isFavorite, createdAt, updatedAt
            FROM nodes WHERE projectId=? ORDER BY updatedAt DESC;
        """)
        try stmt.bind(projectId.uuidString, at: 1)
        var results: [NousNode] = []
        while try stmt.step() {
            results.append(nodeFrom(stmt))
        }
        return results
    }

    func fetchFavorites() throws -> [NousNode] {
        let stmt = try db.prepare("""
            SELECT id, type, title, content, emoji, embedding, projectId, isFavorite, createdAt, updatedAt
            FROM nodes WHERE isFavorite=1 ORDER BY updatedAt DESC;
        """)
        var results: [NousNode] = []
        while try stmt.step() {
            results.append(nodeFrom(stmt))
        }
        return results
    }

    func fetchRecents(limit: Int) throws -> [NousNode] {
        let stmt = try db.prepare("""
            SELECT id, type, title, content, emoji, embedding, projectId, isFavorite, createdAt, updatedAt
            FROM nodes ORDER BY updatedAt DESC LIMIT ?;
        """)
        try stmt.bind(limit, at: 1)
        var results: [NousNode] = []
        while try stmt.step() {
            results.append(nodeFrom(stmt))
        }
        return results
    }

    func fetchNodesWithEmbeddings() throws -> [(NousNode, [Float])] {
        let stmt = try db.prepare("""
            SELECT id, type, title, content, emoji, embedding, projectId, isFavorite, createdAt, updatedAt
            FROM nodes WHERE embedding IS NOT NULL ORDER BY updatedAt DESC;
        """)
        var results: [(NousNode, [Float])] = []
        while try stmt.step() {
            let node = nodeFrom(stmt)
            if let embedding = node.embedding {
                results.append((node, embedding))
            }
        }
        return results
    }

    /// Recent evidence-filtered chat memory feed used for cross-window
    /// continuity. Reads from the active conversation `memory_entries` row,
    /// not the frozen v2.1 `conversation_memory` blob and never the raw
    /// transcript (`node.content`). Using raw content leaks "Nous: …" turns
    /// back into the next chat's system prompt, reintroducing the
    /// self-confirmation loop this memory layer exists to avoid.
    func fetchRecentConversationMemories(
        limit: Int,
        excludingId: UUID? = nil
    ) throws -> [(title: String, memory: String)] {
        let sql: String
        if excludingId == nil {
            sql = """
                SELECT n.title, me.content
                FROM nodes n
                JOIN memory_entries me
                  ON me.scope = 'conversation'
                 AND me.scopeRefId = n.id
                 AND me.status = 'active'
                WHERE n.type='conversation' AND TRIM(me.content) != ''
                ORDER BY me.updatedAt DESC
                LIMIT ?;
            """
        } else {
            sql = """
                SELECT n.title, me.content
                FROM nodes n
                JOIN memory_entries me
                  ON me.scope = 'conversation'
                 AND me.scopeRefId = n.id
                 AND me.status = 'active'
                WHERE n.type='conversation' AND n.id != ? AND TRIM(me.content) != ''
                ORDER BY me.updatedAt DESC
                LIMIT ?;
            """
        }

        let stmt = try db.prepare(sql)
        if let excludingId {
            try stmt.bind(excludingId.uuidString, at: 1)
            try stmt.bind(limit, at: 2)
        } else {
            try stmt.bind(limit, at: 1)
        }

        var results: [(title: String, memory: String)] = []
        while try stmt.step() {
            let title = stmt.text(at: 0) ?? ""
            let memory = stmt.text(at: 1) ?? ""
            results.append((title: title, memory: memory))
        }
        return results
    }

    func fetchRecentConversations(limit: Int, excludingId: UUID? = nil) throws -> [NousNode] {
        let sql: String
        if excludingId == nil {
            sql = """
                SELECT id, type, title, content, emoji, embedding, projectId, isFavorite, createdAt, updatedAt
                FROM nodes
                WHERE type='conversation' AND content != ''
                ORDER BY updatedAt DESC
                LIMIT ?;
            """
        } else {
            sql = """
                SELECT id, type, title, content, emoji, embedding, projectId, isFavorite, createdAt, updatedAt
                FROM nodes
                WHERE type='conversation' AND id != ? AND content != ''
                ORDER BY updatedAt DESC
                LIMIT ?;
            """
        }

        let stmt = try db.prepare(sql)
        if let excludingId {
            try stmt.bind(excludingId.uuidString, at: 1)
            try stmt.bind(limit, at: 2)
        } else {
            try stmt.bind(limit, at: 1)
        }

        var results: [NousNode] = []
        while try stmt.step() {
            results.append(nodeFrom(stmt))
        }
        return results
    }

    func inTransaction(_ work: () throws -> Void) throws {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        try db.exec("BEGIN TRANSACTION;")
        do {
            try work()
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    private func nodeFrom(_ stmt: Statement) -> NousNode {
        let id = UUID(uuidString: stmt.text(at: 0) ?? "") ?? UUID()
        let type = NodeType(rawValue: stmt.text(at: 1) ?? "") ?? .note
        let title = stmt.text(at: 2) ?? ""
        let content = stmt.text(at: 3) ?? ""
        let emoji = stmt.text(at: 4)
        let embedding: [Float]? = stmt.blob(at: 5).map { decodeFloats($0) }
        let projectId: UUID? = stmt.text(at: 6).flatMap { UUID(uuidString: $0) }
        let isFavorite = stmt.int(at: 7) != 0
        let createdAt = Date(timeIntervalSince1970: stmt.double(at: 8))
        let updatedAt = Date(timeIntervalSince1970: stmt.double(at: 9))
        return NousNode(id: id, type: type, title: title, content: content,
                        emoji: emoji, embedding: embedding, projectId: projectId,
                        isFavorite: isFavorite, createdAt: createdAt, updatedAt: updatedAt)
    }

    // MARK: - Messages

    func insertMessage(_ message: Message) throws {
        let stmt = try db.prepare("""
            INSERT INTO messages (id, nodeId, role, content, timestamp, thinking_content)
            VALUES (?, ?, ?, ?, ?, ?);
        """)
        try stmt.bind(message.id.uuidString, at: 1)
        try stmt.bind(message.nodeId.uuidString, at: 2)
        try stmt.bind(message.role.rawValue, at: 3)
        try stmt.bind(message.content, at: 4)
        try stmt.bind(message.timestamp.timeIntervalSince1970, at: 5)
        try stmt.bind(message.thinkingContent, at: 6)
        try stmt.step()
        notifyNodesDidChange()
    }

    func fetchMessages(nodeId: UUID) throws -> [Message] {
        let stmt = try db.prepare("""
            SELECT id, nodeId, role, content, timestamp, thinking_content
            FROM messages WHERE nodeId=? ORDER BY timestamp ASC;
        """)
        try stmt.bind(nodeId.uuidString, at: 1)
        var results: [Message] = []
        while try stmt.step() {
            let id = UUID(uuidString: stmt.text(at: 0) ?? "") ?? UUID()
            let nId = UUID(uuidString: stmt.text(at: 1) ?? "") ?? UUID()
            let role = MessageRole(rawValue: stmt.text(at: 2) ?? "") ?? .user
            let content = stmt.text(at: 3) ?? ""
            let timestamp = Date(timeIntervalSince1970: stmt.double(at: 4))
            let thinkingContent = stmt.text(at: 5)
            results.append(Message(
                id: id,
                nodeId: nId,
                role: role,
                content: content,
                timestamp: timestamp,
                thinkingContent: thinkingContent
            ))
        }
        return results
    }

    // MARK: - Memory scopes (v2.1)

    // --- Global ---

    func fetchGlobalMemory() throws -> GlobalMemory? {
        let stmt = try db.prepare("""
            SELECT content, updatedAt FROM global_memory WHERE id = 1;
        """)
        guard try stmt.step() else { return nil }
        let content = stmt.text(at: 0) ?? ""
        let updatedAt = Date(timeIntervalSince1970: stmt.double(at: 1))
        return GlobalMemory(content: content, updatedAt: updatedAt)
    }

    func saveGlobalMemory(_ memory: GlobalMemory) throws {
        let stmt = try db.prepare("""
            INSERT OR REPLACE INTO global_memory (id, content, updatedAt)
            VALUES (1, ?, ?);
        """)
        try stmt.bind(memory.content, at: 1)
        try stmt.bind(memory.updatedAt.timeIntervalSince1970, at: 2)
        try stmt.step()
    }

    // --- Project ---

    func fetchProjectMemory(projectId: UUID) throws -> ProjectMemory? {
        let stmt = try db.prepare("""
            SELECT content, updatedAt FROM project_memory WHERE projectId = ?;
        """)
        try stmt.bind(projectId.uuidString, at: 1)
        guard try stmt.step() else { return nil }
        let content = stmt.text(at: 0) ?? ""
        let updatedAt = Date(timeIntervalSince1970: stmt.double(at: 1))
        return ProjectMemory(projectId: projectId, content: content, updatedAt: updatedAt)
    }

    func saveProjectMemory(_ memory: ProjectMemory) throws {
        let stmt = try db.prepare("""
            INSERT OR REPLACE INTO project_memory (projectId, content, updatedAt)
            VALUES (?, ?, ?);
        """)
        try stmt.bind(memory.projectId.uuidString, at: 1)
        try stmt.bind(memory.content, at: 2)
        try stmt.bind(memory.updatedAt.timeIntervalSince1970, at: 3)
        try stmt.step()
    }

    // --- Conversation ---

    func fetchConversationMemory(nodeId: UUID) throws -> ConversationMemory? {
        let stmt = try db.prepare("""
            SELECT content, updatedAt FROM conversation_memory WHERE nodeId = ?;
        """)
        try stmt.bind(nodeId.uuidString, at: 1)
        guard try stmt.step() else { return nil }
        let content = stmt.text(at: 0) ?? ""
        let updatedAt = Date(timeIntervalSince1970: stmt.double(at: 1))
        return ConversationMemory(nodeId: nodeId, content: content, updatedAt: updatedAt)
    }

    func saveConversationMemory(_ memory: ConversationMemory) throws {
        let stmt = try db.prepare("""
            INSERT OR REPLACE INTO conversation_memory (nodeId, content, updatedAt)
            VALUES (?, ?, ?);
        """)
        try stmt.bind(memory.nodeId.uuidString, at: 1)
        try stmt.bind(memory.content, at: 2)
        try stmt.bind(memory.updatedAt.timeIntervalSince1970, at: 3)
        try stmt.step()
    }

    /// Atomically increments the per-project refresh counter by 1, creating the
    /// row if absent. Called inside the transaction that persists a
    /// conversation_memory update, so the count is an event count (refreshes
    /// performed) not a row count (distinct chats refreshed). See Codex
    /// adversarial review post-be089e5 finding #6 for why row-counting was
    /// wrong: a single hot chat refreshed 5x is 1 row, never hits threshold.
    func incrementProjectRefreshCounter(projectId: UUID) throws {
        let stmt = try db.prepare("""
            INSERT INTO project_refresh_state (projectId, counter) VALUES (?, 1)
            ON CONFLICT(projectId) DO UPDATE SET counter = counter + 1;
        """)
        try stmt.bind(projectId.uuidString, at: 1)
        try stmt.step()
    }

    /// Reads the current refresh counter for this project (0 if no row exists).
    func readProjectRefreshCounter(projectId: UUID) throws -> Int {
        let stmt = try db.prepare("""
            SELECT counter FROM project_refresh_state WHERE projectId = ?;
        """)
        try stmt.bind(projectId.uuidString, at: 1)
        guard try stmt.step() else { return 0 }
        return stmt.int(at: 0)
    }

    /// Resets the refresh counter to 0. Called at the end of refreshProject so
    /// the next threshold-3 window starts fresh. Atomic w.r.t. concurrent
    /// incrementProjectRefreshCounter calls — a refresh landing mid-rollup
    /// counts toward the next window, which is the desired semantic.
    func resetProjectRefreshCounter(projectId: UUID) throws {
        let stmt = try db.prepare("""
            INSERT INTO project_refresh_state (projectId, counter) VALUES (?, 0)
            ON CONFLICT(projectId) DO UPDATE SET counter = 0;
        """)
        try stmt.bind(projectId.uuidString, at: 1)
        try stmt.step()
    }

    // MARK: - Memory Entries (v2.2b)

    /// Fetch every project's memory blob. Used by MemoryEntriesMigrator to
    /// bootstrap entries from existing v2.1 scope tables without mutating them.
    func fetchAllProjectMemories() throws -> [ProjectMemory] {
        let stmt = try db.prepare("""
            SELECT projectId, content, updatedAt FROM project_memory;
        """)
        var results: [ProjectMemory] = []
        while try stmt.step() {
            guard let projectId = (stmt.text(at: 0)).flatMap({ UUID(uuidString: $0) }) else { continue }
            let content = stmt.text(at: 1) ?? ""
            let updatedAt = Date(timeIntervalSince1970: stmt.double(at: 2))
            results.append(ProjectMemory(projectId: projectId, content: content, updatedAt: updatedAt))
        }
        return results
    }

    /// Fetch every conversation's memory blob. Used by MemoryEntriesMigrator.
    func fetchAllConversationMemories() throws -> [ConversationMemory] {
        let stmt = try db.prepare("""
            SELECT nodeId, content, updatedAt FROM conversation_memory;
        """)
        var results: [ConversationMemory] = []
        while try stmt.step() {
            guard let nodeId = (stmt.text(at: 0)).flatMap({ UUID(uuidString: $0) }) else { continue }
            let content = stmt.text(at: 1) ?? ""
            let updatedAt = Date(timeIntervalSince1970: stmt.double(at: 2))
            results.append(ConversationMemory(nodeId: nodeId, content: content, updatedAt: updatedAt))
        }
        return results
    }

    func insertMemoryEntry(_ entry: MemoryEntry) throws {
        let stmt = try db.prepare("""
            INSERT INTO memory_entries
              (id, scope, scopeRefId, kind, stability, status, content, confidence,
               sourceNodeIds, createdAt, updatedAt, lastConfirmedAt, expiresAt, supersededBy)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        try stmt.bind(entry.id.uuidString, at: 1)
        try stmt.bind(entry.scope.rawValue, at: 2)
        try stmt.bind(entry.scopeRefId?.uuidString, at: 3)
        try stmt.bind(entry.kind.rawValue, at: 4)
        try stmt.bind(entry.stability.rawValue, at: 5)
        try stmt.bind(entry.status.rawValue, at: 6)
        try stmt.bind(entry.content, at: 7)
        try stmt.bind(entry.confidence, at: 8)
        try stmt.bind(encodeSourceNodeIds(entry.sourceNodeIds), at: 9)
        try stmt.bind(entry.createdAt.timeIntervalSince1970, at: 10)
        try stmt.bind(entry.updatedAt.timeIntervalSince1970, at: 11)
        try stmt.bind(entry.lastConfirmedAt?.timeIntervalSince1970, at: 12)
        try stmt.bind(entry.expiresAt?.timeIntervalSince1970, at: 13)
        try stmt.bind(entry.supersededBy?.uuidString, at: 14)
        try stmt.step()
    }

    func updateMemoryEntry(_ entry: MemoryEntry) throws {
        let stmt = try db.prepare("""
            UPDATE memory_entries
            SET scope = ?, scopeRefId = ?, kind = ?, stability = ?, status = ?, content = ?,
                confidence = ?, sourceNodeIds = ?, updatedAt = ?, lastConfirmedAt = ?,
                expiresAt = ?, supersededBy = ?
            WHERE id = ?;
        """)
        try stmt.bind(entry.scope.rawValue, at: 1)
        try stmt.bind(entry.scopeRefId?.uuidString, at: 2)
        try stmt.bind(entry.kind.rawValue, at: 3)
        try stmt.bind(entry.stability.rawValue, at: 4)
        try stmt.bind(entry.status.rawValue, at: 5)
        try stmt.bind(entry.content, at: 6)
        try stmt.bind(entry.confidence, at: 7)
        try stmt.bind(encodeSourceNodeIds(entry.sourceNodeIds), at: 8)
        try stmt.bind(entry.updatedAt.timeIntervalSince1970, at: 9)
        try stmt.bind(entry.lastConfirmedAt?.timeIntervalSince1970, at: 10)
        try stmt.bind(entry.expiresAt?.timeIntervalSince1970, at: 11)
        try stmt.bind(entry.supersededBy?.uuidString, at: 12)
        try stmt.bind(entry.id.uuidString, at: 13)
        try stmt.step()
    }

    func insertMemoryFactEntry(_ entry: MemoryFactEntry) throws {
        let stmt = try db.prepare("""
            INSERT INTO memory_fact_entries
              (id, scope, scopeRefId, kind, content, confidence, status, stability,
               sourceNodeIds, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        try stmt.bind(entry.id.uuidString, at: 1)
        try stmt.bind(entry.scope.rawValue, at: 2)
        try stmt.bind(entry.scopeRefId?.uuidString, at: 3)
        try stmt.bind(entry.kind.rawValue, at: 4)
        try stmt.bind(entry.content, at: 5)
        try stmt.bind(entry.confidence, at: 6)
        try stmt.bind(entry.status.rawValue, at: 7)
        try stmt.bind(entry.stability.rawValue, at: 8)
        try stmt.bind(encodeSourceNodeIds(entry.sourceNodeIds), at: 9)
        try stmt.bind(entry.createdAt.timeIntervalSince1970, at: 10)
        try stmt.bind(entry.updatedAt.timeIntervalSince1970, at: 11)
        try stmt.step()
    }

    func updateMemoryFactEntry(_ entry: MemoryFactEntry) throws {
        let stmt = try db.prepare("""
            UPDATE memory_fact_entries
            SET scope = ?, scopeRefId = ?, kind = ?, content = ?, confidence = ?,
                status = ?, stability = ?, sourceNodeIds = ?, updatedAt = ?
            WHERE id = ?;
        """)
        try stmt.bind(entry.scope.rawValue, at: 1)
        try stmt.bind(entry.scopeRefId?.uuidString, at: 2)
        try stmt.bind(entry.kind.rawValue, at: 3)
        try stmt.bind(entry.content, at: 4)
        try stmt.bind(entry.confidence, at: 5)
        try stmt.bind(entry.status.rawValue, at: 6)
        try stmt.bind(entry.stability.rawValue, at: 7)
        try stmt.bind(encodeSourceNodeIds(entry.sourceNodeIds), at: 8)
        try stmt.bind(entry.updatedAt.timeIntervalSince1970, at: 9)
        try stmt.bind(entry.id.uuidString, at: 10)
        try stmt.step()
    }

    func fetchMemoryEntry(id: UUID) throws -> MemoryEntry? {
        let stmt = try db.prepare("""
            SELECT id, scope, scopeRefId, kind, stability, status, content, confidence,
                   sourceNodeIds, createdAt, updatedAt, lastConfirmedAt, expiresAt, supersededBy
            FROM memory_entries
            WHERE id = ?
            LIMIT 1;
        """)
        try stmt.bind(id.uuidString, at: 1)
        guard try stmt.step() else { return nil }
        return memoryEntryFrom(stmt)
    }

    func deleteMemoryEntry(id: UUID) throws {
        let stmt = try db.prepare("""
            DELETE FROM memory_entries
            WHERE id = ?;
        """)
        try stmt.bind(id.uuidString, at: 1)
        try stmt.step()
    }

    /// Returns every entry (any status). Useful for debug/inspector and tests.
    func fetchMemoryEntries() throws -> [MemoryEntry] {
        let stmt = try db.prepare("""
            SELECT id, scope, scopeRefId, kind, stability, status, content, confidence,
                   sourceNodeIds, createdAt, updatedAt, lastConfirmedAt, expiresAt, supersededBy
            FROM memory_entries
            ORDER BY updatedAt DESC;
        """)
        var results: [MemoryEntry] = []
        while try stmt.step() {
            if let entry = memoryEntryFrom(stmt) { results.append(entry) }
        }
        return results
    }

    /// Reverse lookup: all memory_entries whose `sourceNodeIds` JSON array contains the given node id.
    /// Backs the Citable Pool's node-hit bridging path. Defaults to active-only rows (v2.2 invariant).
    func fetchMemoryEntries(withSourceNodeId nodeId: UUID, activeOnly: Bool = true) throws -> [MemoryEntry] {
        let activeClause = activeOnly ? "AND status = 'active'" : ""
        let stmt = try db.prepare("""
            SELECT id, scope, scopeRefId, kind, stability, status, content, confidence,
                   sourceNodeIds, createdAt, updatedAt, lastConfirmedAt, expiresAt, supersededBy
            FROM memory_entries
            WHERE EXISTS (
                SELECT 1 FROM json_each(memory_entries.sourceNodeIds)
                WHERE json_each.value = ?
            ) \(activeClause)
            ORDER BY updatedAt DESC;
        """)
        try stmt.bind(nodeId.uuidString, at: 1)
        var out: [MemoryEntry] = []
        while try stmt.step() {
            if let entry = memoryEntryFrom(stmt) { out.append(entry) }
        }
        return out
    }

    /// Returns the single `active` entry for a given (scope, scopeRefId), if any.
    /// v2.2b invariant: at most one active entry per scope+ref at any moment.
    func fetchActiveMemoryEntry(scope: MemoryScope, scopeRefId: UUID?) throws -> MemoryEntry? {
        let sql: String
        let stmt: Statement
        if let scopeRefId {
            sql = """
                SELECT id, scope, scopeRefId, kind, stability, status, content, confidence,
                       sourceNodeIds, createdAt, updatedAt, lastConfirmedAt, expiresAt, supersededBy
                FROM memory_entries
                WHERE scope = ? AND scopeRefId = ? AND status = 'active'
                ORDER BY updatedAt DESC
                LIMIT 1;
            """
            stmt = try db.prepare(sql)
            try stmt.bind(scope.rawValue, at: 1)
            try stmt.bind(scopeRefId.uuidString, at: 2)
        } else {
            sql = """
                SELECT id, scope, scopeRefId, kind, stability, status, content, confidence,
                       sourceNodeIds, createdAt, updatedAt, lastConfirmedAt, expiresAt, supersededBy
                FROM memory_entries
                WHERE scope = ? AND scopeRefId IS NULL AND status = 'active'
                ORDER BY updatedAt DESC
                LIMIT 1;
            """
            stmt = try db.prepare(sql)
            try stmt.bind(scope.rawValue, at: 1)
        }
        guard try stmt.step() else { return nil }
        return memoryEntryFrom(stmt)
    }

    /// Returns every sidecar fact entry (any status). Useful for retrieval
    /// tests and future inspector work. Invalid rows are skipped.
    func fetchMemoryFactEntries() throws -> [MemoryFactEntry] {
        let stmt = try db.prepare("""
            SELECT id, scope, scopeRefId, kind, content, confidence, status, stability,
                   sourceNodeIds, createdAt, updatedAt
            FROM memory_fact_entries
            ORDER BY updatedAt DESC;
        """)
        var results: [MemoryFactEntry] = []
        while try stmt.step() {
            if let entry = memoryFactEntryFrom(stmt) { results.append(entry) }
        }
        return results
    }

    func fetchActiveMemoryFactEntries(
        scope: MemoryScope,
        scopeRefId: UUID?,
        kinds: [MemoryKind]
    ) throws -> [MemoryFactEntry] {
        let kindFilter = if kinds.isEmpty {
            ""
        } else {
            " AND kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ", ")))"
        }

        let sql: String
        let stmt: Statement
        if let scopeRefId {
            sql = """
                SELECT id, scope, scopeRefId, kind, content, confidence, status, stability,
                       sourceNodeIds, createdAt, updatedAt
                FROM memory_fact_entries
                WHERE scope = ? AND scopeRefId = ? AND status = 'active'\(kindFilter)
                ORDER BY updatedAt DESC;
            """
            stmt = try db.prepare(sql)
            try stmt.bind(scope.rawValue, at: 1)
            try stmt.bind(scopeRefId.uuidString, at: 2)
            for (offset, kind) in kinds.enumerated() {
                try stmt.bind(kind.rawValue, at: Int32(3 + offset))
            }
        } else {
            sql = """
                SELECT id, scope, scopeRefId, kind, content, confidence, status, stability,
                       sourceNodeIds, createdAt, updatedAt
                FROM memory_fact_entries
                WHERE scope = ? AND scopeRefId IS NULL AND status = 'active'\(kindFilter)
                ORDER BY updatedAt DESC;
            """
            stmt = try db.prepare(sql)
            try stmt.bind(scope.rawValue, at: 1)
            for (offset, kind) in kinds.enumerated() {
                try stmt.bind(kind.rawValue, at: Int32(2 + offset))
            }
        }

        var results: [MemoryFactEntry] = []
        while try stmt.step() {
            if let entry = memoryFactEntryFrom(stmt) { results.append(entry) }
        }
        return results
    }

    /// Marks every currently-`active` entry in (scope, scopeRefId) as
    /// `superseded`, linking them to the replacement via `supersededBy`. Called
    /// atomically in the same transaction as the replacement insert so there is
    /// never a window where two active entries coexist for the same scope+ref.
    func supersedeActiveMemoryEntries(
        scope: MemoryScope,
        scopeRefId: UUID?,
        replacementId: UUID,
        at now: Date
    ) throws {
        let sql: String
        let stmt: Statement
        if let scopeRefId {
            sql = """
                UPDATE memory_entries
                SET status = 'superseded', supersededBy = ?, updatedAt = ?
                WHERE scope = ? AND scopeRefId = ? AND status = 'active';
            """
            stmt = try db.prepare(sql)
            try stmt.bind(replacementId.uuidString, at: 1)
            try stmt.bind(now.timeIntervalSince1970, at: 2)
            try stmt.bind(scope.rawValue, at: 3)
            try stmt.bind(scopeRefId.uuidString, at: 4)
        } else {
            sql = """
                UPDATE memory_entries
                SET status = 'superseded', supersededBy = ?, updatedAt = ?
                WHERE scope = ? AND scopeRefId IS NULL AND status = 'active';
            """
            stmt = try db.prepare(sql)
            try stmt.bind(replacementId.uuidString, at: 1)
            try stmt.bind(now.timeIntervalSince1970, at: 2)
            try stmt.bind(scope.rawValue, at: 3)
        }
        try stmt.step()
    }

    private func encodeSourceNodeIds(_ ids: [UUID]) -> String {
        let strings = ids.map { $0.uuidString }
        guard let data = try? JSONSerialization.data(withJSONObject: strings),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private func decodeSourceNodeIds(_ json: String) -> [UUID] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return arr.compactMap { UUID(uuidString: $0) }
    }

    private func deleteCanonicalMemory(scope: MemoryScope, scopeRefId: UUID) throws {
        let deleteEntries = try db.prepare("""
            DELETE FROM memory_entries
            WHERE scope = ? AND scopeRefId = ?;
        """)
        try deleteEntries.bind(scope.rawValue, at: 1)
        try deleteEntries.bind(scopeRefId.uuidString, at: 2)
        try deleteEntries.step()

        let deleteFactEntries = try db.prepare("""
            DELETE FROM memory_fact_entries
            WHERE scope = ? AND scopeRefId = ?;
        """)
        try deleteFactEntries.bind(scope.rawValue, at: 1)
        try deleteFactEntries.bind(scopeRefId.uuidString, at: 2)
        try deleteFactEntries.step()
    }

    private func memoryEntryFrom(_ stmt: Statement) -> MemoryEntry? {
        guard let idText = stmt.text(at: 0), let id = UUID(uuidString: idText) else { return nil }
        guard let scopeText = stmt.text(at: 1), let scope = MemoryScope(rawValue: scopeText) else { return nil }
        let scopeRefId: UUID? = stmt.text(at: 2).flatMap { UUID(uuidString: $0) }
        guard let kindText = stmt.text(at: 3), let kind = MemoryKind(rawValue: kindText) else { return nil }
        guard let stabilityText = stmt.text(at: 4), let stability = MemoryStability(rawValue: stabilityText) else { return nil }
        guard let statusText = stmt.text(at: 5), let status = MemoryStatus(rawValue: statusText) else { return nil }
        let content = stmt.text(at: 6) ?? ""
        let confidence = stmt.double(at: 7)
        let sourceNodeIds = decodeSourceNodeIds(stmt.text(at: 8) ?? "[]")
        let createdAt = Date(timeIntervalSince1970: stmt.double(at: 9))
        let updatedAt = Date(timeIntervalSince1970: stmt.double(at: 10))
        let lastConfirmedAt: Date? = stmt.isNull(at: 11) ? nil : Date(timeIntervalSince1970: stmt.double(at: 11))
        let expiresAt: Date? = stmt.isNull(at: 12) ? nil : Date(timeIntervalSince1970: stmt.double(at: 12))
        let supersededBy: UUID? = stmt.text(at: 13).flatMap { UUID(uuidString: $0) }
        return MemoryEntry(
            id: id,
            scope: scope,
            scopeRefId: scopeRefId,
            kind: kind,
            stability: stability,
            status: status,
            content: content,
            confidence: confidence,
            sourceNodeIds: sourceNodeIds,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastConfirmedAt: lastConfirmedAt,
            expiresAt: expiresAt,
            supersededBy: supersededBy
        )
    }

    private func memoryFactEntryFrom(_ stmt: Statement) -> MemoryFactEntry? {
        guard let idText = stmt.text(at: 0), let id = UUID(uuidString: idText) else { return nil }
        guard let scopeText = stmt.text(at: 1), let scope = MemoryScope(rawValue: scopeText) else { return nil }
        let scopeRefId: UUID? = stmt.text(at: 2).flatMap { UUID(uuidString: $0) }
        guard let kindText = stmt.text(at: 3), let kind = MemoryKind(rawValue: kindText) else { return nil }
        let content = stmt.text(at: 4) ?? ""
        let confidence = stmt.double(at: 5)
        guard let statusText = stmt.text(at: 6), let status = MemoryStatus(rawValue: statusText) else { return nil }
        guard let stabilityText = stmt.text(at: 7), let stability = MemoryStability(rawValue: stabilityText) else { return nil }
        let sourceNodeIds = decodeSourceNodeIds(stmt.text(at: 8) ?? "[]")
        let createdAt = Date(timeIntervalSince1970: stmt.double(at: 9))
        let updatedAt = Date(timeIntervalSince1970: stmt.double(at: 10))
        return MemoryFactEntry(
            id: id,
            scope: scope,
            scopeRefId: scopeRefId,
            kind: kind,
            content: content,
            confidence: confidence,
            status: status,
            stability: stability,
            sourceNodeIds: sourceNodeIds,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - Projects

    func insertProject(_ project: Project) throws {
        let stmt = try db.prepare("""
            INSERT INTO projects (id, title, goal, emoji, createdAt)
            VALUES (?, ?, ?, ?, ?);
        """)
        try stmt.bind(project.id.uuidString, at: 1)
        try stmt.bind(project.title, at: 2)
        try stmt.bind(project.goal, at: 3)
        try stmt.bind(project.emoji, at: 4)
        try stmt.bind(project.createdAt.timeIntervalSince1970, at: 5)
        try stmt.step()
        notifyNodesDidChange()
    }

    func fetchProject(id: UUID) throws -> Project? {
        let stmt = try db.prepare("""
            SELECT id, title, goal, emoji, createdAt FROM projects WHERE id=?;
        """)
        try stmt.bind(id.uuidString, at: 1)
        guard try stmt.step() else { return nil }
        return projectFrom(stmt)
    }

    func fetchAllProjects() throws -> [Project] {
        let stmt = try db.prepare("""
            SELECT id, title, goal, emoji, createdAt FROM projects ORDER BY createdAt DESC;
        """)
        var results: [Project] = []
        while try stmt.step() {
            results.append(projectFrom(stmt))
        }
        return results
    }

    func deleteProject(id: UUID) throws {
        try inTransaction {
            try deleteCanonicalMemory(scope: .project, scopeRefId: id)
            let stmt = try db.prepare("DELETE FROM projects WHERE id=?;")
            try stmt.bind(id.uuidString, at: 1)
            try stmt.step()
        }
        notifyNodesDidChange()
    }

    private func projectFrom(_ stmt: Statement) -> Project {
        let id = UUID(uuidString: stmt.text(at: 0) ?? "") ?? UUID()
        let title = stmt.text(at: 1) ?? ""
        let goal = stmt.text(at: 2) ?? ""
        let emoji = stmt.text(at: 3) ?? "📁"
        let createdAt = Date(timeIntervalSince1970: stmt.double(at: 4))
        return Project(id: id, title: title, goal: goal, emoji: emoji, createdAt: createdAt)
    }

    // MARK: - Edges

    func insertEdge(_ edge: NodeEdge) throws {
        let stmt = try db.prepare("""
            INSERT INTO edges (id, sourceId, targetId, strength, type)
            VALUES (?, ?, ?, ?, ?);
        """)
        try stmt.bind(edge.id.uuidString, at: 1)
        try stmt.bind(edge.sourceId.uuidString, at: 2)
        try stmt.bind(edge.targetId.uuidString, at: 3)
        try stmt.bind(Double(edge.strength), at: 4)
        try stmt.bind(edge.type.rawValue, at: 5)
        try stmt.step()
    }

    func fetchEdges(nodeId: UUID) throws -> [NodeEdge] {
        let stmt = try db.prepare("""
            SELECT id, sourceId, targetId, strength, type
            FROM edges WHERE sourceId=? OR targetId=?;
        """)
        try stmt.bind(nodeId.uuidString, at: 1)
        try stmt.bind(nodeId.uuidString, at: 2)
        var results: [NodeEdge] = []
        while try stmt.step() {
            results.append(edgeFrom(stmt))
        }
        return results
    }

    func fetchAllEdges() throws -> [NodeEdge] {
        let stmt = try db.prepare("""
            SELECT id, sourceId, targetId, strength, type FROM edges;
        """)
        var results: [NodeEdge] = []
        while try stmt.step() {
            results.append(edgeFrom(stmt))
        }
        return results
    }

    func deleteEdges(nodeId: UUID, type: EdgeType) throws {
        let stmt = try db.prepare("""
            DELETE FROM edges WHERE (sourceId=? OR targetId=?) AND type=?;
        """)
        try stmt.bind(nodeId.uuidString, at: 1)
        try stmt.bind(nodeId.uuidString, at: 2)
        try stmt.bind(type.rawValue, at: 3)
        try stmt.step()
    }

    private func edgeFrom(_ stmt: Statement) -> NodeEdge {
        let id = UUID(uuidString: stmt.text(at: 0) ?? "") ?? UUID()
        let sourceId = UUID(uuidString: stmt.text(at: 1) ?? "") ?? UUID()
        let targetId = UUID(uuidString: stmt.text(at: 2) ?? "") ?? UUID()
        let strength = Float(stmt.double(at: 3))
        let type = EdgeType(rawValue: stmt.text(at: 4) ?? "") ?? .semantic
        return NodeEdge(id: id, sourceId: sourceId, targetId: targetId, strength: strength, type: type)
    }
}

// MARK: - Judge Events

enum JudgeEventFilter: Equatable, Hashable {
    case none
    case fallback(JudgeFallbackReason)
    case shouldProvoke(Bool)
    case userState(UserState)
    case provocationKind(ProvocationKind)
}

extension NodeStore {

    func appendJudgeEvent(_ event: JudgeEvent) throws {
        let stmt = try db.prepare("""
            INSERT INTO judge_events
              (id, ts, nodeId, messageId, chatMode, provider,
               verdictJSON, fallbackReason, userFeedback, feedbackTs, feedbackReason, feedbackNote)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        try stmt.bind(event.id.uuidString, at: 1)
        try stmt.bind(event.ts.timeIntervalSince1970, at: 2)
        try stmt.bind(event.nodeId.uuidString, at: 3)
        try stmt.bind(event.messageId?.uuidString, at: 4)
        try stmt.bind(event.chatMode.rawValue, at: 5)
        try stmt.bind(event.provider.rawValue, at: 6)
        try stmt.bind(event.verdictJSON, at: 7)
        try stmt.bind(event.fallbackReason.rawValue, at: 8)
        try stmt.bind(event.userFeedback?.rawValue, at: 9)
        try stmt.bind(event.feedbackTs?.timeIntervalSince1970, at: 10)
        try stmt.bind(event.feedbackReason?.rawValue, at: 11)
        try stmt.bind(event.feedbackNote, at: 12)
        try stmt.step()
    }

    func fetchJudgeEvent(id: UUID) throws -> JudgeEvent? {
        let stmt = try db.prepare("""
            SELECT id, ts, nodeId, messageId, chatMode, provider,
                   verdictJSON, fallbackReason, userFeedback, feedbackTs, feedbackReason, feedbackNote
            FROM judge_events
            WHERE id = ?
            LIMIT 1;
        """)
        try stmt.bind(id.uuidString, at: 1)
        guard try stmt.step() else { return nil }
        return judgeEventFrom(stmt)
    }

    func recentJudgeEvents(limit: Int, filter: JudgeEventFilter) throws -> [JudgeEvent] {
        let whereClause: String
        switch filter {
        case .none:
            whereClause = ""
        case .fallback:
            whereClause = "WHERE fallbackReason = ?"
        case .shouldProvoke:
            whereClause = "WHERE json_extract(verdictJSON, '$.should_provoke') = ?"
        case .userState:
            whereClause = "WHERE json_extract(verdictJSON, '$.user_state') = ?"
        case .provocationKind:
            whereClause = "WHERE json_extract(verdictJSON, '$.provocation_kind') = ?"
        }
        let stmt = try db.prepare("""
            SELECT id, ts, nodeId, messageId, chatMode, provider,
                   verdictJSON, fallbackReason, userFeedback, feedbackTs, feedbackReason, feedbackNote
            FROM judge_events
            \(whereClause)
            ORDER BY ts DESC
            LIMIT ?;
        """)
        switch filter {
        case .none:
            try stmt.bind(limit, at: 1)
        case .fallback(let reason):
            try stmt.bind(reason.rawValue, at: 1)
            try stmt.bind(limit, at: 2)
        case .shouldProvoke(let flag):
            try stmt.bind(flag ? 1 : 0, at: 1)
            try stmt.bind(limit, at: 2)
        case .userState(let state):
            try stmt.bind(state.rawValue, at: 1)
            try stmt.bind(limit, at: 2)
        case .provocationKind(let kind):
            try stmt.bind(kind.rawValue, at: 1)
            try stmt.bind(limit, at: 2)
        }
        var out: [JudgeEvent] = []
        while try stmt.step() {
            if let ev = judgeEventFrom(stmt) { out.append(ev) }
        }
        return out
    }

    func updateJudgeEventMessageId(eventId: UUID, messageId: UUID) throws {
        let stmt = try db.prepare("""
            UPDATE judge_events SET messageId = ? WHERE id = ?;
        """)
        try stmt.bind(messageId.uuidString, at: 1)
        try stmt.bind(eventId.uuidString, at: 2)
        try stmt.step()
    }

    func updateJudgeEventFeedback(
        id: UUID,
        feedback: JudgeFeedback,
        reason: JudgeFeedbackReason? = nil,
        note: String? = nil,
        at ts: Date
    ) throws {
        let stmt = try db.prepare("""
            UPDATE judge_events
            SET userFeedback = ?, feedbackTs = ?, feedbackReason = ?, feedbackNote = ?
            WHERE id = ?;
        """)
        try stmt.bind(feedback.rawValue, at: 1)
        try stmt.bind(ts.timeIntervalSince1970, at: 2)
        try stmt.bind(reason?.rawValue, at: 3)
        try stmt.bind(note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, at: 4)
        try stmt.bind(id.uuidString, at: 5)
        try stmt.step()
    }

    func clearJudgeEventFeedback(id: UUID) throws {
        let stmt = try db.prepare("""
            UPDATE judge_events
            SET userFeedback = NULL,
                feedbackTs = NULL,
                feedbackReason = NULL,
                feedbackNote = NULL
            WHERE id = ?;
        """)
        try stmt.bind(id.uuidString, at: 1)
        try stmt.step()
    }

    func latestChatMode(forNode nodeId: UUID) throws -> ChatMode? {
        let stmt = try db.prepare("""
            SELECT chatMode FROM judge_events
            WHERE nodeId = ?
            ORDER BY ts DESC
            LIMIT 1;
        """)
        try stmt.bind(nodeId.uuidString, at: 1)
        guard try stmt.step() else { return nil }
        let raw = stmt.text(at: 0)
        return raw.flatMap(ChatMode.init(rawValue:))
    }

    private func judgeEventFrom(_ stmt: Statement) -> JudgeEvent? {
        guard let idStr = stmt.text(at: 0), let id = UUID(uuidString: idStr),
              let nodeIdStr = stmt.text(at: 2), let nodeId = UUID(uuidString: nodeIdStr),
              let chatModeStr = stmt.text(at: 4), let chatMode = ChatMode(rawValue: chatModeStr),
              let providerStr = stmt.text(at: 5), let provider = LLMProvider(rawValue: providerStr),
              let verdictJSON = stmt.text(at: 6),
              let fallbackStr = stmt.text(at: 7), let fallback = JudgeFallbackReason(rawValue: fallbackStr)
        else { return nil }
        let messageId = stmt.text(at: 3).flatMap(UUID.init(uuidString:))
        let feedback = stmt.text(at: 8).flatMap(JudgeFeedback.init(rawValue:))
        let feedbackTs = stmt.isNull(at: 9) ? nil : Date(timeIntervalSince1970: stmt.double(at: 9))
        let feedbackReason = stmt.text(at: 10).flatMap(JudgeFeedbackReason.init(rawValue:))
        let feedbackNote = stmt.text(at: 11)
        return JudgeEvent(
            id: id,
            ts: Date(timeIntervalSince1970: stmt.double(at: 1)),
            nodeId: nodeId,
            messageId: messageId,
            chatMode: chatMode,
            provider: provider,
            verdictJSON: verdictJSON,
            fallbackReason: fallback,
            userFeedback: feedback,
            feedbackTs: feedbackTs,
            feedbackReason: feedbackReason,
            feedbackNote: feedbackNote
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
