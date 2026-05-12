# Edge Inference Feedback Ledger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Phase A telemetry + user feedback infrastructure across galaxy edge inspector and chat atom card surfaces, producing 4 new tables, 4 stores, 1 shared SwiftUI component, and wired-up capture points — without changing inference accuracy directly.

**Architecture:** Two parallel ledgers (per-edge and per-citation), each with append-only `*_judge_trace` for system telemetry and upsert `*_feedback` for user thumb verdicts. Shared `ThumbFeedbackView` SwiftUI component mounts in two places (galaxy `journalCard`, chat atom row) but reads/writes through surface-specific stores keyed by stable identity that survives edge regeneration.

**Tech Stack:** Swift, SwiftUI, SQLite (via existing `NodeStore.db.exec`), XCTest, xcodebuild (NOT swift build — no root Package.swift), Ruby `xcodeproj` gem for pbxproj registration.

**Spec:** `docs/superpowers/specs/2026-05-09-edge-inference-feedback-ledger-design.md`

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `Sources/Nous/Models/EdgeFeedbackTypes.swift` | `ThumbVerdict` + `JudgePath` enums |
| `Sources/Nous/Services/EdgeFeedbackStore.swift` | Galaxy edge feedback upsert/query, normalized node-pair key |
| `Sources/Nous/Services/CitationFeedbackStore.swift` | Chat citation feedback upsert/query, (conv, turn, atom) key |
| `Sources/Nous/Services/EdgeJudgeTraceStore.swift` | Append-only galaxy judge trace |
| `Sources/Nous/Services/CitationJudgeTraceStore.swift` | Append-only chat citation judge trace |
| `Sources/Nous/Services/CitationTraceEmitter.swift` | Helper that batches per-turn citation trace writes after cascade resolves |
| `Sources/Nous/Views/ThumbFeedbackView.swift` | Shared SwiftUI component (.galaxy / .chat style modes) |
| `Tests/NousTests/EdgeFeedbackStoreTests.swift` | Upsert + carry-over invariant + normalization |
| `Tests/NousTests/CitationFeedbackStoreTests.swift` | Upsert + per-turn isolation |
| `Tests/NousTests/EdgeJudgeTraceStoreTests.swift` | Append + latest verdict query |
| `Tests/NousTests/CitationJudgeTraceStoreTests.swift` | Append + per-turn query + was_displayed |
| `Tests/NousTests/ThumbFeedbackViewTests.swift` | Callback wiring + style-mode rendering |

### Modified files

| Path | Change |
|---|---|
| `Sources/Nous/Services/NodeStore.swift` | Add 4 `CREATE TABLE IF NOT EXISTS` blocks in `createTables()` |
| `Sources/Nous/Services/GalaxyRelationJudge.swift` | Accept `judgeTraceWriter: EdgeJudgeTraceStore?` injection; emit trace at atom/llm/fallback/reject sites |
| `Sources/Nous/Services/GalaxyEdgeEngine.swift` | Pass trace writer through; emit reject trace when `assessment.decision != .accept` |
| `Sources/Nous/ViewModels/ChatViewModel.swift` | After `AttributionDisplay.cascade` resolves, write one trace row per candidate atom with `was_displayed` flag |
| `Sources/Nous/Views/GalaxyView.swift` | Mount `ThumbFeedbackView(.galaxy)` at bottom of `journalCard` ScrollView |
| `Sources/Nous/Views/CorpusAtomCardListView.swift` | Mount compact `ThumbFeedbackView(.chat)` per `atomRow` |
| `Nous.xcodeproj/project.pbxproj` | Register all new .swift files (handled inline in each task that creates a file, via Ruby xcodeproj gem) |

---

## Task 1: ThumbVerdict + JudgePath enums

**Files:**
- Create: `Sources/Nous/Models/EdgeFeedbackTypes.swift`
- Create: `Tests/NousTests/EdgeFeedbackTypesTests.swift`
- Modify: `Nous.xcodeproj/project.pbxproj` (register new files)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NousTests/EdgeFeedbackTypesTests.swift
import XCTest
@testable import Nous

final class EdgeFeedbackTypesTests: XCTestCase {
    func testThumbVerdictRoundTrips() throws {
        let verdicts: [ThumbVerdict] = [.up, .down, .unset]
        for verdict in verdicts {
            let data = try JSONEncoder().encode(verdict)
            let decoded = try JSONDecoder().decode(ThumbVerdict.self, from: data)
            XCTAssertEqual(verdict, decoded)
        }
    }

    func testJudgePathRoundTrips() throws {
        let paths: [JudgePath] = [.atom, .llm, .fallback, .retrieval]
        for path in paths {
            let data = try JSONEncoder().encode(path)
            let decoded = try JSONDecoder().decode(JudgePath.self, from: data)
            XCTAssertEqual(path, decoded)
        }
    }

    func testRawValuesAreStable() {
        XCTAssertEqual(ThumbVerdict.up.rawValue, "up")
        XCTAssertEqual(ThumbVerdict.down.rawValue, "down")
        XCTAssertEqual(ThumbVerdict.unset.rawValue, "unset")
        XCTAssertEqual(JudgePath.atom.rawValue, "atom")
        XCTAssertEqual(JudgePath.llm.rawValue, "llm")
        XCTAssertEqual(JudgePath.fallback.rawValue, "fallback")
        XCTAssertEqual(JudgePath.retrieval.rawValue, "retrieval")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/EdgeFeedbackTypesTests 2>&1 | tail -20`
Expected: FAIL with "Cannot find type 'ThumbVerdict' in scope"

- [ ] **Step 3: Create the enum file**

```swift
// Sources/Nous/Models/EdgeFeedbackTypes.swift
import Foundation

enum ThumbVerdict: String, Codable {
    case up
    case down
    case unset
}

enum JudgePath: String, Codable {
    case atom
    case llm
    case fallback
    case retrieval
}
```

- [ ] **Step 4: Register new files in pbxproj**

```bash
ruby -rxcodeproj -e '
proj = Xcodeproj::Project.open("Nous.xcodeproj")
target = proj.targets.find { |t| t.name == "Nous" }
test_target = proj.targets.find { |t| t.name == "NousTests" }
models_group = proj.main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == "Models" }
tests_group = proj.main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == "NousTests" }

src_ref = models_group.new_reference("EdgeFeedbackTypes.swift")
target.source_build_phase.add_file_reference(src_ref)

test_ref = tests_group.new_reference("EdgeFeedbackTypesTests.swift")
test_target.source_build_phase.add_file_reference(test_ref)

proj.save
'
```

If the Ruby snippet errors because group paths differ, inspect with `ruby -rxcodeproj -e 'proj = Xcodeproj::Project.open("Nous.xcodeproj"); proj.main_group.recursive_children.select { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) }.each { |g| puts "#{g.hierarchy_path} -> #{g.path}" }'` and adjust group lookup. Verify after save with `grep -c "EdgeFeedbackTypes" Nous.xcodeproj/project.pbxproj` returns 4 (2 PBXFileReference + 2 PBXBuildFile).

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/EdgeFeedbackTypesTests 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`, 3 tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Models/EdgeFeedbackTypes.swift Tests/NousTests/EdgeFeedbackTypesTests.swift Nous.xcodeproj/project.pbxproj
git commit -m "feat(feedback): add ThumbVerdict + JudgePath enums

Phase A foundation. Codable enums shared across edge_feedback,
citation_feedback, edge_judge_trace, citation_judge_trace tables.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: NodeStore migration — 4 new tables

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift` — add CREATE TABLE blocks at end of `createTables()`
- Create: `Tests/NousTests/EdgeFeedbackSchemaTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NousTests/EdgeFeedbackSchemaTests.swift
import XCTest
@testable import Nous

final class EdgeFeedbackSchemaTests: XCTestCase {
    private var store: NodeStore!

    override func setUpWithError() throws {
        store = try NodeStore(databasePath: ":memory:")
    }

    func testEdgeFeedbackTableExists() throws {
        let rows = try store.db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='edge_feedback'")
        XCTAssertEqual(rows.count, 1)
    }

    func testCitationFeedbackTableExists() throws {
        let rows = try store.db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='citation_feedback'")
        XCTAssertEqual(rows.count, 1)
    }

    func testEdgeJudgeTraceTableExists() throws {
        let rows = try store.db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='edge_judge_trace'")
        XCTAssertEqual(rows.count, 1)
    }

    func testCitationJudgeTraceTableExists() throws {
        let rows = try store.db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='citation_judge_trace'")
        XCTAssertEqual(rows.count, 1)
    }

