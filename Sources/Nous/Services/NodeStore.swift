import Foundation

extension Notification.Name {
    static let nousNodesDidChange = Notification.Name("NousNodesDidChange")
}

struct ScratchPadStateRecord: Equatable {
    let nodeId: UUID
    let latestSummary: ScratchSummary?
    let currentContent: String
    let baseSnapshot: String
    let contentBaseGeneratedAt: Date?
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

        try db.exec("""
            CREATE TABLE IF NOT EXISTS scratchpad_state (
                nodeId                     TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                latestSummaryMarkdown      TEXT,
                latestSummaryGeneratedAt   REAL,
                latestSummarySourceMessageId TEXT,
                currentContent             TEXT NOT NULL DEFAULT '',
                baseSnapshot               TEXT NOT NULL DEFAULT '',
                contentBaseGeneratedAt     REAL
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

        // Weekly self-reflection tables (WeeklyReflectionService).
        // `reflection_runs` is one row per weekly job; `reflection_claim` stores
        // validator-passed claims; `reflection_evidence` binds each claim to the
        // `messages` rows that support it. Evidence cascades when messages are
        // deleted; an app-level step then re-checks claim evidence count and
        // flips `reflection_claim.status` to 'orphaned' if it drops below the
        // validator's minimum (2).
        //
        // `project_id` is nullable because conversations without a project
        // (Alex's primary usage mode as of 2026-04-22) still need weekly
        // reflection. NULL means "free-chat scope" — all projectId IS NULL
        // conversations in the week. The unique index below uses COALESCE so
        // NULL-scoped runs still dedupe per-week.
        try db.exec("""
            CREATE TABLE IF NOT EXISTS reflection_runs (
                id               TEXT PRIMARY KEY,
                project_id       TEXT REFERENCES projects(id) ON DELETE CASCADE,
                week_start       REAL NOT NULL,
                week_end         REAL NOT NULL,
                ran_at           REAL NOT NULL,
                status           TEXT NOT NULL,
                rejection_reason TEXT,
                cost_cents       INTEGER
            );
        """)

        try db.exec("""
            CREATE TABLE IF NOT EXISTS reflection_claim (
                id              TEXT PRIMARY KEY,
                run_id          TEXT NOT NULL REFERENCES reflection_runs(id) ON DELETE CASCADE,
                claim           TEXT NOT NULL,
                confidence      REAL NOT NULL,
                why_non_obvious TEXT NOT NULL,
                status          TEXT NOT NULL,
                created_at      REAL NOT NULL
            );
        """)

        try db.exec("""
            CREATE TABLE IF NOT EXISTS reflection_evidence (
                reflection_id TEXT NOT NULL REFERENCES reflection_claim(id) ON DELETE CASCADE,
                message_id    TEXT NOT NULL REFERENCES messages(id)         ON DELETE CASCADE,
                PRIMARY KEY (reflection_id, message_id)
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
        try db.exec("CREATE INDEX IF NOT EXISTS idx_reflection_runs_project_week ON reflection_runs(project_id, week_end);")
        // SQLite treats NULLs as distinct in UNIQUE constraints, so the free-chat
        // scope (project_id IS NULL) would accept duplicate rows for the same week.
        // COALESCE folds NULL to '' and restores the single-row-per-(scope, week) invariant.
        try db.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_reflection_runs_unique ON reflection_runs(COALESCE(project_id, ''), week_start, week_end);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_reflection_claim_run ON reflection_claim(run_id);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_reflection_claim_status ON reflection_claim(status);")
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
            NotificationCenter.default.post(name: .nousNodesDidChange, object: self)
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
            // Messages cascade out via FK; reflection_evidence cascades from
            // messages. Reconcile any claim that lost its two-evidence floor.
            try reconcileOrphanedReflectionClaims()
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

    func deleteMessage(id: UUID) throws {
        let stmt = try db.prepare("DELETE FROM messages WHERE id = ?;")
        try stmt.bind(id.uuidString, at: 1)
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

    func clearAllMessageThinkingContent() throws {
        let stmt = try db.prepare("""
            UPDATE messages
               SET thinking_content = NULL
             WHERE thinking_content IS NOT NULL;
        """)
        try stmt.step()
        notifyNodesDidChange()
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

    func fetchScratchPadState(nodeId: UUID) throws -> ScratchPadStateRecord? {
        let stmt = try db.prepare("""
            SELECT latestSummaryMarkdown,
                   latestSummaryGeneratedAt,
                   latestSummarySourceMessageId,
                   currentContent,
                   baseSnapshot,
                   contentBaseGeneratedAt
            FROM scratchpad_state
            WHERE nodeId = ?;
        """)
        try stmt.bind(nodeId.uuidString, at: 1)
        guard try stmt.step() else { return nil }

        let latestSummary: ScratchSummary?
        if let markdown = stmt.text(at: 0),
           let sourceMessageIdRaw = stmt.text(at: 2),
           let sourceMessageId = UUID(uuidString: sourceMessageIdRaw) {
            latestSummary = ScratchSummary(
                markdown: markdown,
                generatedAt: Date(timeIntervalSince1970: stmt.double(at: 1)),
                sourceMessageId: sourceMessageId
            )
        } else {
            latestSummary = nil
        }

        let currentContent = stmt.text(at: 3) ?? ""
        let baseSnapshot = stmt.text(at: 4) ?? ""
        let contentBaseGeneratedAt: Date?
        if stmt.text(at: 5) != nil {
            contentBaseGeneratedAt = Date(timeIntervalSince1970: stmt.double(at: 5))
        } else {
            contentBaseGeneratedAt = nil
        }

        return ScratchPadStateRecord(
            nodeId: nodeId,
            latestSummary: latestSummary,
            currentContent: currentContent,
            baseSnapshot: baseSnapshot,
            contentBaseGeneratedAt: contentBaseGeneratedAt
        )
    }

    func saveScratchPadState(_ state: ScratchPadStateRecord) throws {
        let stmt = try db.prepare("""
            INSERT INTO scratchpad_state (
                nodeId,
                latestSummaryMarkdown,
                latestSummaryGeneratedAt,
                latestSummarySourceMessageId,
                currentContent,
                baseSnapshot,
                contentBaseGeneratedAt
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(nodeId) DO UPDATE SET
                latestSummaryMarkdown = excluded.latestSummaryMarkdown,
                latestSummaryGeneratedAt = excluded.latestSummaryGeneratedAt,
                latestSummarySourceMessageId = excluded.latestSummarySourceMessageId,
                currentContent = excluded.currentContent,
                baseSnapshot = excluded.baseSnapshot,
                contentBaseGeneratedAt = excluded.contentBaseGeneratedAt;
        """)
        try stmt.bind(state.nodeId.uuidString, at: 1)
        try stmt.bind(state.latestSummary?.markdown, at: 2)
        try stmt.bind(state.latestSummary?.generatedAt.timeIntervalSince1970, at: 3)
        try stmt.bind(state.latestSummary?.sourceMessageId.uuidString, at: 4)
        try stmt.bind(state.currentContent, at: 5)
        try stmt.bind(state.baseSnapshot, at: 6)
        try stmt.bind(state.contentBaseGeneratedAt?.timeIntervalSince1970, at: 7)
        try stmt.step()
    }

    func deleteScratchPadState(nodeId: UUID) throws {
        let stmt = try db.prepare("""
            DELETE FROM scratchpad_state WHERE nodeId = ?;
        """)
        try stmt.bind(nodeId.uuidString, at: 1)
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
            // Nodes cascade via FK → messages cascade → reflection_evidence
            // cascades. Reflection_runs for this project also cascade, which
            // drops their claims. Sweep any other claims that lost evidence.
            try reconcileOrphanedReflectionClaims()
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

    func clearJudgeEventMessageId(messageId: UUID) throws {
        let stmt = try db.prepare("""
            UPDATE judge_events SET messageId = NULL WHERE messageId = ?;
        """)
        try stmt.bind(messageId.uuidString, at: 1)
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

// MARK: - Reflections

extension NodeStore {

    /// Per-conversation rollup used by WeeklyReflectionService when building
    /// the prompt fixture. The reflection prompt is chat-aware — it wants the
    /// model to notice patterns across separate conversations in the same
    /// week, so we group messages by `nodeId` rather than returning a flat list.
    struct ReflectionFixtureRow {
        let nodeId: UUID
        let nodeTitle: String
        let messages: [Message]
    }

    /// Pulls messages in the week window across all nodes matching `projectId`.
    /// `projectId == nil` matches free-chat nodes (projectId IS NULL).
    /// Ordered by node, then by timestamp ascending within each node.
    func fetchReflectionFixture(
        projectId: UUID?,
        weekStart: Date,
        weekEnd: Date
    ) throws -> [ReflectionFixtureRow] {
        let sql: String
        if projectId != nil {
            sql = """
                SELECT m.id, m.nodeId, n.title, m.role, m.content, m.timestamp, m.thinking_content
                FROM messages m
                JOIN nodes n ON n.id = m.nodeId
                WHERE n.projectId = ?
                  AND m.timestamp >= ?
                  AND m.timestamp <  ?
                ORDER BY m.nodeId, m.timestamp ASC;
            """
        } else {
            sql = """
                SELECT m.id, m.nodeId, n.title, m.role, m.content, m.timestamp, m.thinking_content
                FROM messages m
                JOIN nodes n ON n.id = m.nodeId
                WHERE n.projectId IS NULL
                  AND m.timestamp >= ?
                  AND m.timestamp <  ?
                ORDER BY m.nodeId, m.timestamp ASC;
            """
        }
        let stmt = try db.prepare(sql)
        if let projectId {
            try stmt.bind(projectId.uuidString, at: 1)
            try stmt.bind(weekStart.timeIntervalSince1970, at: 2)
            try stmt.bind(weekEnd.timeIntervalSince1970, at: 3)
        } else {
            try stmt.bind(weekStart.timeIntervalSince1970, at: 1)
            try stmt.bind(weekEnd.timeIntervalSince1970, at: 2)
        }

        var grouped: [(UUID, String, [Message])] = []
        while try stmt.step() {
            let id = UUID(uuidString: stmt.text(at: 0) ?? "") ?? UUID()
            let nodeId = UUID(uuidString: stmt.text(at: 1) ?? "") ?? UUID()
            let title = stmt.text(at: 2) ?? ""
            let role = MessageRole(rawValue: stmt.text(at: 3) ?? "") ?? .user
            let content = stmt.text(at: 4) ?? ""
            let ts = Date(timeIntervalSince1970: stmt.double(at: 5))
            let thinking = stmt.text(at: 6)
            let msg = Message(id: id, nodeId: nodeId, role: role, content: content, timestamp: ts, thinkingContent: thinking)
            if let i = grouped.lastIndex(where: { $0.0 == nodeId }) {
                grouped[i].2.append(msg)
            } else {
                grouped.append((nodeId, title, [msg]))
            }
        }
        return grouped.map { ReflectionFixtureRow(nodeId: $0.0, nodeTitle: $0.1, messages: $0.2) }
    }

    /// Writes a run + its validated claims + evidence rows in a single
    /// transaction (Codex T5). If the validator rejected everything, pass
    /// empty `claims` / `evidence` and a non-nil `run.rejectionReason`.
    /// Callers get atomic "either the whole weekly reflection lands or
    /// nothing does".
    func persistReflectionRun(
        _ run: ReflectionRun,
        claims: [ReflectionClaim],
        evidence: [ReflectionEvidence]
    ) throws {
        try inTransaction {
            try self.insertReflectionRun(run)
            for claim in claims {
                try self.insertReflectionClaim(claim)
            }
            for ev in evidence {
                try self.insertReflectionEvidence(ev)
            }
        }
    }

    /// Returns true iff a run (success OR rejected_all OR failed) already
    /// exists for this (scope, week). The foreground trigger calls this
    /// before kicking off a job so we don't double-run on app launches
    /// after the Sunday rollover.
    ///
    /// NULL-safe match: `projectId == nil` matches rows with
    /// `project_id IS NULL`. Mirrors the COALESCE unique index.
    func existsReflectionRun(
        projectId: UUID?,
        weekStart: Date,
        weekEnd: Date
    ) throws -> Bool {
        let sql: String
        if projectId != nil {
            sql = """
                SELECT 1 FROM reflection_runs
                WHERE project_id = ? AND week_start = ? AND week_end = ?
                LIMIT 1;
            """
        } else {
            sql = """
                SELECT 1 FROM reflection_runs
                WHERE project_id IS NULL AND week_start = ? AND week_end = ?
                LIMIT 1;
            """
        }
        let stmt = try db.prepare(sql)
        if let projectId {
            try stmt.bind(projectId.uuidString, at: 1)
            try stmt.bind(weekStart.timeIntervalSince1970, at: 2)
            try stmt.bind(weekEnd.timeIntervalSince1970, at: 3)
        } else {
            try stmt.bind(weekStart.timeIntervalSince1970, at: 1)
            try stmt.bind(weekEnd.timeIntervalSince1970, at: 2)
        }
        return try stmt.step()
    }

    /// Most-recent run regardless of status. The foreground trigger uses this
    /// to decide whether *any* attempt has happened this week (so we don't
    /// retry a `.failed` run five times per app launch).
    func latestReflectionRun(projectId: UUID?) throws -> ReflectionRun? {
        let sql: String
        if projectId != nil {
            sql = """
                SELECT id, project_id, week_start, week_end, ran_at, status,
                       rejection_reason, cost_cents
                FROM reflection_runs
                WHERE project_id = ?
                ORDER BY ran_at DESC
                LIMIT 1;
            """
        } else {
            sql = """
                SELECT id, project_id, week_start, week_end, ran_at, status,
                       rejection_reason, cost_cents
                FROM reflection_runs
                WHERE project_id IS NULL
                ORDER BY ran_at DESC
                LIMIT 1;
            """
        }
        let stmt = try db.prepare(sql)
        if let projectId {
            try stmt.bind(projectId.uuidString, at: 1)
        }
        guard try stmt.step() else { return nil }
        return reflectionRunFrom(stmt)
    }

    /// Active reflections for a scope. Pulls claims whose parent run matches
    /// `projectId` (including NULL = free-chat scope) and whose `status =
    /// 'active'`. Used by retrieval when building the Self-reflection slice
    /// of the citable-entry pool (Codex R2).
    func fetchActiveReflectionClaims(projectId: UUID?) throws -> [ReflectionClaim] {
        let sql: String
        if projectId != nil {
            sql = """
                SELECT c.id, c.run_id, c.claim, c.confidence, c.why_non_obvious,
                       c.status, c.created_at
                FROM reflection_claim c
                JOIN reflection_runs r ON r.id = c.run_id
                WHERE r.project_id = ? AND c.status = 'active'
                ORDER BY c.created_at DESC;
            """
        } else {
            sql = """
                SELECT c.id, c.run_id, c.claim, c.confidence, c.why_non_obvious,
                       c.status, c.created_at
                FROM reflection_claim c
                JOIN reflection_runs r ON r.id = c.run_id
                WHERE r.project_id IS NULL AND c.status = 'active'
                ORDER BY c.created_at DESC;
            """
        }
        let stmt = try db.prepare(sql)
        if let projectId {
            try stmt.bind(projectId.uuidString, at: 1)
        }
        var results: [ReflectionClaim] = []
        while try stmt.step() {
            results.append(reflectionClaimFrom(stmt))
        }
        return results
    }

    /// Flip a single claim to `.orphaned`. Used by the MemoryDebugInspector
    /// manual-orphan button and by `reconcileOrphanedReflectionClaims`.
    /// No-op if the claim is already orphaned/superseded.
    func orphanReflectionClaim(id: UUID) throws {
        let stmt = try db.prepare("""
            UPDATE reflection_claim
            SET status = 'orphaned'
            WHERE id = ? AND status = 'active';
        """)
        try stmt.bind(id.uuidString, at: 1)
        try stmt.step()
    }

    /// After a cascade-delete drops evidence rows, any claim whose remaining
    /// grounded evidence falls below 2 loses the "two independent turns"
    /// invariant the validator enforced at creation time. Flip those claims
    /// to `.orphaned` so they exit the citable-entry pool.
    ///
    /// Returns the claim IDs that were flipped (useful for tests + debug UI).
    @discardableResult
    func reconcileOrphanedReflectionClaims() throws -> [UUID] {
        let stmt = try db.prepare("""
            SELECT c.id
            FROM reflection_claim c
            LEFT JOIN reflection_evidence e ON e.reflection_id = c.id
            WHERE c.status = 'active'
            GROUP BY c.id
            HAVING COUNT(e.message_id) < 2;
        """)
        var flipped: [UUID] = []
        while try stmt.step() {
            guard let raw = stmt.text(at: 0),
                  let uuid = UUID(uuidString: raw) else { continue }
            flipped.append(uuid)
        }
        for id in flipped {
            try orphanReflectionClaim(id: id)
        }
        return flipped
    }

    // MARK: - Internal inserts

    private func insertReflectionRun(_ run: ReflectionRun) throws {
        let stmt = try db.prepare("""
            INSERT INTO reflection_runs
              (id, project_id, week_start, week_end, ran_at, status,
               rejection_reason, cost_cents)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """)
        try stmt.bind(run.id.uuidString, at: 1)
        try stmt.bind(run.projectId?.uuidString, at: 2)
        try stmt.bind(run.weekStart.timeIntervalSince1970, at: 3)
        try stmt.bind(run.weekEnd.timeIntervalSince1970, at: 4)
        try stmt.bind(run.ranAt.timeIntervalSince1970, at: 5)
        try stmt.bind(run.status.rawValue, at: 6)
        try stmt.bind(run.rejectionReason?.rawValue, at: 7)
        if let cents = run.costCents {
            try stmt.bind(cents, at: 8)
        } else {
            try stmt.bind(nil as String?, at: 8)
        }
        try stmt.step()
    }

    private func insertReflectionClaim(_ claim: ReflectionClaim) throws {
        let stmt = try db.prepare("""
            INSERT INTO reflection_claim
              (id, run_id, claim, confidence, why_non_obvious, status, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
        """)
        try stmt.bind(claim.id.uuidString, at: 1)
        try stmt.bind(claim.runId.uuidString, at: 2)
        try stmt.bind(claim.claim, at: 3)
        try stmt.bind(claim.confidence, at: 4)
        try stmt.bind(claim.whyNonObvious, at: 5)
        try stmt.bind(claim.status.rawValue, at: 6)
        try stmt.bind(claim.createdAt.timeIntervalSince1970, at: 7)
        try stmt.step()
    }

    private func insertReflectionEvidence(_ ev: ReflectionEvidence) throws {
        let stmt = try db.prepare("""
            INSERT OR IGNORE INTO reflection_evidence
              (reflection_id, message_id)
            VALUES (?, ?);
        """)
        try stmt.bind(ev.reflectionId.uuidString, at: 1)
        try stmt.bind(ev.messageId.uuidString, at: 2)
        try stmt.step()
    }

    // MARK: - Row decoders

    private func reflectionRunFrom(_ stmt: Statement) -> ReflectionRun {
        let id = UUID(uuidString: stmt.text(at: 0) ?? "") ?? UUID()
        let projectId = (stmt.text(at: 1)).flatMap { UUID(uuidString: $0) }
        let weekStart = Date(timeIntervalSince1970: stmt.double(at: 2))
        let weekEnd = Date(timeIntervalSince1970: stmt.double(at: 3))
        let ranAt = Date(timeIntervalSince1970: stmt.double(at: 4))
        let status = ReflectionRunStatus(rawValue: stmt.text(at: 5) ?? "failed") ?? .failed
        let reason = (stmt.text(at: 6)).flatMap(ReflectionRejectionReason.init(rawValue:))
        let cost: Int? = stmt.isNull(at: 7) ? nil : stmt.int(at: 7)
        return ReflectionRun(
            id: id,
            projectId: projectId,
            weekStart: weekStart,
            weekEnd: weekEnd,
            ranAt: ranAt,
            status: status,
            rejectionReason: reason,
            costCents: cost
        )
    }

    private func reflectionClaimFrom(_ stmt: Statement) -> ReflectionClaim {
        let id = UUID(uuidString: stmt.text(at: 0) ?? "") ?? UUID()
        let runId = UUID(uuidString: stmt.text(at: 1) ?? "") ?? UUID()
        let claim = stmt.text(at: 2) ?? ""
        let confidence = stmt.double(at: 3)
        let whyNonObvious = stmt.text(at: 4) ?? ""
        let status = ReflectionClaimStatus(rawValue: stmt.text(at: 5) ?? "active") ?? .active
        let createdAt = Date(timeIntervalSince1970: stmt.double(at: 6))
        return ReflectionClaim(
            id: id,
            runId: runId,
            claim: claim,
            confidence: confidence,
            whyNonObvious: whyNonObvious,
            status: status,
            createdAt: createdAt
        )
    }
}
