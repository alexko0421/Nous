import Foundation

/// One-time bootstrap: turn existing v2.1 scope blobs into canonical
/// `memory_entries` rows.
///
/// **v2.2b discipline — 1 blob = 1 entry.** No bullet-splitting or heading
/// inference. This guarantees content parity between blob and entry: for a
/// given (scope, scopeRefId), the active entry's `content` equals the blob's
/// `content`. That property is what makes v2.2b's dual-write safe to roll back
/// and sets up v2.2c's read-path cutover to be a no-op replacement.
///
/// Smarter per-fact parsing (the WIP heading-inference migrator) is deferred to
/// v2.3+ once the LLM writer itself emits structured per-fact drafts.
///
/// Idempotent via `schema_meta.memory_entries_version`. Transactional: partial
/// failure rolls back and re-runs next boot.
enum MemoryEntriesMigrator {

    static let versionKey = "memory_entries_version"
    static let targetVersion = "1"

    static func runIfNeeded(store: NodeStore) throws {
        let db = store.rawDatabase
        try db.exec("BEGIN TRANSACTION;")
        do {
            if try readVersion(db: db) == nil {
                try bootstrapEntries(from: store)
                try writeVersion(db: db, value: targetVersion)
            }
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    private static func bootstrapEntries(from store: NodeStore) throws {
        // Defensive: never double-bootstrap even if the version row was cleared
        // externally. If any entries already exist, stamp the version and exit.
        guard try store.fetchMemoryEntries().isEmpty else { return }

        if let global = try store.fetchGlobalMemory(),
           !global.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try store.insertMemoryEntry(
                MemoryEntry(
                    scope: .global,
                    scopeRefId: nil,
                    kind: .identity,
                    stability: .stable,
                    content: global.content,
                    confidence: 0.8,
                    sourceNodeIds: [],
                    createdAt: global.updatedAt,
                    updatedAt: global.updatedAt,
                    lastConfirmedAt: global.updatedAt
                )
            )
        }

        for memory in try store.fetchAllProjectMemories()
        where !memory.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try store.insertMemoryEntry(
                MemoryEntry(
                    scope: .project,
                    scopeRefId: memory.projectId,
                    kind: .thread,
                    stability: .stable,
                    content: memory.content,
                    confidence: 0.8,
                    sourceNodeIds: [],
                    createdAt: memory.updatedAt,
                    updatedAt: memory.updatedAt,
                    lastConfirmedAt: memory.updatedAt
                )
            )
        }

        for memory in try store.fetchAllConversationMemories()
        where !memory.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try store.insertMemoryEntry(
                MemoryEntry(
                    scope: .conversation,
                    scopeRefId: memory.nodeId,
                    kind: .thread,
                    stability: .temporary,
                    content: memory.content,
                    confidence: 0.8,
                    sourceNodeIds: [memory.nodeId],
                    createdAt: memory.updatedAt,
                    updatedAt: memory.updatedAt,
                    lastConfirmedAt: memory.updatedAt
                )
            )
        }
    }

    private static func readVersion(db: Database) throws -> String? {
        let stmt = try db.prepare("SELECT value FROM schema_meta WHERE key = ?;")
        try stmt.bind(versionKey, at: 1)
        guard try stmt.step() else { return nil }
        return stmt.text(at: 0)
    }

    private static func writeVersion(db: Database, value: String) throws {
        let stmt = try db.prepare("""
            INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?);
        """)
        try stmt.bind(versionKey, at: 1)
        try stmt.bind(value, at: 2)
        try stmt.step()
    }
}