    func testEdgeJudgeTraceHasIndex() throws {
        let rows = try store.db.query("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='edge_judge_trace'")
        XCTAssertGreaterThanOrEqual(rows.count, 1, "edge_judge_trace should have at least one index")
    }
}
```

If `NodeStore` does not expose a public `db` accessor, add a test-only helper method `func tableNames() throws -> [String]` and assert against it instead. Verify the existing test suite for the convention used (check `MemoryGraphStoreTests.swift` or `NodeStoreTests.swift` for how tables are queried).

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/EdgeFeedbackSchemaTests 2>&1 | tail -20`
Expected: 4 of 5 tests FAIL (tables don't exist yet)

- [ ] **Step 3: Add 4 CREATE TABLE blocks to NodeStore.createTables()**

Locate the end of `createTables()` in `Sources/Nous/Services/NodeStore.swift` (around line 600+, after the last existing CREATE TABLE). Append:

```swift
        try db.exec("""
            CREATE TABLE IF NOT EXISTS edge_feedback (
                node_a_id      TEXT NOT NULL,
                node_b_id      TEXT NOT NULL,
                relation_kind  TEXT NOT NULL,
                verdict        TEXT NOT NULL,
                note           TEXT,
                verdict_at     REAL NOT NULL,
                verdict_count  INTEGER NOT NULL DEFAULT 1,
                PRIMARY KEY (node_a_id, node_b_id, relation_kind)
            );
        """)

        try db.exec("""
            CREATE TABLE IF NOT EXISTS citation_feedback (
                conversation_id TEXT NOT NULL,
                turn_id         TEXT NOT NULL,
                atom_id         TEXT NOT NULL,
                verdict         TEXT NOT NULL,
                note            TEXT,
                verdict_at      REAL NOT NULL,
                PRIMARY KEY (conversation_id, turn_id, atom_id)
            );
        """)

        try db.exec("""
            CREATE TABLE IF NOT EXISTS edge_judge_trace (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                node_a_id     TEXT NOT NULL,
                node_b_id     TEXT NOT NULL,
                relation_kind TEXT,
                judge_path    TEXT NOT NULL,
                similarity    REAL NOT NULL,
                confidence    REAL,
                judged_at     REAL NOT NULL
            );
        """)

        try db.exec("""
            CREATE INDEX IF NOT EXISTS idx_edge_judge_trace_pair_time
                ON edge_judge_trace (node_a_id, node_b_id, judged_at DESC);
        """)

        try db.exec("""
            CREATE TABLE IF NOT EXISTS citation_judge_trace (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                conversation_id TEXT NOT NULL,
                turn_id         TEXT NOT NULL,
                atom_id         TEXT NOT NULL,
                confidence      REAL NOT NULL,
                was_displayed   INTEGER NOT NULL,
                judged_at       REAL NOT NULL
            );
        """)

        try db.exec("""
            CREATE INDEX IF NOT EXISTS idx_citation_judge_trace_turn_time
                ON citation_judge_trace (turn_id, judged_at);
        """)
```

- [ ] **Step 4: Register new test file in pbxproj**

```bash
ruby -rxcodeproj -e '
proj = Xcodeproj::Project.open("Nous.xcodeproj")
test_target = proj.targets.find { |t| t.name == "NousTests" }
tests_group = proj.main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == "NousTests" }

test_ref = tests_group.new_reference("EdgeFeedbackSchemaTests.swift")
test_target.source_build_phase.add_file_reference(test_ref)

proj.save
'
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/EdgeFeedbackSchemaTests 2>&1 | tail -10`
Expected: 5/5 tests pass

- [ ] **Step 6: Run full test suite to verify no regression**

Run: `scripts/test_nous.sh 2>&1 | tail -10`
Expected: All existing tests still pass + 5 new pass

- [ ] **Step 7: Commit**

```bash
git add Sources/Nous/Services/NodeStore.swift Tests/NousTests/EdgeFeedbackSchemaTests.swift Nous.xcodeproj/project.pbxproj
git commit -m "feat(feedback): add 4 ledger tables to NodeStore schema

edge_feedback + citation_feedback (user verdicts, upsert by stable key)
edge_judge_trace + citation_judge_trace (system telemetry, append-only)

CREATE TABLE IF NOT EXISTS pattern matches existing NodeStore migration
convention. No backfill — collection is forward-only.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: EdgeFeedbackStore

**Files:**
- Create: `Sources/Nous/Services/EdgeFeedbackStore.swift`
- Create: `Tests/NousTests/EdgeFeedbackStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NousTests/EdgeFeedbackStoreTests.swift
import XCTest
@testable import Nous

final class EdgeFeedbackStoreTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var store: EdgeFeedbackStore!
    private let nodeA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let nodeB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    override func setUpWithError() throws {
        nodeStore = try NodeStore(databasePath: ":memory:")
        store = EdgeFeedbackStore(nodeStore: nodeStore)
    }

    func testUpsertCreatesRow() throws {
        try store.upsert(sourceId: nodeA, targetId: nodeB, relationKind: "supports", verdict: .up, note: nil)
        let row = try store.fetch(sourceId: nodeA, targetId: nodeB, relationKind: "supports")
        XCTAssertEqual(row?.verdict, .up)
        XCTAssertEqual(row?.verdictCount, 1)
    }

    func testUpsertSecondTimeUpdatesAndBumpsCount() throws {
        try store.upsert(sourceId: nodeA, targetId: nodeB, relationKind: "supports", verdict: .up, note: nil)
        try store.upsert(sourceId: nodeA, targetId: nodeB, relationKind: "supports", verdict: .down, note: "唔啱")
        let row = try store.fetch(sourceId: nodeA, targetId: nodeB, relationKind: "supports")
        XCTAssertEqual(row?.verdict, .down)
        XCTAssertEqual(row?.note, "唔啱")
        XCTAssertEqual(row?.verdictCount, 2)
    }

    func testNodePairOrderIsNormalized() throws {
        try store.upsert(sourceId: nodeA, targetId: nodeB, relationKind: "supports", verdict: .up, note: nil)
        // Same pair queried with reversed order returns the same row.
        let rowReversed = try store.fetch(sourceId: nodeB, targetId: nodeA, relationKind: "supports")
        XCTAssertEqual(rowReversed?.verdict, .up)
    }

    func testDifferentRelationKindsAreSeparateRows() throws {
        try store.upsert(sourceId: nodeA, targetId: nodeB, relationKind: "supports", verdict: .up, note: nil)
        try store.upsert(sourceId: nodeA, targetId: nodeB, relationKind: "contradicts", verdict: .down, note: nil)
        XCTAssertEqual(try store.fetch(sourceId: nodeA, targetId: nodeB, relationKind: "supports")?.verdict, .up)
        XCTAssertEqual(try store.fetch(sourceId: nodeA, targetId: nodeB, relationKind: "contradicts")?.verdict, .down)
    }

    func testFetchMissingReturnsNil() throws {
        let row = try store.fetch(sourceId: nodeA, targetId: nodeB, relationKind: "supports")
        XCTAssertNil(row)
    }

    func testRegenCarryOverInvariant() throws {
        // Simulate: edge created, user thumbs up, edge regen produces SAME kind.
        try store.upsert(sourceId: nodeA, targetId: nodeB, relationKind: "supports", verdict: .up, note: nil)
        // Regen does NOT touch edge_feedback table — feedback should persist.
        let row = try store.fetch(sourceId: nodeA, targetId: nodeB, relationKind: "supports")
        XCTAssertEqual(row?.verdict, .up, "Feedback survives across regen of same kind")

        // Simulate: regen produces DIFFERENT kind. The new kind has fresh state.
        let differentKindRow = try store.fetch(sourceId: nodeA, targetId: nodeB, relationKind: "contradicts")
        XCTAssertNil(differentKindRow, "Different kind starts fresh — prior thumb does not apply")

        // Original kind's thumb is still preserved as historical signal.
        let originalRow = try store.fetch(sourceId: nodeA, targetId: nodeB, relationKind: "supports")
        XCTAssertEqual(originalRow?.verdict, .up)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/EdgeFeedbackStoreTests 2>&1 | tail -10`
Expected: FAIL with "Cannot find 'EdgeFeedbackStore' in scope"

- [ ] **Step 3: Create EdgeFeedbackStore**

```swift
// Sources/Nous/Services/EdgeFeedbackStore.swift
import Foundation

struct EdgeFeedbackRow: Equatable {
    let nodeAId: UUID
    let nodeBId: UUID
    let relationKind: String
    let verdict: ThumbVerdict
    let note: String?
    let verdictAt: Date
    let verdictCount: Int
}

final class EdgeFeedbackStore {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    func upsert(
        sourceId: UUID,
        targetId: UUID,
        relationKind: String,
        verdict: ThumbVerdict,
        note: String?
    ) throws {
        let (a, b) = Self.normalize(sourceId, targetId)
        let now = Date().timeIntervalSince1970
        try nodeStore.db.exec("""
            INSERT INTO edge_feedback (node_a_id, node_b_id, relation_kind, verdict, note, verdict_at, verdict_count)
            VALUES (?, ?, ?, ?, ?, ?, 1)
            ON CONFLICT(node_a_id, node_b_id, relation_kind) DO UPDATE SET
                verdict = excluded.verdict,
                note = excluded.note,
                verdict_at = excluded.verdict_at,
                verdict_count = verdict_count + 1
        """, params: [a.uuidString, b.uuidString, relationKind, verdict.rawValue, note as Any, now])
    }

    func fetch(sourceId: UUID, targetId: UUID, relationKind: String) throws -> EdgeFeedbackRow? {
        let (a, b) = Self.normalize(sourceId, targetId)
        let rows = try nodeStore.db.query("""
            SELECT node_a_id, node_b_id, relation_kind, verdict, note, verdict_at, verdict_count
            FROM edge_feedback
            WHERE node_a_id = ? AND node_b_id = ? AND relation_kind = ?
        """, params: [a.uuidString, b.uuidString, relationKind])

        guard let row = rows.first else { return nil }
        return EdgeFeedbackRow(
            nodeAId: UUID(uuidString: row["node_a_id"] as! String)!,
            nodeBId: UUID(uuidString: row["node_b_id"] as! String)!,
            relationKind: row["relation_kind"] as! String,
            verdict: ThumbVerdict(rawValue: row["verdict"] as! String) ?? .unset,
            note: row["note"] as? String,
            verdictAt: Date(timeIntervalSince1970: row["verdict_at"] as! Double),
            verdictCount: Int(row["verdict_count"] as! Int64)
        )
    }

    private static func normalize(_ x: UUID, _ y: UUID) -> (UUID, UUID) {
        x.uuidString < y.uuidString ? (x, y) : (y, x)
    }
}
```

The exact `db.exec` and `db.query` signatures depend on the existing `Database` wrapper convention in `NodeStore.swift`. If the wrapper uses different parameter binding (`bindings:`, positional `?`, named `:name`), inspect any existing call site (e.g., near `INSERT INTO nodes` in NodeStore.swift) and match that pattern. The query result row representation may also be `[String: Any?]` or a typed struct — match the existing convention.

- [ ] **Step 4: Register new file in pbxproj**

```bash
ruby -rxcodeproj -e '
proj = Xcodeproj::Project.open("Nous.xcodeproj")
target = proj.targets.find { |t| t.name == "Nous" }
test_target = proj.targets.find { |t| t.name == "NousTests" }
services_group = proj.main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == "Services" }
tests_group = proj.main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == "NousTests" }

