import Foundation

/// One-time migration from the pre-v2.1 single `user_memory` blob to the
/// three-scope `global_memory` / `project_memory` / `conversation_memory` layout.
///
/// Idempotent: guarded by `schema_meta.memory_version`, which lives in the SQLite
/// file and therefore survives app reinstall. Once migration has run, subsequent
/// boots short-circuit and do not touch `global_memory`.
enum MemoryV2Migrator {

    static let memoryVersionKey = "memory_version"
    static let targetVersion = "2"

    /// Run at app startup after `NodeStore` has created tables. Wraps all work
    /// in a BEGIN/COMMIT transaction so partial failure rolls back cleanly.
    ///
    /// `faultInjectAfterMigrate` is a test-only hook that fires between the
    /// row-copy step and the schema-version stamp, used by T1b to prove the
    /// ROLLBACK path actually restores pre-migration state. Production callers
    /// pass nil (the default).
    static func runIfNeeded(
        db: Database,
        faultInjectAfterMigrate: (() throws -> Void)? = nil
    ) throws {
        try db.exec("BEGIN TRANSACTION;")
        do {
            let currentVersion = try readMemoryVersion(db: db)

            if currentVersion == nil {
                // First boot on v2.1. Either fresh install (no user_memory) or
                // pre-v2.1 upgrade (user_memory exists with prior summary).
                if try tableExists(db: db, name: "user_memory") {
                    try migrateFromUserMemory(db: db)
                }
                try faultInjectAfterMigrate?()
                try writeMemoryVersion(db: db, value: targetVersion)
            }
            // currentVersion == targetVersion: already migrated, no-op.
            // currentVersion is some other value: leave alone for forward compat.

            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Parser

    /// Parses the pre-v2.1 Markdown summary and returns only the content that
    /// belongs in `global_memory`. Per v2.1 §7, `## Ongoing Threads` and
    /// `## Open Questions` are intentionally discarded because they cannot be
    /// retroactively attributed to a project or conversation.
    static func parseGlobalContent(from rawSummary: String) -> String {
        let keepHeadings: Set<String> = [
            "identity",
            "constraints",
            "preferences",
            "relationships",
        ]

        var sections: [(heading: String, body: [String])] = []
        var currentHeading: String?
        var currentBody: [String] = []

        for line in rawSummary.components(separatedBy: .newlines) {
            if let heading = line.markdownH2Heading() {
                if let prev = currentHeading {
                    sections.append((prev, currentBody))
                }
                currentHeading = heading
                currentBody = []
            } else if currentHeading != nil {
                currentBody.append(line)
            }
            // Lines before the first heading are dropped — pre-v2.1 always
            // used headed sections, so leading prose shouldn't exist.
        }
        if let last = currentHeading {
            sections.append((last, currentBody))
        }

        let kept = sections.filter { keepHeadings.contains($0.heading.lowercased()) }

        var out: [String] = []
        for section in kept {
            out.append("## \(section.heading)")
            let bodyTrimmed = section.body
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !bodyTrimmed.isEmpty {
                out.append(bodyTrimmed)
            }
        }
        return out.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private helpers

    private static func readMemoryVersion(db: Database) throws -> String? {
        let stmt = try db.prepare("SELECT value FROM schema_meta WHERE key = ?;")
        try stmt.bind(memoryVersionKey, at: 1)
        guard try stmt.step() else { return nil }
        return stmt.text(at: 0)
    }

    private static func writeMemoryVersion(db: Database, value: String) throws {
        let stmt = try db.prepare("""
            INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?);
        """)
        try stmt.bind(memoryVersionKey, at: 1)
        try stmt.bind(value, at: 2)
        try stmt.step()
    }

    private static func tableExists(db: Database, name: String) throws -> Bool {
        let stmt = try db.prepare("""
            SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;
        """)
        try stmt.bind(name, at: 1)
        return try stmt.step()
    }

    private static func migrateFromUserMemory(db: Database) throws {
        var oldSummary = ""
        do {
            let readStmt = try db.prepare("SELECT summary FROM user_memory WHERE id = 1;")
            if try readStmt.step() {
                oldSummary = readStmt.text(at: 0) ?? ""
            }
            // Release the cursor before DROP TABLE — without reset(), SQLite
            // still considers the row locked and the drop fails with
            // "database table is locked".
            readStmt.reset()
        }

        let parsed = parseGlobalContent(from: oldSummary)

        if !parsed.isEmpty {
            let writeStmt = try db.prepare("""
                INSERT OR REPLACE INTO global_memory (id, content, updatedAt)
                VALUES (1, ?, ?);
            """)
            try writeStmt.bind(parsed, at: 1)
            try writeStmt.bind(Date().timeIntervalSince1970, at: 2)
            try writeStmt.step()
        }

        try db.exec("DROP TABLE user_memory;")
    }
}

private extension String {
    /// Returns the heading text for a line like "## Identity", otherwise nil.
    func markdownH2Heading() -> String? {
        let trimmed = self.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## ") else { return nil }
        return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }
}
