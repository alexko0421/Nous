import Foundation

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
                embedding  BLOB,
                projectId  TEXT REFERENCES projects(id) ON DELETE SET NULL,
                isFavorite INTEGER NOT NULL DEFAULT 0,
                createdAt  REAL NOT NULL,
                updatedAt  REAL NOT NULL
            );
        """)

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

        // Indexes
        try db.exec("CREATE INDEX IF NOT EXISTS idx_nodes_projectId  ON nodes(projectId);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_messages_nodeId  ON messages(nodeId);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_edges_sourceId   ON edges(sourceId);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_edges_targetId   ON edges(targetId);")

        // Migration: context compression columns
        try? db.exec("ALTER TABLE nodes ADD COLUMN mode TEXT;")
        try? db.exec("ALTER TABLE nodes ADD COLUMN emoji TEXT;")
        try? db.exec("ALTER TABLE nodes ADD COLUMN compressedHistory TEXT;")
        try? db.exec("ALTER TABLE nodes ADD COLUMN compressedUpTo INTEGER NOT NULL DEFAULT 0;")

        // FTS5 full-text search across messages
        try db.exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                messageId UNINDEXED, nodeId UNINDEXED, content
            );
        """)

        // Auto-sync triggers: insert + delete
        try db.exec("""
            CREATE TRIGGER IF NOT EXISTS messages_fts_insert AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts(messageId, nodeId, content)
                VALUES (NEW.id, NEW.nodeId, NEW.content);
            END;
        """)
        try db.exec("""
            CREATE TRIGGER IF NOT EXISTS messages_fts_delete AFTER DELETE ON messages BEGIN
                DELETE FROM messages_fts WHERE messageId = OLD.id;
            END;
        """)

        // Backfill: index any existing messages not yet in FTS
        try db.exec("""
            INSERT INTO messages_fts(messageId, nodeId, content)
            SELECT id, nodeId, content FROM messages
            WHERE id NOT IN (SELECT messageId FROM messages_fts);
        """)
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

    // MARK: - Smart Chunking (QMD-inspired)

    /// Splits content at natural markdown boundaries for better search indexing.
    /// Prioritizes headings > hr > blank lines > list items.
    static func chunkContent(_ content: String, targetTokens: Int = 200) -> [String] {
        guard !content.isEmpty else { return [] }
        let targetChars = targetTokens * 4 // rough estimate

        // If short enough, return as-is
        if content.count <= targetChars { return [content] }

        var chunks: [String] = []
        var current = ""

        for line in content.components(separatedBy: "\n") {
            let isBreakPoint = line.hasPrefix("#") || line.hasPrefix("---") || line.hasPrefix("***") || line.trimmingCharacters(in: .whitespaces).isEmpty

            if isBreakPoint && current.count >= targetChars / 2 {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { chunks.append(trimmed) }
                current = line + "\n"
            } else {
                current += line + "\n"
                // Force split if way over target
                if current.count > targetChars * 2 {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { chunks.append(trimmed) }
                    current = ""
                }
            }
        }

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { chunks.append(trimmed) }

        return chunks
    }

    // MARK: - Nodes

    func insertNode(_ node: NousNode) throws {
        let stmt = try db.prepare("""
            INSERT INTO nodes (id, type, title, content, embedding, projectId, isFavorite, mode, emoji, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        try stmt.bind(node.id.uuidString, at: 1)
        try stmt.bind(node.type.rawValue, at: 2)
        try stmt.bind(node.title, at: 3)
        try stmt.bind(node.content, at: 4)
        let embeddingData: Data? = node.embedding.map { encodeFloats($0) }
        try stmt.bind(embeddingData, at: 5)
        try stmt.bind(node.projectId?.uuidString, at: 6)
        try stmt.bind(node.isFavorite ? 1 : 0, at: 7)
        try stmt.bind(node.mode?.rawValue, at: 8)
        try stmt.bind(node.emoji, at: 9)
        try stmt.bind(node.createdAt.timeIntervalSince1970, at: 10)
        try stmt.bind(node.updatedAt.timeIntervalSince1970, at: 11)
        try stmt.step()
    }

    func updateNode(_ node: NousNode) throws {
        let stmt = try db.prepare("""
            UPDATE nodes
            SET type=?, title=?, content=?, embedding=?, projectId=?, isFavorite=?, mode=?, emoji=?, updatedAt=?
            WHERE id=?;
        """)
        try stmt.bind(node.type.rawValue, at: 1)
        try stmt.bind(node.title, at: 2)
        try stmt.bind(node.content, at: 3)
        let embeddingData: Data? = node.embedding.map { encodeFloats($0) }
        try stmt.bind(embeddingData, at: 4)
        try stmt.bind(node.projectId?.uuidString, at: 5)
        try stmt.bind(node.isFavorite ? 1 : 0, at: 6)
        try stmt.bind(node.mode?.rawValue, at: 7)
        try stmt.bind(node.emoji, at: 8)
        try stmt.bind(node.updatedAt.timeIntervalSince1970, at: 9)
        try stmt.bind(node.id.uuidString, at: 10)
        try stmt.step()
    }

    func deleteNode(id: UUID) throws {
        let stmt = try db.prepare("DELETE FROM nodes WHERE id=?;")
        try stmt.bind(id.uuidString, at: 1)
        try stmt.step()
    }

    func fetchNode(id: UUID) throws -> NousNode? {
        let stmt = try db.prepare("""
            SELECT id, type, title, content, embedding, projectId, isFavorite, mode, emoji, createdAt, updatedAt
            FROM nodes WHERE id=?;
        """)
        try stmt.bind(id.uuidString, at: 1)
        guard try stmt.step() else { return nil }
        return nodeFrom(stmt)
    }

    func fetchAllNodes() throws -> [NousNode] {
        let stmt = try db.prepare("""
            SELECT id, type, title, content, embedding, projectId, isFavorite, mode, emoji, createdAt, updatedAt
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
            SELECT id, type, title, content, embedding, projectId, isFavorite, mode, emoji, createdAt, updatedAt
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
            SELECT id, type, title, content, embedding, projectId, isFavorite, mode, emoji, createdAt, updatedAt
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
            SELECT id, type, title, content, embedding, projectId, isFavorite, mode, emoji, createdAt, updatedAt
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
            SELECT id, type, title, content, embedding, projectId, isFavorite, mode, emoji, createdAt, updatedAt
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

    private func nodeFrom(_ stmt: Statement) -> NousNode {
        let id = UUID(uuidString: stmt.text(at: 0) ?? "") ?? UUID()
        let type = NodeType(rawValue: stmt.text(at: 1) ?? "") ?? .note
        let title = stmt.text(at: 2) ?? ""
        let content = stmt.text(at: 3) ?? ""
        let embedding: [Float]? = stmt.blob(at: 4).map { decodeFloats($0) }
        let projectId: UUID? = stmt.text(at: 5).flatMap { UUID(uuidString: $0) }
        let isFavorite = stmt.int(at: 6) != 0
        let mode: ConversationMode? = stmt.text(at: 7).flatMap { ConversationMode(rawValue: $0) }
        let emoji = stmt.text(at: 8)
        let createdAt = Date(timeIntervalSince1970: stmt.double(at: 9))
        let updatedAt = Date(timeIntervalSince1970: stmt.double(at: 10))
        return NousNode(id: id, type: type, title: title, content: content,
                        embedding: embedding, projectId: projectId,
                        isFavorite: isFavorite, mode: mode, emoji: emoji,
                        createdAt: createdAt, updatedAt: updatedAt)
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

    // MARK: - Full-Text Search

    struct FTSResult {
        let nodeId: UUID
        let snippet: String
    }

    func searchMessages(query: String, limit: Int = 10) throws -> [FTSResult] {
        let stmt = try db.prepare("""
            SELECT nodeId, snippet(messages_fts, 2, '**', '**', '…', 40)
            FROM messages_fts WHERE content MATCH ?
            ORDER BY rank LIMIT ?;
        """)
        try stmt.bind(query, at: 1)
        try stmt.bind(limit, at: 2)
        var results: [FTSResult] = []
        while try stmt.step() {
            guard let nodeIdStr = stmt.text(at: 0),
                  let nodeId = UUID(uuidString: nodeIdStr),
                  let snippet = stmt.text(at: 1) else { continue }
            results.append(FTSResult(nodeId: nodeId, snippet: snippet))
        }
        return results
    }

    // MARK: - Context Compression

    func fetchCompression(nodeId: UUID) throws -> (summary: String?, upTo: Int) {
        let stmt = try db.prepare("SELECT compressedHistory, compressedUpTo FROM nodes WHERE id=?;")
        try stmt.bind(nodeId.uuidString, at: 1)
        guard try stmt.step() else { return (nil, 0) }
        return (stmt.text(at: 0), stmt.int(at: 1))
    }

    func updateCompression(nodeId: UUID, summary: String, upTo: Int) throws {
        let stmt = try db.prepare("UPDATE nodes SET compressedHistory=?, compressedUpTo=? WHERE id=?;")
        try stmt.bind(summary, at: 1)
        try stmt.bind(upTo, at: 2)
        try stmt.bind(nodeId.uuidString, at: 3)
        try stmt.step()
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