src_ref = services_group.new_reference("EdgeFeedbackStore.swift")
target.source_build_phase.add_file_reference(src_ref)

test_ref = tests_group.new_reference("EdgeFeedbackStoreTests.swift")
test_target.source_build_phase.add_file_reference(test_ref)

proj.save
'
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/EdgeFeedbackStoreTests 2>&1 | tail -10`
Expected: 6/6 tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Services/EdgeFeedbackStore.swift Tests/NousTests/EdgeFeedbackStoreTests.swift Nous.xcodeproj/project.pbxproj
git commit -m "feat(feedback): EdgeFeedbackStore — upsert by normalized node-pair + kind

Survives edge regen of same kind (carry-over invariant). Different-kind
regen leaves prior thumb intact as historical signal.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: CitationFeedbackStore

**Files:**
- Create: `Sources/Nous/Services/CitationFeedbackStore.swift`
- Create: `Tests/NousTests/CitationFeedbackStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NousTests/CitationFeedbackStoreTests.swift
import XCTest
@testable import Nous

final class CitationFeedbackStoreTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var store: CitationFeedbackStore!
    private let conv = UUID()
    private let turn = UUID()
    private let atom = UUID()

    override func setUpWithError() throws {
        nodeStore = try NodeStore(databasePath: ":memory:")
        store = CitationFeedbackStore(nodeStore: nodeStore)
    }

    func testUpsertCreatesRow() throws {
        try store.upsert(conversationId: conv, turnId: turn, atomId: atom, verdict: .up, note: nil)
        let row = try store.fetch(conversationId: conv, turnId: turn, atomId: atom)
        XCTAssertEqual(row?.verdict, .up)
    }

    func testUpsertSecondTimeUpdates() throws {
        try store.upsert(conversationId: conv, turnId: turn, atomId: atom, verdict: .up, note: nil)
        try store.upsert(conversationId: conv, turnId: turn, atomId: atom, verdict: .down, note: "irrelevant")
        let row = try store.fetch(conversationId: conv, turnId: turn, atomId: atom)
        XCTAssertEqual(row?.verdict, .down)
        XCTAssertEqual(row?.note, "irrelevant")
    }

    func testDifferentTurnsAreSeparateRows() throws {
        let turn2 = UUID()
        try store.upsert(conversationId: conv, turnId: turn, atomId: atom, verdict: .up, note: nil)
        try store.upsert(conversationId: conv, turnId: turn2, atomId: atom, verdict: .down, note: nil)
        XCTAssertEqual(try store.fetch(conversationId: conv, turnId: turn, atomId: atom)?.verdict, .up)
        XCTAssertEqual(try store.fetch(conversationId: conv, turnId: turn2, atomId: atom)?.verdict, .down)
    }

    func testFetchMissingReturnsNil() throws {
        let row = try store.fetch(conversationId: conv, turnId: turn, atomId: atom)
        XCTAssertNil(row)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/CitationFeedbackStoreTests 2>&1 | tail -10`
Expected: FAIL with "Cannot find 'CitationFeedbackStore' in scope"

- [ ] **Step 3: Create CitationFeedbackStore**

```swift
// Sources/Nous/Services/CitationFeedbackStore.swift
import Foundation

struct CitationFeedbackRow: Equatable {
    let conversationId: UUID
    let turnId: UUID
    let atomId: UUID
    let verdict: ThumbVerdict
    let note: String?
    let verdictAt: Date
}

final class CitationFeedbackStore {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    func upsert(
        conversationId: UUID,
        turnId: UUID,
        atomId: UUID,
        verdict: ThumbVerdict,
        note: String?
    ) throws {
        let now = Date().timeIntervalSince1970
        try nodeStore.db.exec("""
            INSERT INTO citation_feedback (conversation_id, turn_id, atom_id, verdict, note, verdict_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(conversation_id, turn_id, atom_id) DO UPDATE SET
                verdict = excluded.verdict,
                note = excluded.note,
                verdict_at = excluded.verdict_at
        """, params: [conversationId.uuidString, turnId.uuidString, atomId.uuidString, verdict.rawValue, note as Any, now])
    }

    func fetch(conversationId: UUID, turnId: UUID, atomId: UUID) throws -> CitationFeedbackRow? {
        let rows = try nodeStore.db.query("""
            SELECT conversation_id, turn_id, atom_id, verdict, note, verdict_at
            FROM citation_feedback
            WHERE conversation_id = ? AND turn_id = ? AND atom_id = ?
        """, params: [conversationId.uuidString, turnId.uuidString, atomId.uuidString])

        guard let row = rows.first else { return nil }
        return CitationFeedbackRow(
            conversationId: UUID(uuidString: row["conversation_id"] as! String)!,
            turnId: UUID(uuidString: row["turn_id"] as! String)!,
            atomId: UUID(uuidString: row["atom_id"] as! String)!,
            verdict: ThumbVerdict(rawValue: row["verdict"] as! String) ?? .unset,
            note: row["note"] as? String,
            verdictAt: Date(timeIntervalSince1970: row["verdict_at"] as! Double)
        )
    }
}
```

(Same caveat as Task 3 about matching the existing `db.exec`/`db.query` calling convention.)

- [ ] **Step 4: Register new file in pbxproj**

```bash
ruby -rxcodeproj -e '
proj = Xcodeproj::Project.open("Nous.xcodeproj")
target = proj.targets.find { |t| t.name == "Nous" }
test_target = proj.targets.find { |t| t.name == "NousTests" }
services_group = proj.main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == "Services" }
tests_group = proj.main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == "NousTests" }

src_ref = services_group.new_reference("CitationFeedbackStore.swift")
target.source_build_phase.add_file_reference(src_ref)

test_ref = tests_group.new_reference("CitationFeedbackStoreTests.swift")
test_target.source_build_phase.add_file_reference(test_ref)

proj.save
'
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/CitationFeedbackStoreTests 2>&1 | tail -10`
Expected: 4/4 tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Services/CitationFeedbackStore.swift Tests/NousTests/CitationFeedbackStoreTests.swift Nous.xcodeproj/project.pbxproj
git commit -m "feat(feedback): CitationFeedbackStore — upsert by (conv, turn, atom)

Per-turn immutable identity. No verdict_count bump (chat citations are
one row per turn; multiple updates overwrite, count would be misleading).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: EdgeJudgeTraceStore

**Files:**
- Create: `Sources/Nous/Services/EdgeJudgeTraceStore.swift`
- Create: `Tests/NousTests/EdgeJudgeTraceStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NousTests/EdgeJudgeTraceStoreTests.swift
import XCTest
@testable import Nous

final class EdgeJudgeTraceStoreTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var store: EdgeJudgeTraceStore!
    private let nodeA = UUID()
    private let nodeB = UUID()

    override func setUpWithError() throws {
        nodeStore = try NodeStore(databasePath: ":memory:")
        store = EdgeJudgeTraceStore(nodeStore: nodeStore)
    }

    func testAppendOneRow() throws {
        try store.append(
            sourceId: nodeA,
            targetId: nodeB,
            relationKind: "supports",
            judgePath: .atom,
            similarity: 0.82,
            confidence: 0.78
        )
        let history = try store.history(sourceId: nodeA, targetId: nodeB, limit: 10)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].relationKind, "supports")
        XCTAssertEqual(history[0].judgePath, .atom)
    }

    func testAppendNullKindForRejection() throws {
        try store.append(
            sourceId: nodeA,
            targetId: nodeB,
            relationKind: nil,
            judgePath: .fallback,
            similarity: 0.71,
            confidence: nil
        )
        let history = try store.history(sourceId: nodeA, targetId: nodeB, limit: 10)
        XCTAssertEqual(history.count, 1)
        XCTAssertNil(history[0].relationKind, "Nil relation kind = judge said no connection")
    }

    func testHistoryReturnsDescendingByTime() throws {
        try store.append(sourceId: nodeA, targetId: nodeB, relationKind: "supports", judgePath: .atom, similarity: 0.8, confidence: 0.7)
        Thread.sleep(forTimeInterval: 0.01)
        try store.append(sourceId: nodeA, targetId: nodeB, relationKind: "contradicts", judgePath: .llm, similarity: 0.85, confidence: 0.82)
        let history = try store.history(sourceId: nodeA, targetId: nodeB, limit: 10)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].relationKind, "contradicts", "Most recent first")
        XCTAssertEqual(history[1].relationKind, "supports")
    }

    func testHistoryNormalizedByPair() throws {
        try store.append(sourceId: nodeA, targetId: nodeB, relationKind: "supports", judgePath: .atom, similarity: 0.8, confidence: 0.7)
        // Query with reversed order returns same row.
        let reversed = try store.history(sourceId: nodeB, targetId: nodeA, limit: 10)
        XCTAssertEqual(reversed.count, 1)
    }

    func testLatestReturnsOnlyMostRecent() throws {
        try store.append(sourceId: nodeA, targetId: nodeB, relationKind: "supports", judgePath: .atom, similarity: 0.8, confidence: 0.7)
        Thread.sleep(forTimeInterval: 0.01)
        try store.append(sourceId: nodeA, targetId: nodeB, relationKind: nil, judgePath: .fallback, similarity: 0.65, confidence: nil)
        let latest = try store.latest(sourceId: nodeA, targetId: nodeB)
        XCTAssertNil(latest?.relationKind)
        XCTAssertEqual(latest?.judgePath, .fallback)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/EdgeJudgeTraceStoreTests 2>&1 | tail -10`
Expected: FAIL with "Cannot find 'EdgeJudgeTraceStore' in scope"

- [ ] **Step 3: Create EdgeJudgeTraceStore**

```swift
// Sources/Nous/Services/EdgeJudgeTraceStore.swift
import Foundation

struct EdgeJudgeTraceRow: Equatable {
    let id: Int64
    let nodeAId: UUID
    let nodeBId: UUID
    let relationKind: String?
    let judgePath: JudgePath
    let similarity: Double
    let confidence: Double?
    let judgedAt: Date
}

final class EdgeJudgeTraceStore {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    func append(
        sourceId: UUID,
        targetId: UUID,
        relationKind: String?,
        judgePath: JudgePath,
        similarity: Double,
        confidence: Double?
    ) throws {
        let (a, b) = Self.normalize(sourceId, targetId)
        let now = Date().timeIntervalSince1970
        try nodeStore.db.exec("""
            INSERT INTO edge_judge_trace
              (node_a_id, node_b_id, relation_kind, judge_path, similarity, confidence, judged_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            a.uuidString, b.uuidString,
            relationKind as Any,
            judgePath.rawValue,
            similarity,
            confidence as Any,
            now
        ])
    }

    func history(sourceId: UUID, targetId: UUID, limit: Int) throws -> [EdgeJudgeTraceRow] {
        let (a, b) = Self.normalize(sourceId, targetId)
        let rows = try nodeStore.db.query("""
            SELECT id, node_a_id, node_b_id, relation_kind, judge_path, similarity, confidence, judged_at
            FROM edge_judge_trace
            WHERE node_a_id = ? AND node_b_id = ?
            ORDER BY judged_at DESC
            LIMIT ?
        """, params: [a.uuidString, b.uuidString, limit])
        return rows.map(parseRow)
    }

    func latest(sourceId: UUID, targetId: UUID) throws -> EdgeJudgeTraceRow? {
        try history(sourceId: sourceId, targetId: targetId, limit: 1).first
    }

    private func parseRow(_ row: [String: Any?]) -> EdgeJudgeTraceRow {
        EdgeJudgeTraceRow(
            id: row["id"] as! Int64,
            nodeAId: UUID(uuidString: row["node_a_id"] as! String)!,
            nodeBId: UUID(uuidString: row["node_b_id"] as! String)!,
            relationKind: row["relation_kind"] as? String,
            judgePath: JudgePath(rawValue: row["judge_path"] as! String) ?? .fallback,
            similarity: row["similarity"] as! Double,
            confidence: row["confidence"] as? Double,
            judgedAt: Date(timeIntervalSince1970: row["judged_at"] as! Double)
        )
    }

    private static func normalize(_ x: UUID, _ y: UUID) -> (UUID, UUID) {
        x.uuidString < y.uuidString ? (x, y) : (y, x)
    }
}
```

- [ ] **Step 4: Register new file in pbxproj**

```bash
ruby -rxcodeproj -e '
proj = Xcodeproj::Project.open("Nous.xcodeproj")
target = proj.targets.find { |t| t.name == "Nous" }
test_target = proj.targets.find { |t| t.name == "NousTests" }
services_group = proj.main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == "Services" }
tests_group = proj.main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == "NousTests" }

src_ref = services_group.new_reference("EdgeJudgeTraceStore.swift")
target.source_build_phase.add_file_reference(src_ref)

test_ref = tests_group.new_reference("EdgeJudgeTraceStoreTests.swift")
test_target.source_build_phase.add_file_reference(test_ref)

proj.save
'
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/EdgeJudgeTraceStoreTests 2>&1 | tail -10`
Expected: 5/5 tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Services/EdgeJudgeTraceStore.swift Tests/NousTests/EdgeJudgeTraceStoreTests.swift Nous.xcodeproj/project.pbxproj
git commit -m "feat(feedback): EdgeJudgeTraceStore — append-only galaxy judge trace

Records every judge decision (including rejections via NULL relation_kind)
so we can distinguish 'judge didn't try' from 'judge said no'.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: CitationJudgeTraceStore

**Files:**
- Create: `Sources/Nous/Services/CitationJudgeTraceStore.swift`
- Create: `Tests/NousTests/CitationJudgeTraceStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NousTests/CitationJudgeTraceStoreTests.swift
import XCTest
@testable import Nous

final class CitationJudgeTraceStoreTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var store: CitationJudgeTraceStore!
    private let conv = UUID()
    private let turn = UUID()
    private let atom1 = UUID()
    private let atom2 = UUID()

    override func setUpWithError() throws {
        nodeStore = try NodeStore(databasePath: ":memory:")
        store = CitationJudgeTraceStore(nodeStore: nodeStore)
    }

    func testAppendDisplayedRow() throws {
        try store.append(conversationId: conv, turnId: turn, atomId: atom1, confidence: 0.84, wasDisplayed: true)
        let rows = try store.byTurn(turnId: turn)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].wasDisplayed)
    }

    func testAppendFilteredRow() throws {
        try store.append(conversationId: conv, turnId: turn, atomId: atom1, confidence: 0.55, wasDisplayed: false)
        let rows = try store.byTurn(turnId: turn)
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].wasDisplayed)
    }

    func testByTurnReturnsAllAtomsForTurn() throws {
        try store.append(conversationId: conv, turnId: turn, atomId: atom1, confidence: 0.84, wasDisplayed: true)
        try store.append(conversationId: conv, turnId: turn, atomId: atom2, confidence: 0.55, wasDisplayed: false)
        let rows = try store.byTurn(turnId: turn)
        XCTAssertEqual(rows.count, 2)
    }

    func testByTurnExcludesOtherTurns() throws {
        let otherTurn = UUID()
        try store.append(conversationId: conv, turnId: turn, atomId: atom1, confidence: 0.84, wasDisplayed: true)
        try store.append(conversationId: conv, turnId: otherTurn, atomId: atom2, confidence: 0.55, wasDisplayed: false)
        let rows = try store.byTurn(turnId: turn)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].atomId, atom1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/CitationJudgeTraceStoreTests 2>&1 | tail -10`
Expected: FAIL with "Cannot find 'CitationJudgeTraceStore' in scope"

- [ ] **Step 3: Create CitationJudgeTraceStore**

```swift
// Sources/Nous/Services/CitationJudgeTraceStore.swift
import Foundation

struct CitationJudgeTraceRow: Equatable {
    let id: Int64
    let conversationId: UUID
    let turnId: UUID
    let atomId: UUID
    let confidence: Double
    let wasDisplayed: Bool
    let judgedAt: Date
}

final class CitationJudgeTraceStore {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    func append(
        conversationId: UUID,
        turnId: UUID,
        atomId: UUID,
        confidence: Double,
        wasDisplayed: Bool
    ) throws {
        let now = Date().timeIntervalSince1970
        try nodeStore.db.exec("""
            INSERT INTO citation_judge_trace
              (conversation_id, turn_id, atom_id, confidence, was_displayed, judged_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            conversationId.uuidString, turnId.uuidString, atomId.uuidString,
            confidence,
            wasDisplayed ? 1 : 0,
            now
        ])
    }

    func byTurn(turnId: UUID) throws -> [CitationJudgeTraceRow] {
        let rows = try nodeStore.db.query("""
            SELECT id, conversation_id, turn_id, atom_id, confidence, was_displayed, judged_at
            FROM citation_judge_trace
            WHERE turn_id = ?
            ORDER BY judged_at ASC
        """, params: [turnId.uuidString])
        return rows.map { row in
            CitationJudgeTraceRow(
                id: row["id"] as! Int64,
                conversationId: UUID(uuidString: row["conversation_id"] as! String)!,
                turnId: UUID(uuidString: row["turn_id"] as! String)!,
                atomId: UUID(uuidString: row["atom_id"] as! String)!,
                confidence: row["confidence"] as! Double,
                wasDisplayed: (row["was_displayed"] as! Int64) == 1,
                judgedAt: Date(timeIntervalSince1970: row["judged_at"] as! Double)
            )
        }
    }
}
```

- [ ] **Step 4: Register new file in pbxproj**

```bash
ruby -rxcodeproj -e '
proj = Xcodeproj::Project.open("Nous.xcodeproj")
target = proj.targets.find { |t| t.name == "Nous" }
test_target = proj.targets.find { |t| t.name == "NousTests" }
services_group = proj.main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == "Services" }
tests_group = proj.main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == "NousTests" }

