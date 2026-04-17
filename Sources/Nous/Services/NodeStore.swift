import Foundation

extension Notification.Name {
    static let nousNodesDidChange = Notification.Name("NousNodesDidChange")
}

// MARK: - NodeStore

final class NodeStore {

    private let db: Database

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
                id        TEXT PRIMARY KEY,
                nodeId    TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
                role      TEXT NOT NULL,
                content   TEXT NOT NULL,
                timestamp REAL NOT NULL
            );
        """)

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

        // Indexes
        try db.exec("CREATE INDEX IF NOT EXISTS idx_nodes_projectId  ON nodes(projectId);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_messages_nodeId  ON messages(nodeId);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_edges_sourceId   ON edges(sourceId);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_edges_targetId   ON edges(targetId);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_conversation_memory_updatedAt ON conversation_memory(updatedAt);")
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
    }

    func deleteNode(id: UUID) throws {
        let stmt = try db.prepare("DELETE FROM nodes WHERE id=?;")
        try stmt.bind(id.uuidString, at: 1)
        try stmt.step()
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
            INSERT INTO messages (id, nodeId, role, content, timestamp)
            VALUES (?, ?, ?, ?, ?);
        """)
        try stmt.bind(message.id.uuidString, at: 1)
        try stmt.bind(message.nodeId.uuidString, at: 2)
        try stmt.bind(message.role.rawValue, at: 3)
        try stmt.bind(message.content, at: 4)
        try stmt.bind(message.timestamp.timeIntervalSince1970, at: 5)
        try stmt.step()
    }

    func fetchMessages(nodeId: UUID) throws -> [Message] {
        let stmt = try db.prepare("""
            SELECT id, nodeId, role, content, timestamp
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
            results.append(Message(id: id, nodeId: nId, role: role, content: content, timestamp: timestamp))
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

    /// Number of conversation_memory rows for nodes in this project whose
    /// `updatedAt` is strictly greater than this project's `project_memory.updatedAt`
    /// (or 0 if no project_memory row exists). Drives the timestamp-derived
    /// project-refresh trigger so the signal survives app restarts (prior
    /// in-memory counter silently died on quit — see plan §14.1 / Eng Review #3).
    func countConversationMemoryUpdatesSinceProjectMemory(projectId: UUID) throws -> Int {
        let lastProjectRefresh: Double
        let pmStmt = try db.prepare("""
            SELECT updatedAt FROM project_memory WHERE projectId = ?;
        """)
        try pmStmt.bind(projectId.uuidString, at: 1)
        if try pmStmt.step() {
            lastProjectRefresh = pmStmt.double(at: 0)
        } else {
            lastProjectRefresh = 0
        }

        let countStmt = try db.prepare("""
            SELECT COUNT(*)
            FROM conversation_memory cm
            JOIN nodes n ON cm.nodeId = n.id
            WHERE n.projectId = ? AND cm.updatedAt > ?;
        """)
        try countStmt.bind(projectId.uuidString, at: 1)
        try countStmt.bind(lastProjectRefresh, at: 2)
        _ = try countStmt.step()
        return countStmt.int(at: 0)
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
        let stmt = try db.prepare("DELETE FROM projects WHERE id=?;")
        try stmt.bind(id.uuidString, at: 1)
        try stmt.step()
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
