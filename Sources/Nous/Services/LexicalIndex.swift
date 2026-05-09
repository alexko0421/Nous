import Foundation

/// SQLite FTS5 lexical retrieval over node titles, message contents, and
/// source chunk texts.
///
/// Per `docs/superpowers/plans/2026-05-08-memory-retrieval-multilingual-architecture.md`
/// Move 1. Provides the second retrieval lane that pairs with vector search
/// in `VectorStore.searchHybrid`. Critical for CJK queries where the
/// English-only embedding model produces noise-zone similarities.
///
/// Tokenizer: `trigram`. SQLite FTS5's trigram tokenizer indexes every
/// 3-character Unicode sequence and falls back to substring search for
/// queries shorter than 3 characters. This is the right shape for CJK
/// because `unicode61` (the default) does not segment unbroken Chinese
/// runs into useful tokens — e.g. `MATCH '室友'` against a body containing
/// `啲室友違反協定` returns 0 hits with `unicode61` but matches with `trigram`.
///
/// Schema layout — three parallel FTS5 virtual tables, one per row source:
///
/// ```
/// messages_fts(messageId, nodeId, content)         tokenize=trigram
/// nodes_fts(nodeId, type, title)                   tokenize=trigram
/// source_chunks_fts(chunkId, sourceNodeId, text)   tokenize=trigram
/// ```
///
/// Triggers (INSERT, UPDATE, DELETE) on each backing table keep the FTS
/// indexes in sync. All trigger work runs inside the same transaction as
/// the parent row write.
///
/// `messages_fts` may pre-exist from the legacy implementation that lived
/// in NodeStore.swift before commit `2c04a5f`. Old binaries created it with
/// the default `unicode61` tokenizer. `bootstrap()` detects schema drift
/// via `schema_meta.lexical_index_version` and rebuilds with `trigram` if
/// the version is missing or behind.
final class LexicalIndex {

    /// Bumped when tokenizer choice or schema shape changes. Driving a
    /// rebuild of the FTS5 virtual tables.
    /// - 1: messages_fts + nodes_fts + source_chunks_fts (trigram).
    /// - 2: adds memory_atoms_fts (trigram) for atom-level lexical recall.
    static let currentVersion: Int = 2

    private let db: Database

    init(database: Database) {
        self.db = database
    }

    // MARK: - Bootstrap

    /// Idempotent. Call from NodeStore.init() after parent tables exist.
    func bootstrap() throws {
        let storedVersion = try readSchemaVersion()
        if storedVersion < Self.currentVersion {
            try migrateToCurrentVersion(from: storedVersion)
            try writeSchemaVersion(Self.currentVersion)
        } else {
            // Schema up to date. Make sure triggers + tables exist (defensive).
            try createSchemaIfMissing()
        }
    }

    private func readSchemaVersion() throws -> Int {
        let stmt = try db.prepare("SELECT value FROM schema_meta WHERE key = 'lexical_index_version';")
        if try stmt.step() {
            return Int(stmt.text(at: 0) ?? "0") ?? 0
        }
        return 0
    }

    private func writeSchemaVersion(_ version: Int) throws {
        let stmt = try db.prepare("""
            INSERT INTO schema_meta (key, value) VALUES ('lexical_index_version', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """)
        try stmt.bind(String(version), at: 1)
        try stmt.step()
    }

    private func migrateToCurrentVersion(from storedVersion: Int) throws {
        // Drop any pre-existing FTS5 tables + triggers. SQLite tolerates
        // DROP IF NOT EXISTS but FTS5 virtual tables drop cleanly.
        for trigger in [
            "messages_fts_insert", "messages_fts_update", "messages_fts_delete",
            "nodes_fts_insert", "nodes_fts_update", "nodes_fts_delete",
            "source_chunks_fts_insert", "source_chunks_fts_update", "source_chunks_fts_delete",
            "memory_atoms_fts_insert", "memory_atoms_fts_update", "memory_atoms_fts_delete"
        ] {
            try db.exec("DROP TRIGGER IF EXISTS \(trigger);")
        }
        for table in ["messages_fts", "nodes_fts", "source_chunks_fts", "memory_atoms_fts"] {
            try db.exec("DROP TABLE IF EXISTS \(table);")
        }

        try createSchemaIfMissing()
        try backfillFromBackingTables()
    }