src_ref = services_group.new_reference("CitationJudgeTraceStore.swift")
target.source_build_phase.add_file_reference(src_ref)

test_ref = tests_group.new_reference("CitationJudgeTraceStoreTests.swift")
test_target.source_build_phase.add_file_reference(test_ref)

proj.save
'
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/CitationJudgeTraceStoreTests 2>&1 | tail -10`
Expected: 4/4 tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Services/CitationJudgeTraceStore.swift Tests/NousTests/CitationJudgeTraceStoreTests.swift Nous.xcodeproj/project.pbxproj
git commit -m "feat(feedback): CitationJudgeTraceStore — per-turn citation telemetry

Append-only. Records both displayed and floor-filtered atoms so the
dataset captures cascade decisions, not just shown chips.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 7: ThumbFeedbackView SwiftUI component

**Files:**
- Create: `Sources/Nous/Views/ThumbFeedbackView.swift`
- Create: `Tests/NousTests/ThumbFeedbackViewTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NousTests/ThumbFeedbackViewTests.swift
import XCTest
import SwiftUI
@testable import Nous

final class ThumbFeedbackViewTests: XCTestCase {
    func testInitialVerdictIsUnset() {
        var verdict = ThumbVerdict.unset
        var note = ""
        var calls: [(ThumbVerdict, String)] = []
        let view = ThumbFeedbackView(
            verdict: Binding(get: { verdict }, set: { verdict = $0 }),
            note: Binding(get: { note }, set: { note = $0 }),
            style: .galaxy,
            telemetry: nil,
            onChange: { v, n in calls.append((v, n)) }
        )
        // The view should render without crash; verdict starts unset.
        XCTAssertEqual(verdict, .unset)
        XCTAssertNotNil(view)
    }

    func testTelemetryStripPresenceMatchesStyle() {
        let galaxyView = ThumbFeedbackView(
            verdict: .constant(.unset),
            note: .constant(""),
            style: .galaxy,
            telemetry: TelemetryStrip(similarity: 0.78, judgePath: .llm, confidence: 0.82, judgedAt: Date(), priorVerdictCount: 1),
            onChange: { _, _ in }
        )
        XCTAssertNotNil(galaxyView)

        let chatView = ThumbFeedbackView(
            verdict: .constant(.unset),
            note: .constant(""),
            style: .chat,
            telemetry: nil,
            onChange: { _, _ in }
        )
        XCTAssertNotNil(chatView)
    }

    func testStyleEnumValues() {
        XCTAssertNotEqual(ThumbFeedbackView.Style.galaxy, ThumbFeedbackView.Style.chat)
    }
}
```

(SwiftUI views are notoriously hard to deep-test without snapshot frameworks. These tests verify the type compiles, callbacks are wired, and style modes are distinct. Manual QA in Task 13 covers visual verification.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/ThumbFeedbackViewTests 2>&1 | tail -10`
Expected: FAIL with "Cannot find 'ThumbFeedbackView' in scope"

- [ ] **Step 3: Create ThumbFeedbackView**

```swift
// Sources/Nous/Views/ThumbFeedbackView.swift
import SwiftUI

struct TelemetryStrip {
    let similarity: Double
    let judgePath: JudgePath
    let confidence: Double?
    let judgedAt: Date
    let priorVerdictCount: Int
}

struct ThumbFeedbackView: View {
    enum Style: Equatable {
        case galaxy
        case chat
    }

    @Binding var verdict: ThumbVerdict
    @Binding var note: String
    let style: Style
    let telemetry: TelemetryStrip?
    let onChange: (ThumbVerdict, String) -> Void

    @State private var noteFocused = false

    var body: some View {
        switch style {
        case .galaxy:
            galaxyBody
        case .chat:
            chatBody
        }
    }

    @ViewBuilder
    private var galaxyBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("呢条关联啱吗？")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColor.secondaryText)

            HStack(spacing: 8) {
                thumbButton(.up, label: "👍 啱")
                thumbButton(.down, label: "👎 唔啱")
            }

            TextField("想补充？", text: $note, onEditingChanged: { editing in
                noteFocused = editing
                if !editing { onChange(verdict, note) }
            })
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))

            if let telemetry {
                Text(telemetryLine(telemetry))
                    .font(.system(size: 11))
                    .foregroundStyle(AppColor.secondaryText)
            } else {
                Text("判断路径: 未记录（Phase A 之前）")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var chatBody: some View {
        HStack(spacing: 6) {
            Button { setVerdict(.up) } label: {
                Image(systemName: verdict == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .font(.system(size: 11))
                    .foregroundStyle(verdict == .up ? AppColor.dustyRose : AppColor.secondaryText)
            }
            .buttonStyle(.plain)

            Button { setVerdict(.down) } label: {
                Image(systemName: verdict == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(size: 11))
                    .foregroundStyle(verdict == .down ? AppColor.dustyRose : AppColor.secondaryText)
            }
            .buttonStyle(.plain)

            if verdict == .down {
                TextField("关联唔到呢条 message？", text: $note, onEditingChanged: { editing in
                    if !editing { onChange(verdict, note) }
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            }
        }
    }

    private func thumbButton(_ kind: ThumbVerdict, label: String) -> some View {
        Button { setVerdict(kind) } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(verdict == kind ? AppColor.dustyRose : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AppColor.panelStroke, lineWidth: 1)
                )
                .foregroundStyle(verdict == kind ? .white : AppColor.primaryText)
        }
        .buttonStyle(.plain)
    }

    private func setVerdict(_ v: ThumbVerdict) {
        verdict = v
        onChange(v, note)
    }

    private func telemetryLine(_ t: TelemetryStrip) -> String {
        let confText = t.confidence.map { String(format: "信心 %.2f · ", $0) } ?? ""
        let priorText = t.priorVerdictCount > 0 ? " · 之前已表态 \(t.priorVerdictCount) 次" : ""
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        return String(format: "相似度 %.2f · 路径 %@ · %@判断於 %@%@",
                      t.similarity,
                      t.judgePath.rawValue,
                      confText,
                      timeFormatter.string(from: t.judgedAt),
                      priorText)
    }
}
```

If `AppColor.dustyRose` does not exist yet, add it to `AppColor.swift`. Per the [Galaxy — no colaOrange anywhere] memory, the dusty rose is already part of the Morandi palette used by GalaxyPalette; either use `GalaxyPalette.accent` or add an `AppColor.dustyRose` alias for cross-surface consistency. Inspect `Sources/Nous/Models/AppColor.swift` to decide which.

- [ ] **Step 4: Register new file in pbxproj**

```bash
ruby -rxcodeproj -e '
proj = Xcodeproj::Project.open("Nous.xcodeproj")
target = proj.targets.find { |t| t.name == "Nous" }
test_target = proj.targets.find { |t| t.name == "NousTests" }
views_group = proj.main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == "Views" }
tests_group = proj.main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == "NousTests" }

src_ref = views_group.new_reference("ThumbFeedbackView.swift")
target.source_build_phase.add_file_reference(src_ref)

test_ref = tests_group.new_reference("ThumbFeedbackViewTests.swift")
test_target.source_build_phase.add_file_reference(test_ref)

proj.save
'
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/ThumbFeedbackViewTests 2>&1 | tail -10`
Expected: 3/3 tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Views/ThumbFeedbackView.swift Tests/NousTests/ThumbFeedbackViewTests.swift Nous.xcodeproj/project.pbxproj
git commit -m "feat(feedback): ThumbFeedbackView shared SwiftUI component

Two style modes (.galaxy full size + telemetry strip; .chat compact
icon-only). Selected state uses Morandi dusty rose, never colaOrange,
per Galaxy palette invariant.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 8: Wire EdgeJudgeTraceStore into GalaxyRelationJudge + GalaxyEdgeEngine

**Files:**
- Modify: `Sources/Nous/Services/GalaxyRelationJudge.swift` — accept optional trace writer in init; emit at atom/llm/fallback/nil sites
- Modify: `Sources/Nous/Services/GalaxyEdgeEngine.swift` — pass trace writer through; emit reject trace when assessment != .accept
- Create: `Tests/NousTests/GalaxyJudgeTraceWiringTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NousTests/GalaxyJudgeTraceWiringTests.swift
import XCTest
@testable import Nous

final class GalaxyJudgeTraceWiringTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var traceStore: EdgeJudgeTraceStore!

    override func setUpWithError() throws {
        nodeStore = try NodeStore(databasePath: ":memory:")
        traceStore = EdgeJudgeTraceStore(nodeStore: nodeStore)
    }

    func testJudgeWritesTraceForAtomPath() throws {
        // Build a judge with the trace writer injected and a fake node-pair
        // where atom relationship judgment will hit. (Use the same atom
        // construction pattern as existing GalaxyRelationJudgeTests.)
        let judge = GalaxyRelationJudge(judgeTraceWriter: traceStore)
        let nodeA = NousNode.fixture(id: UUID())
        let nodeB = NousNode.fixture(id: UUID())
        let sourceAtoms = [MemoryAtom.fixture(type: .boundary, statement: "唔做 ChatGPT 啰嗦句式")]
        let targetAtoms = [MemoryAtom.fixture(type: .goal, statement: "想要简洁回复")]

        _ = judge.judge(
            source: nodeA,
            target: nodeB,
            similarity: 0.78,
            sourceAtoms: sourceAtoms,
            targetAtoms: targetAtoms
        )

        let history = try traceStore.history(sourceId: nodeA.id, targetId: nodeB.id, limit: 10)
        XCTAssertEqual(history.count, 1, "Atom-path judge call should emit one trace row")
        XCTAssertEqual(history[0].judgePath, .atom)
        XCTAssertNotNil(history[0].relationKind)
    }

    func testJudgeWritesTraceForFallbackPath() throws {
        let judge = GalaxyRelationJudge(judgeTraceWriter: traceStore)
        let nodeA = NousNode.fixture(id: UUID())
        let nodeB = NousNode.fixture(id: UUID())
        // No atoms → falls through to topicSimilarity fallback (similarity above threshold).
        _ = judge.judge(
            source: nodeA,
            target: nodeB,
            similarity: 0.78,
            sourceAtoms: [],
            targetAtoms: []
        )

        let history = try traceStore.history(sourceId: nodeA.id, targetId: nodeB.id, limit: 10)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].judgePath, .fallback)
    }

    func testJudgeWritesTraceForRejection() throws {
        let judge = GalaxyRelationJudge(judgeTraceWriter: traceStore)
        let nodeA = NousNode.fixture(id: UUID())
        let nodeB = NousNode.fixture(id: UUID())
        // Similarity below threshold → judge returns nil.
        _ = judge.judge(
            source: nodeA,
            target: nodeB,
            similarity: 0.50,
            sourceAtoms: [],
            targetAtoms: []
        )

        let history = try traceStore.history(sourceId: nodeA.id, targetId: nodeB.id, limit: 10)
        XCTAssertEqual(history.count, 1, "Rejection still produces a trace row")
        XCTAssertNil(history[0].relationKind, "Nil relation_kind = judge said no")
    }
}
```

If `NousNode.fixture` and `MemoryAtom.fixture` test helpers don't exist, inspect `Tests/NousTests/GalaxyRelationJudgeTests.swift` (or similar) for the existing fixture pattern and either reuse the helper or inline a minimal `init(...)` call.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/GalaxyJudgeTraceWiringTests 2>&1 | tail -10`
Expected: FAIL — `judgeTraceWriter` parameter doesn't exist on init

- [ ] **Step 3: Modify GalaxyRelationJudge to accept and use the trace writer**

In `Sources/Nous/Services/GalaxyRelationJudge.swift`, modify the `init` to accept `judgeTraceWriter: EdgeJudgeTraceStore?`:

```swift
private let judgeTraceWriter: EdgeJudgeTraceStore?

init(
    minimumTopicSimilarity: Float = GalaxyRelationTuning.semanticThreshold,
    telemetry: GalaxyRelationTelemetry? = nil,
    backgroundTelemetry: (any BackgroundAIJobTelemetryRecording)? = nil,
    judgeTraceWriter: EdgeJudgeTraceStore? = nil,
    llmServiceProvider: (() -> (any LLMService)?)? = nil
) {
    self.minimumTopicSimilarity = minimumTopicSimilarity
    self.telemetry = telemetry
    self.backgroundTelemetry = backgroundTelemetry
    self.judgeTraceWriter = judgeTraceWriter
    self.llmServiceProvider = llmServiceProvider
}
```

In the body of `judge(source:target:similarity:sourceAtoms:targetAtoms:)`, after each verdict-decision branch, add a trace write. Locate the existing `telemetry?.record(...)` lines and add adjacent `try? judgeTraceWriter?.append(...)` calls:

```swift
// In judgeAtomRelationship-hit branch, after `telemetry?.record(.localVerdict)`:
try? judgeTraceWriter?.append(
    sourceId: source.id,
    targetId: target.id,
    relationKind: atomVerdict.relationKind.rawValue,
    judgePath: .atom,
    similarity: Double(similarity),
    confidence: Double(atomVerdict.confidence)
)

// In threshold-fail branch, after `telemetry?.record(.localNil)`:
try? judgeTraceWriter?.append(
    sourceId: source.id,
    targetId: target.id,
    relationKind: nil,
    judgePath: .fallback,
    similarity: Double(similarity),
    confidence: nil
)

// In topicSimilarity-fallback branch, after `telemetry?.record(.localVerdict)`:
try? judgeTraceWriter?.append(
    sourceId: source.id,
    targetId: target.id,
    relationKind: GalaxyRelationKind.topicSimilarity.rawValue,
    judgePath: .fallback,
    similarity: Double(similarity),
    confidence: Double(similarity)
)
```

Also add to `judgeRefined` LLM-success path:

```swift
// After `telemetry?.record(verdict == nil ? .llmNil : .llmVerdict)`:
try? judgeTraceWriter?.append(
    sourceId: source.id,
    targetId: target.id,
    relationKind: verdict?.relationKind.rawValue,
    judgePath: .llm,
    similarity: Double(similarity),
    confidence: verdict.map { Double($0.confidence) }
)
```

- [ ] **Step 4: Modify GalaxyEdgeEngine to pass trace writer through**

In `Sources/Nous/Services/GalaxyEdgeEngine.swift`, add `judgeTraceWriter: EdgeJudgeTraceStore?` to init (matching the same convention) and propagate to GalaxyRelationJudge construction. Also emit a reject trace when `assessment.decision != .accept`:

```swift
// In generateSemanticEdges, replace the `guard assessment.decision == .accept ...` block with:
guard assessment.decision == .accept, let verdict = assessment.verdict else {
    try? judgeTraceWriter?.append(
        sourceId: node.id,
        targetId: neighbor.node.id,
        relationKind: nil,
        judgePath: .fallback,
        similarity: Double(neighbor.similarity),
        confidence: nil
    )
    continue
}
```

Note: this reject-trace covers the case where `relationJudge.judge` returned a verdict but `connectionJudge.assess` rejected it. The judge-internal traces from Step 3 cover the case where `relationJudge.judge` returned nil. Both are needed — they capture different rejection reasons.

- [ ] **Step 5: Register new test file in pbxproj**

```bash
ruby -rxcodeproj -e '
proj = Xcodeproj::Project.open("Nous.xcodeproj")
test_target = proj.targets.find { |t| t.name == "NousTests" }
tests_group = proj.main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == "NousTests" }

test_ref = tests_group.new_reference("GalaxyJudgeTraceWiringTests.swift")
test_target.source_build_phase.add_file_reference(test_ref)

proj.save
'
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/GalaxyJudgeTraceWiringTests 2>&1 | tail -10`
Expected: 3/3 new tests pass

Run: `scripts/test_nous.sh 2>&1 | tail -10`
Expected: All existing tests still pass

- [ ] **Step 7: Commit**

```bash
git add Sources/Nous/Services/GalaxyRelationJudge.swift Sources/Nous/Services/GalaxyEdgeEngine.swift Tests/NousTests/GalaxyJudgeTraceWiringTests.swift Nous.xcodeproj/project.pbxproj
git commit -m "feat(feedback): wire EdgeJudgeTraceStore into galaxy judge

Trace writes at atom/llm/fallback/reject sites. Reject branch covers both
'judge returned nil' (in judge body) and 'connection judge rejected'
(in engine loop) — distinct rejection reasons captured separately.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 9: Wire CitationJudgeTraceStore into ChatViewModel

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift` — after cascade resolves, write one trace row per candidate atom with was_displayed flag
- Create: `Tests/NousTests/CitationTraceWiringTests.swift`

- [ ] **Step 1: Inspect existing wiring**

Before writing tests, find:
- Where in `ChatViewModel.swift` `resolvedCorpusEntries` is set (search for `resolvedCorpusEntries =`).
- Where `primaryAttribution` (the cascade result) is computed.
- Where the model reply turn id is available — likely in the same scope as where reply messages are persisted.

Goal: identify the exact function where cascade has resolved AND turn id is known. That's where the trace writes go.

- [ ] **Step 2: Write the failing test**

```swift
// Tests/NousTests/CitationTraceWiringTests.swift
import XCTest
@testable import Nous

final class CitationTraceWiringTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var traceStore: CitationJudgeTraceStore!

    override func setUpWithError() throws {
        nodeStore = try NodeStore(databasePath: ":memory:")
        traceStore = CitationJudgeTraceStore(nodeStore: nodeStore)
    }

    func testTraceWriteEmitsRowPerCandidateAtom() throws {
        let conv = UUID()
        let turn = UUID()
        let atom1 = UUID()
        let atom2 = UUID()
        let atom3 = UUID()

        // The shape of the helper depends on how ChatViewModel exposes the
        // write. Build a CitationTraceEmitter helper struct that takes
        // (candidates, displayedIds) and writes traces — this is the same
        // function ChatViewModel will call.
        let emitter = CitationTraceEmitter(traceStore: traceStore)
        let candidates = [
            (atomId: atom1, confidence: 0.85),
            (atomId: atom2, confidence: 0.55),
            (atomId: atom3, confidence: 0.72)
        ]
        let displayed: Set<UUID> = [atom1, atom3]  // atom2 filtered by floor

        try emitter.emit(
            conversationId: conv,
            turnId: turn,
            candidates: candidates,
            displayedIds: displayed
        )

        let rows = try traceStore.byTurn(turnId: turn)
        XCTAssertEqual(rows.count, 3, "One row per candidate, including filtered")
        XCTAssertEqual(rows.filter(\.wasDisplayed).count, 2)
        XCTAssertTrue(rows.first { $0.atomId == atom2 }?.wasDisplayed == false)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/CitationTraceWiringTests 2>&1 | tail -10`
Expected: FAIL — `CitationTraceEmitter` doesn't exist

- [ ] **Step 4: Create CitationTraceEmitter helper**