    private func createSchemaIfMissing() throws {
        // FTS5 virtual tables. `tokenize='trigram'` is the SQLite-bundled
        // trigram tokenizer (added in 3.34, well before macOS 26.0 SDK).
        try db.exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                messageId UNINDEXED,
                nodeId UNINDEXED,
                content,
                tokenize = 'trigram'
            );
        """)
        try db.exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(
                nodeId UNINDEXED,
                type UNINDEXED,
                title,
                tokenize = 'trigram'
            );
        """)
        try db.exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS source_chunks_fts USING fts5(
                chunkId UNINDEXED,
                sourceNodeId UNINDEXED,
                text,
                tokenize = 'trigram'
            );
        """)
        // memory_atoms_fts indexes the atom statement (the user's distilled
        // claims like "Alex prefers async-first teams"). Lexical lane lets
        // CJK paraphrase / partial substring queries hit atoms that the
        // keyword-intent classifier in MemoryQueryPlanner misses, and gives
        // a recall path that doesn't depend on having a query embedding.
        try db.exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_atoms_fts USING fts5(
                atomId UNINDEXED,
                type UNINDEXED,
                statement,
                tokenize = 'trigram'
            );
        """)

        // Triggers — keep all three FTS tables in sync with their backing
        // tables. Each trigger runs inside the same transaction as the
        // parent INSERT/UPDATE/DELETE so a crash mid-write never leaves
        // the index drifted.

        // messages_fts ↔ messages
        try db.exec("""
            CREATE TRIGGER IF NOT EXISTS messages_fts_insert AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts(messageId, nodeId, content)
                VALUES (NEW.id, NEW.nodeId, NEW.content);
            END;
        """)
        try db.exec("""
            CREATE TRIGGER IF NOT EXISTS messages_fts_update AFTER UPDATE OF content ON messages BEGIN
                DELETE FROM messages_fts WHERE messageId = OLD.id;
                INSERT INTO messages_fts(messageId, nodeId, content)
                VALUES (NEW.id, NEW.nodeId, NEW.content);
            END;
        """)
        try db.exec("""
            CREATE TRIGGER IF NOT EXISTS messages_fts_delete AFTER DELETE ON messages BEGIN
                DELETE FROM messages_fts WHERE messageId = OLD.id;
            END;
        """)

        // nodes_fts ↔ nodes (title only — content lives in messages)
        try db.exec("""
            CREATE TRIGGER IF NOT EXISTS nodes_fts_insert AFTER INSERT ON nodes BEGIN
                INSERT INTO nodes_fts(nodeId, type, title)
                VALUES (NEW.id, NEW.type, NEW.title);
            END;
        """)
        try db.exec("""
            CREATE TRIGGER IF NOT EXISTS nodes_fts_update AFTER UPDATE OF title ON nodes BEGIN
                DELETE FROM nodes_fts WHERE nodeId = OLD.id;
                INSERT INTO nodes_fts(nodeId, type, title)
                VALUES (NEW.id, NEW.type, NEW.title);
            END;
        """)
        try db.exec("""
            CREATE TRIGGER IF NOT EXISTS nodes_fts_delete AFTER DELETE ON nodes BEGIN
                DELETE FROM nodes_fts WHERE nodeId = OLD.id;
            END;
        """)

        // source_chunks_fts ↔ source_chunks
        try db.exec("""
            CREATE TRIGGER IF NOT EXISTS source_chunks_fts_insert AFTER INSERT ON source_chunks BEGIN
                INSERT INTO source_chunks_fts(chunkId, sourceNodeId, text)
                VALUES (NEW.id, NEW.sourceNodeId, NEW.text);
            END;
        """)
        try db.exec("""
            CREATE TRIGGER IF NOT EXISTS source_chunks_fts_update AFTER UPDATE OF text ON source_chunks BEGIN
                DELETE FROM source_chunks_fts WHERE chunkId = OLD.id;
                INSERT INTO source_chunks_fts(chunkId, sourceNodeId, text)
                VALUES (NEW.id, NEW.sourceNodeId, NEW.text);
            END;
        """)
        try db.exec("""
            CREATE TRIGGER IF NOT EXISTS source_chunks_fts_delete AFTER DELETE ON source_chunks BEGIN
                DELETE FROM source_chunks_fts WHERE chunkId = OLD.id;
            END;
        """)

        // memory_atoms_fts ↔ memory_atoms (statement only — type tracks the
        // atom kind for filterability but isn't searchable text)
        try db.exec("""
            CREATE TRIGGER IF NOT EXISTS memory_atoms_fts_insert AFTER INSERT ON memory_atoms BEGIN
                INSERT INTO memory_atoms_fts(atomId, type, statement)
                VALUES (NEW.id, NEW.type, NEW.statement);
            END;
        """)
        try db.exec("""
            CREATE TRIGGER IF NOT EXISTS memory_atoms_fts_update AFTER UPDATE OF statement ON memory_atoms BEGIN
                DELETE FROM memory_atoms_fts WHERE atomId = OLD.id;
                INSERT INTO memory_atoms_fts(atomId, type, statement)
                VALUES (NEW.id, NEW.type, NEW.statement);
            END;
        """)
        try db.exec("""
            CREATE TRIGGER IF NOT EXISTS memory_atoms_fts_delete AFTER DELETE ON memory_atoms BEGIN
                DELETE FROM memory_atoms_fts WHERE atomId = OLD.id;
            END;
        """)
    }

    private func backfillFromBackingTables() throws {
        try db.exec("""
            INSERT INTO messages_fts(messageId, nodeId, content)
            SELECT id, nodeId, content FROM messages;
        """)
        try db.exec("""
            INSERT INTO nodes_fts(nodeId, type, title)
            SELECT id, type, title FROM nodes;
        """)
        try db.exec("""
            INSERT INTO source_chunks_fts(chunkId, sourceNodeId, text)
            SELECT id, sourceNodeId, text FROM source_chunks;
        """)
        try db.exec("""
            INSERT INTO memory_atoms_fts(atomId, type, statement)
            SELECT id, type, statement FROM memory_atoms;
        """)
    }

    // MARK: - Search API

    /// One lexical hit, normalized BM25 score (higher = more relevant —
    /// SQLite returns negative numbers natively, we negate for clarity).
    struct LexicalHit {
        let nodeId: UUID
        /// Sub-row id when the hit is at message or chunk granularity;
        /// equals `nodeId` for title hits.
        let rowId: UUID
        let score: Double
        let kind: Kind

        enum Kind {
            case title
            case message
            case sourceChunk
            case atom
        }
    }

    /// Search node titles. Returns at most `limit` hits, sorted by descending score.
    /// The query is normalized via `QueryNormalizer.normalize`.
    func searchTitles(query: String, limit: Int = 20, excludeNodeIds: Set<UUID> = []) throws -> [LexicalHit] {
        guard limit > 0, let ftsQuery = buildFTS5Query(query) else { return [] }

        let stmt = try db.prepare("""
            SELECT nodeId, -bm25(nodes_fts) AS score
            FROM nodes_fts
            WHERE title MATCH ?
            ORDER BY bm25(nodes_fts) ASC
            LIMIT ?;
        """)
        try stmt.bind(ftsQuery, at: 1)
        try stmt.bind(limit + excludeNodeIds.count, at: 2)

        var out: [LexicalHit] = []
        out.reserveCapacity(limit)
        while try stmt.step() {
            guard let nodeIdString = stmt.text(at: 0),
                  let nodeId = UUID(uuidString: nodeIdString) else { continue }
            if excludeNodeIds.contains(nodeId) { continue }
            let score = stmt.double(at: 1)
            out.append(LexicalHit(nodeId: nodeId, rowId: nodeId, score: score, kind: .title))
            if out.count >= limit { break }
        }
        return out
    }

    /// Search message bodies. Returns at most `limit` hits per matching node
    /// (best message score per node) so a chat with many roommate messages
    /// doesn't crowd out unrelated chats.
    func searchMessages(query: String, limit: Int = 20, excludeNodeIds: Set<UUID> = []) throws -> [LexicalHit] {
        guard limit > 0, let ftsQuery = buildFTS5Query(query) else { return [] }

        // FTS5's `bm25()` cannot be wrapped in aggregate functions in a
        // GROUP BY context (`unable to use function bm25 in the requested
        // context`). Instead we pull all matching rows ordered by score
        // and dedupe by nodeId in Swift, keeping the best per node.
        let stmt = try db.prepare("""
            SELECT messageId, nodeId, -bm25(messages_fts) AS score
            FROM messages_fts
            WHERE content MATCH ?
            ORDER BY bm25(messages_fts) ASC
            LIMIT ?;
        """)
        try stmt.bind(ftsQuery, at: 1)
        // Pull a generous pool so dedupe-by-nodeId still has options.
        try stmt.bind((limit + excludeNodeIds.count) * 4, at: 2)

        var out: [LexicalHit] = []
        var seenNodeIds = Set<UUID>()
        out.reserveCapacity(limit)
        while try stmt.step() {
            guard let messageIdString = stmt.text(at: 0),
                  let messageId = UUID(uuidString: messageIdString),
                  let nodeIdString = stmt.text(at: 1),
                  let nodeId = UUID(uuidString: nodeIdString) else { continue }
            if excludeNodeIds.contains(nodeId) { continue }
            // First-seen wins (already best because ORDER BY bm25 ASC).
            guard seenNodeIds.insert(nodeId).inserted else { continue }
            let score = stmt.double(at: 2)
            out.append(LexicalHit(nodeId: nodeId, rowId: messageId, score: score, kind: .message))
            if out.count >= limit { break }
        }
        return out
    }

    /// Search source chunks. Returns at most `limit` hits per source node.
    func searchSourceChunks(query: String, limit: Int = 20, excludeSourceNodeIds: Set<UUID> = []) throws -> [LexicalHit] {
        guard limit > 0, let ftsQuery = buildFTS5Query(query) else { return [] }

        // Same dedupe-in-Swift approach as searchMessages — bm25() can
        // not be aggregated under GROUP BY in FTS5.
        let stmt = try db.prepare("""
            SELECT chunkId, sourceNodeId, -bm25(source_chunks_fts) AS score
            FROM source_chunks_fts
            WHERE text MATCH ?
            ORDER BY bm25(source_chunks_fts) ASC
            LIMIT ?;
        """)
        try stmt.bind(ftsQuery, at: 1)
        try stmt.bind((limit + excludeSourceNodeIds.count) * 4, at: 2)

        var out: [LexicalHit] = []
        var seenSourceIds = Set<UUID>()
        out.reserveCapacity(limit)
        while try stmt.step() {
            guard let chunkIdString = stmt.text(at: 0),
                  let chunkId = UUID(uuidString: chunkIdString),
                  let sourceIdString = stmt.text(at: 1),
                  let sourceNodeId = UUID(uuidString: sourceIdString) else { continue }
            if excludeSourceNodeIds.contains(sourceNodeId) { continue }
            guard seenSourceIds.insert(sourceNodeId).inserted else { continue }
            let score = stmt.double(at: 2)
            out.append(LexicalHit(nodeId: sourceNodeId, rowId: chunkId, score: score, kind: .sourceChunk))
            if out.count >= limit { break }
        }
        return out
    }

    /// Search memory_atoms statements. Returns hits where `rowId` is the
    /// atom UUID (atoms aren't node-bound, so `nodeId` mirrors `rowId` for
    /// API uniformity). Used by CitableContextBuilder to feed atom IDs into
    /// its scoring lane alongside the planner's keyword + vector recall.
    ///
    /// CJK queries hit atoms via the trigram tokenizer that the planner's
    /// English-only embedding falls down on (e.g. `面善` body containing
    /// `面善的人通常需要 social awareness` returns 0 hits with `unicode61`
    /// but matches with `trigram`).
    /// Debug helper: count rows currently in memory_atoms_fts. Useful when
    /// a unit test is asserting "lexical lane found my atom" but suspecting
    /// the trigger didn't fire / migration didn't complete.
    func debugMemoryAtomFtsRowCount() throws -> Int {
        let stmt = try db.prepare("SELECT count(*) FROM memory_atoms_fts;")
        guard try stmt.step() else { return 0 }
        return Int(stmt.double(at: 0))
    }

    /// Debug helper: read back what the trigger actually wrote. Tests assert
    /// the statement text round-tripped intact (UTF-8 / CJK preservation).
    func debugMemoryAtomFtsRows() throws -> [(atomId: String, statement: String)] {
        let stmt = try db.prepare("SELECT atomId, statement FROM memory_atoms_fts;")
        var out: [(String, String)] = []
        while try stmt.step() {
            out.append((stmt.text(at: 0) ?? "", stmt.text(at: 1) ?? ""))
        }
        return out
    }

    func searchMemoryAtoms(
        query: String,
        limit: Int = 20,
        excludeAtomIds: Set<UUID> = []
    ) throws -> [LexicalHit] {
        guard limit > 0, let ftsQuery = buildFTS5Query(query) else { return [] }

        let stmt = try db.prepare("""
            SELECT atomId, -bm25(memory_atoms_fts) AS score
            FROM memory_atoms_fts
            WHERE statement MATCH ?
            ORDER BY bm25(memory_atoms_fts) ASC
            LIMIT ?;
        """)
        try stmt.bind(ftsQuery, at: 1)
        try stmt.bind(limit + excludeAtomIds.count, at: 2)

        var out: [LexicalHit] = []
        out.reserveCapacity(limit)
        while try stmt.step() {
            guard let atomIdString = stmt.text(at: 0),
                  let atomId = UUID(uuidString: atomIdString) else { continue }
            if excludeAtomIds.contains(atomId) { continue }
            let score = stmt.double(at: 1)
            out.append(LexicalHit(nodeId: atomId, rowId: atomId, score: score, kind: .atom))
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: - Helpers

    /// Build an FTS5 MATCH query from a free-form natural language string.
    ///
    /// Strategy:
    ///   - Split the normalized query on whitespace and punctuation.
    ///   - For each whitespace-run that contains CJK characters and is at
    ///     least 4 chars long, also emit every 2-character bigram from
    ///     within the run. CJK has no whitespace tokenization, so bigrams
    ///     are how users actually retrieve "室友" out of "啲室友違反協定".
    ///   - Phrase-quote every token (escapes internal quotes; trigram
    ///     tokenizer treats phrase = substring).
    ///   - OR all phrases together.
    ///
    /// OR-fusion means recall is wide and BM25 does the ranking. The
    /// type-aware quotas in `VectorStore.searchHybrid` filter sources
    /// without lexical signal, so wide recall doesn't pollute citations.
    ///
    /// Why not AND: AND-of-tokens fails entirely on CJK queries that
    /// don't appear verbatim in the corpus. For "室友又惡咗我啊" no doc
    /// contains the whole phrase, so AND collapses to empty. OR-of-bigrams
    /// finds "室友" in any doc that has it.
    private func buildFTS5Query(_ raw: String) -> String? {
        let normalized = QueryNormalizer.normalize(raw)
        guard !normalized.isEmpty else { return nil }

        var tokens: [String] = []
        let separator: (Character) -> Bool = { ch in
            // Treat punctuation including hyphens / dashes as token boundaries.
            // FTS5 trigram tokenizer behaves erratically on phrases containing
            // mid-token punctuation (e.g. `"F-1"` errors at query time), so
            // we split on every non-letter / non-digit / non-CJK character.
            ch.isWhitespace ||
            ".,!?;:()[]{}<>\"'`/\\-–—_=+*&^%$#@~|".contains(ch)
        }
        let runs = normalized.split(whereSeparator: separator).map(String.init)
        for run in runs {
            guard isAcceptableTokenLength(run) else { continue }
            tokens.append(run)
            // For CJK-bearing runs of length ≥ 4, additionally emit every
            // 2-char bigram and every 3-char trigram. Length-3 runs are
            // already adequately handled by the run-as-token entry above.
            //
            // Why both: bigrams give substring breadth for queries that
            // share short fragments with the corpus (when FTS5's LIKE
            // fallback for short phrases works). Trigrams give exact
            // tokenizer matches against pure-CJK indexed content — the
            // FTS5 trigram tokenizer indexes 3-char windows, so a 3-char
            // query phrase can match a 3-char index trigram directly.
            // Pure-CJK 2-char queries against pure-CJK content
            // unreliably trip FTS5's LIKE fallback in our SQLite build,
            // so the trigram overlay is what makes long CJK queries hit.
            if run.count >= 4, run.contains(where: Self.isCJKScalar) {
                let chars = Array(run)
                for i in 0..<(chars.count - 1) {
                    let bigram = String(chars[i...(i + 1)])
                    // Skip ASCII-only bigrams (already covered by the
                    // run-as-token entry above; bigrams there only inflate
                    // noise like "F-" or "1 ").
                    if bigram.contains(where: Self.isCJKScalar) {
                        tokens.append(bigram)
                    }
                }
                if chars.count >= 3 {
                    for i in 0..<(chars.count - 2) {
                        let trigram = String(chars[i...(i + 2)])
                        if trigram.contains(where: Self.isCJKScalar) {
                            tokens.append(trigram)
                        }
                    }
                }
            }
        }

        let phrases: [String] = tokens.compactMap { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return escaped.isEmpty ? nil : "\"\(escaped)\""
        }
        guard !phrases.isEmpty else { return nil }
        return phrases.joined(separator: " OR ")
    }

    /// Trigram tokenizer needs at least 2 characters to derive a token,
    /// and pure-ASCII tokens shorter than 3 characters (`I`, `is`, `to`)
    /// degrade into LIKE-substring scans that produce SQLite errors and
    /// pollute results. CJK bigrams of exactly length 2 are accepted —
    /// they're how Chinese phrases like 室友 surface from corpus text.
    private func isAcceptableTokenLength(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if token.count >= 3 { return true }
        if token.count == 2, token.contains(where: Self.isCJKScalar) { return true }
        return false
    }

    private static func isCJKScalar(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            // CJK Unified Ideographs + extensions A/B/C/D/E + CJK
            // compatibility ideographs. Captures Trad + Simp.
            if (0x3400...0x4DBF).contains(scalar.value) ||
               (0x4E00...0x9FFF).contains(scalar.value) ||
               (0xF900...0xFAFF).contains(scalar.value) ||
               (0x20000...0x2A6DF).contains(scalar.value) ||
               (0x2A700...0x2EBEF).contains(scalar.value) {
                return true
            }
        }
        return false
    }
}