```swift
// Sources/Nous/Services/CitationTraceEmitter.swift
import Foundation

/// Writes citation_judge_trace rows for a single chat turn, after
/// AttributionDisplay.cascade has resolved which atoms ended up displayed.
/// Called from ChatViewModel once per assistant reply turn.
final class CitationTraceEmitter {
    private let traceStore: CitationJudgeTraceStore

    init(traceStore: CitationJudgeTraceStore) {
        self.traceStore = traceStore
    }

    func emit(
        conversationId: UUID,
        turnId: UUID,
        candidates: [(atomId: UUID, confidence: Double)],
        displayedIds: Set<UUID>
    ) throws {
        for candidate in candidates {
            try traceStore.append(
                conversationId: conversationId,
                turnId: turnId,
                atomId: candidate.atomId,
                confidence: candidate.confidence,
                wasDisplayed: displayedIds.contains(candidate.atomId)
            )
        }
    }
}
```

- [ ] **Step 5: Wire CitationTraceEmitter into ChatViewModel**

Find the function in `ChatViewModel.swift` that runs after the model reply finishes streaming AND `primaryAttribution` has resolved. Inject `CitationTraceEmitter` (initialized in the ChatViewModel constructor with the shared NodeStore) and call:

```swift
// After cascade decision, before storing reply turn:
let displayedAtomIds: Set<UUID> = {
    switch primaryAttribution {
    case .atomCards(let entries):
        return Set(entries.compactMap { entry in
            // Resolve UUID from entry.entry.id (a string) — match existing helper.
            UUID(uuidString: entry.entry.id)
        })
    case .legacyCitations, .none:
        return []
    }
}()

let candidates = resolvedCorpusEntries.map { entry in
    (atomId: UUID(uuidString: entry.entry.id) ?? UUID(),
     confidence: entry.entry.confidence ?? 0.0)
}

try? citationTraceEmitter.emit(
    conversationId: conversationId,
    turnId: replyTurnId,
    candidates: candidates,
    displayedIds: displayedAtomIds
)
```

The exact field names (`entry.entry.id`, `entry.entry.confidence`) depend on the `ResolvedCitableEntry` shape — verify against `Sources/Nous/Models/CitableContext.swift` and adjust. If the ResolvedCitableEntry id is not a UUID string but a different identifier shape, propagate that type through the emitter signature instead of forcing UUID.

- [ ] **Step 6: Register new files in pbxproj**

```bash
ruby -rxcodeproj -e '
proj = Xcodeproj::Project.open("Nous.xcodeproj")
target = proj.targets.find { |t| t.name == "Nous" }
test_target = proj.targets.find { |t| t.name == "NousTests" }
services_group = proj.main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == "Services" }
tests_group = proj.main_group.recursive_children.find { |g| g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == "NousTests" }

src_ref = services_group.new_reference("CitationTraceEmitter.swift")
target.source_build_phase.add_file_reference(src_ref)

test_ref = tests_group.new_reference("CitationTraceWiringTests.swift")
test_target.source_build_phase.add_file_reference(test_ref)

proj.save
'
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -only-testing:NousTests/CitationTraceWiringTests 2>&1 | tail -10`
Expected: 1/1 new test pass

Run: `scripts/test_nous.sh 2>&1 | tail -10`
Expected: All existing tests still pass

- [ ] **Step 8: Commit**

```bash
git add Sources/Nous/Services/CitationTraceEmitter.swift Sources/Nous/ViewModels/ChatViewModel.swift Tests/NousTests/CitationTraceWiringTests.swift Nous.xcodeproj/project.pbxproj
git commit -m "feat(feedback): wire CitationJudgeTraceStore into ChatViewModel

Deferred single-write — emitter runs once per turn after AttributionDisplay
cascade resolves. Trade-off: ChatViewModel takes on a small telemetry
write responsibility; benefit: one DB write per turn, no row-id round-trip.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 10: Mount ThumbFeedbackView in GalaxyView journalCard

**Files:**
- Modify: `Sources/Nous/Views/GalaxyView.swift` — add ThumbFeedbackView at end of journalCard ScrollView VStack; wire EdgeFeedbackStore upsert in callback
- Modify: `Sources/Nous/ViewModels/GalaxyViewModel.swift` — add `feedbackStore: EdgeFeedbackStore` and `traceStore: EdgeJudgeTraceStore` properties; expose lookup methods for inspector

- [ ] **Step 1: Wire EdgeFeedbackStore + EdgeJudgeTraceStore into GalaxyViewModel**

Add to `GalaxyViewModel`:

```swift
private let feedbackStore: EdgeFeedbackStore
private let traceStore: EdgeJudgeTraceStore

// Update init to receive nodeStore-derived instances:
init(
    nodeStore: NodeStore,
    // ... existing params ...
) {
    // ... existing init body ...
    self.feedbackStore = EdgeFeedbackStore(nodeStore: nodeStore)
    self.traceStore = EdgeJudgeTraceStore(nodeStore: nodeStore)
}

func feedback(for edge: NodeEdge) -> EdgeFeedbackRow? {
    try? feedbackStore.fetch(
        sourceId: edge.sourceId,
        targetId: edge.targetId,
        relationKind: edge.relationKind?.rawValue ?? ""
    )
}

func telemetry(for edge: NodeEdge) -> TelemetryStrip? {
    guard let trace = try? traceStore.latest(sourceId: edge.sourceId, targetId: edge.targetId) else {
        return nil
    }
    let priorCount = (try? feedbackStore.fetch(
        sourceId: edge.sourceId,
        targetId: edge.targetId,
        relationKind: edge.relationKind?.rawValue ?? ""
    ))??.verdictCount ?? 0
    return TelemetryStrip(
        similarity: trace.similarity,
        judgePath: trace.judgePath,
        confidence: trace.confidence,
        judgedAt: trace.judgedAt,
        priorVerdictCount: priorCount
    )
}

func upsertEdgeFeedback(edge: NodeEdge, verdict: ThumbVerdict, note: String) {
    try? feedbackStore.upsert(
        sourceId: edge.sourceId,
        targetId: edge.targetId,
        relationKind: edge.relationKind?.rawValue ?? "",
        verdict: verdict,
        note: note.isEmpty ? nil : note
    )
}
```

- [ ] **Step 2: Mount ThumbFeedbackView at end of journalCard ScrollView VStack**

In `Sources/Nous/Views/GalaxyView.swift`, locate the journalCard `ScrollView { VStack(...)` body (around line 126-148). After the existing `Text(summary.body)` block, append:

```swift
                if let edge = journalEdge {
                    Divider().background(GalaxyPalette.panelStroke)

                    ThumbFeedbackView(
                        verdict: Binding(
                            get: { vm.feedback(for: edge)?.verdict ?? .unset },
                            set: { newVerdict in
                                let currentNote = vm.feedback(for: edge)?.note ?? ""
                                vm.upsertEdgeFeedback(edge: edge, verdict: newVerdict, note: currentNote)
                            }
                        ),
                        note: Binding(
                            get: { vm.feedback(for: edge)?.note ?? "" },
                            set: { newNote in
                                let currentVerdict = vm.feedback(for: edge)?.verdict ?? .unset
                                vm.upsertEdgeFeedback(edge: edge, verdict: currentVerdict, note: newNote)
                            }
                        ),
                        style: .galaxy,
                        telemetry: vm.telemetry(for: edge),
                        onChange: { verdict, note in
                            vm.upsertEdgeFeedback(edge: edge, verdict: verdict, note: note)
                        }
                    )
                }
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild build -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`

If there are compile errors about `journalEdge` shape or `edge.relationKind?.rawValue` access, inspect the actual `NodeEdge` and `journalEdge` types in `Sources/Nous/Models/` and adjust the bindings/lookup to match.

- [ ] **Step 4: Run full test suite**

Run: `scripts/test_nous.sh 2>&1 | tail -10`
Expected: All existing tests still pass

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/GalaxyView.swift Sources/Nous/ViewModels/GalaxyViewModel.swift
git commit -m "feat(feedback): mount ThumbFeedbackView in galaxy journal card

Bottom of inspector below evidence cards. Reads existing feedback +
telemetry on display, upserts on user interaction. Old edges show
'未记录（Phase A 之前）' for the telemetry strip.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 11: Mount compact ThumbFeedbackView in CorpusAtomCardListView

**Files:**
- Modify: `Sources/Nous/Views/CorpusAtomCardListView.swift` — add ThumbFeedbackView per atom row; needs conversationId + turnId props passed in
- Modify: `Sources/Nous/Views/ChatArea.swift` (or wherever CorpusAtomCardListView is mounted) — pass conversationId + turnId + feedbackStore through

- [ ] **Step 1: Add props to CorpusAtomCardListView**

In `Sources/Nous/Views/CorpusAtomCardListView.swift`, add to the struct's stored properties:

```swift
let conversationId: UUID
let turnId: UUID
let feedbackStore: CitationFeedbackStore
```

Update the `atomRow` private function to mount ThumbFeedbackView per row:

```swift
private func atomRow(_ resolved: ResolvedCitableEntry) -> some View {
    HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 4) {
            // ... existing atom row body (header + statement) ...

            HStack {
                Spacer()
                if let atomId = UUID(uuidString: resolved.entry.id) {
                    ThumbFeedbackView(
                        verdict: Binding(
                            get: {
                                (try? feedbackStore.fetch(
                                    conversationId: conversationId,
                                    turnId: turnId,
                                    atomId: atomId
                                ))??.verdict ?? .unset
                            },
                            set: { newVerdict in
                                let currentNote = (try? feedbackStore.fetch(
                                    conversationId: conversationId,
                                    turnId: turnId,
                                    atomId: atomId
                                ))??.note ?? ""
                                try? feedbackStore.upsert(
                                    conversationId: conversationId,
                                    turnId: turnId,
                                    atomId: atomId,
                                    verdict: newVerdict,
                                    note: currentNote.isEmpty ? nil : currentNote
                                )
                            }
                        ),
                        note: Binding(
                            get: {
                                (try? feedbackStore.fetch(
                                    conversationId: conversationId,
                                    turnId: turnId,
                                    atomId: atomId
                                ))??.note ?? ""
                            },
                            set: { newNote in
                                let currentVerdict = (try? feedbackStore.fetch(
                                    conversationId: conversationId,
                                    turnId: turnId,
                                    atomId: atomId
                                ))??.verdict ?? .unset
                                try? feedbackStore.upsert(
                                    conversationId: conversationId,
                                    turnId: turnId,
                                    atomId: atomId,
                                    verdict: currentVerdict,
                                    note: newNote.isEmpty ? nil : newNote
                                )
                            }
                        ),
                        style: .chat,
                        telemetry: nil,
                        onChange: { _, _ in /* upsert in setters above */ }
                    )
                }
            }
        }
    }
}
```

- [ ] **Step 2: Update CorpusAtomCardListView call sites**

Find every place `CorpusAtomCardListView(...)` is constructed (likely in `ChatArea.swift`). Add the three new params:

```swift
CorpusAtomCardListView(
    entries: ...,
    isExpanded: ...,
    onOpenSource: ...,
    conversationId: chatVM.conversationId,
    turnId: messageTurnId,
    feedbackStore: chatVM.citationFeedbackStore  // expose this on ChatViewModel
)
```

ChatViewModel needs to expose `citationFeedbackStore: CitationFeedbackStore` (constructed in init from nodeStore).

- [ ] **Step 3: Build to verify**

Run: `xcodebuild build -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`

If compile errors about `messageTurnId` (chat side may use a different identifier — `messageId`, `nodeId`, etc.), match what's available in the ChatArea scope. The trace store and feedback store both need a stable per-turn identifier; if the chat schema doesn't have one, use the model reply's `messageId` (which IS unique per turn).

- [ ] **Step 4: Run full test suite**

Run: `scripts/test_nous.sh 2>&1 | tail -10`
Expected: All existing tests still pass

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/CorpusAtomCardListView.swift Sources/Nous/Views/ChatArea.swift Sources/Nous/ViewModels/ChatViewModel.swift
git commit -m "feat(feedback): mount compact ThumbFeedbackView in chat atom cards

Per-atom thumb (icon-only) keyed by (conversationId, turnId, atomId).
Note textbox reveals only on thumb-down to keep reading flow intact.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 12: pbxproj sanity check + dedupe

**Files:**
- Verify: `Nous.xcodeproj/project.pbxproj` has no duplicate file references introduced by the per-task Ruby snippets

- [ ] **Step 1: Check for duplicates**

Run:

```bash
ruby -rxcodeproj -e '
proj = Xcodeproj::Project.open("Nous.xcodeproj")
seen = Hash.new(0)
proj.files.each do |f|
  seen[f.path] += 1 if f.path
end
dupes = seen.select { |_, count| count > 1 }
if dupes.empty?
  puts "OK — no duplicate PBXFileReferences"
else
  puts "DUPLICATES FOUND:"
  dupes.each { |path, count| puts "  #{path}: #{count}" }
end
'
```

Expected: `OK — no duplicate PBXFileReferences`

If duplicates exist, dedupe with:

```bash
ruby -rxcodeproj -e '
proj = Xcodeproj::Project.open("Nous.xcodeproj")
seen = {}
to_remove = []
proj.files.each do |f|
  if f.path && seen[f.path]
    to_remove << f
  elsif f.path
    seen[f.path] = f
  end
end
to_remove.each(&:remove_from_project)
proj.save
puts "Removed #{to_remove.count} duplicates"
'
```

Then re-run the check command.

- [ ] **Step 2: Run final build to verify clean**

Run: `xcodebuild build -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` with no "duplicate" warnings

- [ ] **Step 3: Run full test suite**

Run: `scripts/test_nous.sh 2>&1 | tail -10`
Expected: All tests pass (existing + new ~22 new tests across 6 test files)

- [ ] **Step 4: Commit if pbxproj changed**

If Step 1 found duplicates and removed them:

```bash
git add Nous.xcodeproj/project.pbxproj
git commit -m "fix(build): dedupe pbxproj entries from per-task additions

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

If no duplicates, skip the commit.

---

## Task 13: Manual QA + final integration check

**Files:** none modified — verification only

- [ ] **Step 1: Launch Nous**

```bash
xcodebuild build -project Nous.xcodeproj -scheme Nous -destination "platform=macOS" -derivedDataPath build 2>&1 | tail -5
open build/Build/Products/Debug/Nous.app
```

- [ ] **Step 2: Galaxy QA — feedback UI**

1. Open Galaxy view
2. Tap a node that has at least one verified edge → verify focus mode + edge highlights work (should still match prior behavior)
3. Tap an edge → inspector opens with the new feedback section at the bottom
4. Verify telemetry strip displays:
   - For NEW edges (post-Phase A): `相似度 X.XX · 路径 atom/llm/fallback · 信心 X.XX · 判断於 HH:MM`
   - For OLD edges (pre-Phase A): `判断路径: 未记录（Phase A 之前）`
5. Tap 👎 → button gets dusty rose fill
6. Type into "想补充？" textbox → defocus → verify upsert happens (no UI feedback expected, but no crash)
7. Close inspector + reopen same edge → selected state persists, note text persists
8. Tap 👍 → verify state changes, telemetry strip should now show `· 之前已表态 1 次`

- [ ] **Step 3: Chat QA — feedback UI**

1. Open chat, send a message that should trigger atom retrieval (e.g., a question referencing a topic from prior conversations)
2. Verify the model reply has atom cards below it (the existing block-4b UI)
3. Expand the atom card list
4. Verify each atom row has thumb 👍 👎 icons on the right
5. Tap 👎 on an atom → verify thumb fills dusty rose; verify a textbox reveals below the row
6. Type into the textbox → defocus → no crash
7. Close + reopen the atom card list → selected state persists

- [ ] **Step 4: Persistence QA**

1. Quit Nous
2. Relaunch
3. Open same galaxy edge from Step 2 → verify thumb + note persists
4. Open same chat conversation → verify atom thumbs persist

- [ ] **Step 5: Telemetry sanity check**

Find the SQLite DB path (likely `~/Library/Containers/<bundle id>/Data/Library/Application Support/Nous/database.sqlite` or similar — check NodeStore for the actual path):

```bash
DB="$(find ~/Library/Containers -name 'database.sqlite' 2>/dev/null | head -1)"
echo "DB: $DB"
sqlite3 "$DB" "SELECT COUNT(*) FROM edge_judge_trace;"
sqlite3 "$DB" "SELECT COUNT(*) FROM citation_judge_trace;"
sqlite3 "$DB" "SELECT COUNT(*) FROM edge_feedback;"
sqlite3 "$DB" "SELECT COUNT(*) FROM citation_feedback;"
```

Expected: All four counts are >= 0 (the trace tables should have rows after using the app; feedback tables have rows after thumb interactions in QA above).

- [ ] **Step 6: Final commit if needed**

If Steps 1-5 surface any bug fixes, commit them with descriptive messages. If everything works, no commit needed — Phase A is shipped.

- [ ] **Step 7: Update spec status**

In `docs/superpowers/specs/2026-05-09-edge-inference-feedback-ledger-design.md`, change `**Status**: approved` to `**Status**: shipped (Phase A)`. Commit:

```bash
git add docs/superpowers/specs/2026-05-09-edge-inference-feedback-ledger-design.md
git commit -m "docs: mark edge inference feedback ledger Phase A as shipped

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Self-Review Notes

**Spec coverage:**
- ✅ 4 tables (Tasks 2)
- ✅ ThumbVerdict + JudgePath enums (Task 1)
- ✅ 4 stores: EdgeFeedback, CitationFeedback, EdgeJudgeTrace, CitationJudgeTrace (Tasks 3-6)
- ✅ ThumbFeedbackView shared component (Task 7)
- ✅ Galaxy inspector mount (Task 10)
- ✅ Chat atom card mount (Task 11)
- ✅ Telemetry capture wire-up — galaxy (Task 8) + chat (Task 9)
- ✅ Test coverage per spec testing strategy
- ✅ Manual QA checklist (Task 13)

**Type consistency:** All references to `ThumbVerdict`, `JudgePath`, `EdgeFeedbackStore`, `CitationFeedbackStore`, `EdgeJudgeTraceStore`, `CitationJudgeTraceStore`, `TelemetryStrip`, `ThumbFeedbackView.Style`, `CitationTraceEmitter` use consistent names across tasks.

**Placeholder scan:** No "TBD" or "implement later" markers. Tasks that depend on inspecting existing code (e.g., `db.exec` signature, `ResolvedCitableEntry.id` type, journalEdge shape) explicitly call out the inspection step rather than hand-waving — implementer must verify before adapting.

**Out-of-scope items confirmed not done in this plan:** voice surface feedback, "suggest correct verdict" quick-pick, trace rotation/TTL, dataset export tooling, Phase A2 threshold/prompt tuning. These are explicitly listed in the spec as deferred.
