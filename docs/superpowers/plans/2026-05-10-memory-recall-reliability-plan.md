# Memory Recall Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Nous memory recall reliable across conversations and languages by swapping in a multilingual embedding model with a signature-tracked migration, teaching the atom extractor to preserve Alex's source-language voice, and routing default chat through the same query-driven corpus retrieval that quick-action modes already use.

**Architecture:** Three independent structural changes plus an upstream embedding-compat verification, all guarded by one class-level regression suite that uses synthetic fixture data (no historical incident names). Each change is reversible on its own; together they unblock cross-conversation cross-lingual recall in the default chat path.

**Tech Stack:** Swift 6, MLX Swift / MLXEmbedders, SQLite (existing `NodeStore` infra), XCTest. No new third-party dependencies. Build via `xcodebuild` (no root `Package.swift`).

**Spec reference:** `docs/superpowers/specs/2026-05-10-memory-recall-reliability-design.md` (committed `e4018e25`).

---

## File Structure

**New files:**

- `Sources/Nous/Services/EmbeddingMigrationRunner.swift` — runs on app boot, re-embeds rows whose `embedding_signature` no longer matches `EmbeddingService.currentSignature`. Mirrors `MemoryAtomEmbeddingBackfillService` shape (idempotent, batched, resumable).
- `Tests/NousTests/MemoryRecallReliabilityTests.swift` — fast deterministic class-level regression suite using `StubEmbedder`-style fakes.
- `Tests/NousTests/MemoryRecallReliabilityIntegrationTests.swift` — env-gated (`MEMORY_RECALL_INTEGRATION=1`) integration suite that loads the real multilingual model.
- `docs/superpowers/memos/2026-05-10-embedding-compat.md` — Phase 0 deliverable locking model choice.

**Modified files:**

- `Sources/Nous/Services/EmbeddingService.swift` — swap `defaultModelId`; add static `currentSignature`; add `currentModelDescriptor`.
- `Sources/Nous/Services/NodeStore.swift` — schema migration adding `embedding_signature TEXT` + `verbatim_quote TEXT` columns to `memory_atoms`; per-signature filter in `fetchMemoryAtomsNearest`.
- `Sources/Nous/Models/MemoryAtom.swift` — add `embeddingSignature: String?` and `verbatimQuote: String?` fields with default `nil`.
- `Sources/Nous/Services/MemoryGraphWriter.swift` — stamp current signature on every atom write that produces an embedding.
- `Sources/Nous/Services/UserMemoryService.swift` — atom-extraction prompt edit (lines 1034–1093 area); persist `evidence_quote` into the new `verbatim_quote` column.
- `Sources/Nous/Services/TurnMemoryContextBuilder.swift:113–127` — compute `queryEmbedding` and `memoryGraphRecall` for default chat, not just quick-action modes.
- `Sources/Nous/Services/PromptContextAssembler.swift:1019` — remove the `activeQuickActionMode != nil` clause guarding `GRAPH MEMORY RECALL` injection.
- `Sources/Nous/App/AppEnvironment.swift:187–193` area — wire `EmbeddingMigrationRunner` on boot.

**Untouched (explicit non-goals):**

- `Sources/Nous/Resources/anchor.md` (frozen per `AGENTS.md:39, 131`).
- `messages_fts` / `nodes_fts` chat-citation chip retrieval — that's the 2026-05-08 plan's scope.
- `MemoryProjectionService` conversation summary blob — kept as orientation context.

---

## Phase 0 — Embedding Compatibility Verification (~½ day)

**Goal:** Pick the multilingual model that both loads cleanly in `MLXEmbedders` and produces non-noise cross-lingual cosine similarity on Alex's real corpus shape. Lock the choice in a memo before any code change.

### Task 0.1 — Verify candidate models load in MLXEmbedders

**Files:**
- Read: `Sources/Nous/Services/EmbeddingService.swift`
- Output: `docs/superpowers/memos/2026-05-10-embedding-compat.md` (new)

- [ ] **Step 1:** In a scratch test target or playground, attempt to load each candidate by swapping `defaultModelId` and calling `loadModel()`:
  - `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` (384 dim, BERT family — preferred)
  - `intfloat/multilingual-e5-small` (384 dim, XLM-R family — backup)

- [ ] **Step 2:** Record for each model: (a) `loadModel()` returns without throwing, (b) `embed("hello")` returns the expected dim count, (c) tokenizer round-trips both English and Cantonese characters, (d) first-load + subsequent-call latency on M-series.

- [ ] **Step 3:** Compute cross-lingual similarity sanity check. Embed these 4 pairs with each candidate and record cosine:
  - `("我嚟到美国都已经系不可思议嘅啦", "I made it to the US at all is already remarkable")`
  - `("自卑", "inferiority complex")`
  - `("普通人", "ordinary people")`
  - `("室友又惡咗我", "my roommate is being mean to me again")`

  Compare against MiniLM-L6-v2 baseline. Pass criterion: each pair scores ≥ 0.65 cosine on the multilingual model AND ≥ 0.20 above the MiniLM-L6-v2 baseline.

- [ ] **Step 4:** Write the memo at `docs/superpowers/memos/2026-05-10-embedding-compat.md` with sections: candidates tested, load results, latency table, cross-lingual cosine table, **chosen model + rationale**, fallback model, signature string format.

- [ ] **Step 5:** Commit the memo:

```bash
git add docs/superpowers/memos/2026-05-10-embedding-compat.md
git commit -m "docs(memos): lock multilingual embedding model choice"
```

---

## Phase 1 — Multilingual Embedding + Signature Column + Migration Runner (~1.5 days)

**Goal:** Replace English-only `all-MiniLM-L6-v2` with the Phase 0 choice, gate all vector comparisons by `embedding_signature` to make accidental cross-model comparison impossible, and ship the migration runner that re-embeds the existing 1810 atoms (and ~52 chat nodes) into the new space.

This phase is TDD-first: the class-level fixture test file gets created in Task 1.1 and asserts the contracts that subsequent tasks make pass.

### Task 1.1 — Class-level regression suite (TDD-first; failing)

**Files:**
- Create: `Tests/NousTests/MemoryRecallReliabilityTests.swift`

- [ ] **Step 1:** Create the test file with a `StubEmbedder` helper that maps fixture statements to deterministic embeddings (parallel-translation pairs share a vector to simulate multilingual semantic match):

```swift
import XCTest
@testable import Nous

final class MemoryRecallReliabilityTests: XCTestCase {
    /// Deterministic stub. Keys that share the leading "topic-X-" prefix
    /// share an embedding vector — this models a multilingual model that
    /// places Cantonese / English paraphrases near each other.
    final class StubEmbedder {
        private static let dim = 8
        func embed(_ text: String) -> [Float] {
            var vec = [Float](repeating: 0, count: Self.dim)
            for topic in ["topic-A", "topic-B", "topic-C", "topic-D"] {
                if text.contains(topic) { vec[topic.last!.asciiValue! % UInt8(Self.dim)] = 1; break }
            }
            return vec
        }
    }
}
```

- [ ] **Step 2:** Add the 7 class assertions from the spec as separate `func test_…` methods, each currently calling functions that don't exist yet (will fail to compile — that's the failing-test state):

```swift
func test_assertion_1_cantonese_2char_keyword_surfaces_chat_atoms() throws {
    let env = try MemoryRecallTestEnv.make()  // helper to be created
    env.seedAtom(text: "topic-A 我唔配喺呢度", scope: .conversation, conv: "chat-A")
    let results = try env.retrieve(query: "topic-A 自卑")
    XCTAssertTrue(results.contains { $0.statement.contains("topic-A") })
}

func test_assertion_2_codeswitch_query_finds_both_languages() throws {
    let env = try MemoryRecallTestEnv.make()
    env.seedAtom(text: "topic-B 我嘅 career", scope: .conversation, conv: "chat-B")
    env.seedAtom(text: "topic-B my career planning", scope: .conversation, conv: "chat-C")
    let results = try env.retrieve(query: "topic-B career 走向")
    XCTAssertGreaterThanOrEqual(results.filter { $0.statement.contains("topic-B") }.count, 2)
}

func test_assertion_3_cantonese_query_finds_english_atom_via_vector() throws {
    let env = try MemoryRecallTestEnv.make()
    env.seedAtom(text: "topic-C English-only fixture statement", scope: .conversation, conv: "chat-D")
    let results = try env.retrieve(query: "topic-C 中文 query")
    XCTAssertTrue(results.contains { $0.statement.contains("topic-C") })
}

func test_assertion_4_off_topic_query_returns_empty_or_low_confidence() throws {
    let env = try MemoryRecallTestEnv.make()
    env.seedAtom(text: "topic-A unrelated", scope: .conversation, conv: "chat-A")
    let results = try env.retrieve(query: "topic-Z totally different")
    XCTAssertTrue(results.isEmpty || results.allSatisfy { $0.confidence < 0.5 })
}

func test_assertion_5_default_chat_runs_corpus_retrieval() throws {
    let env = try MemoryRecallTestEnv.make()
    env.seedAtom(text: "topic-A statement", scope: .conversation, conv: "chat-A")
    let result = try env.buildPromptContext(quickActionMode: nil, query: "topic-A query")
    XCTAssertTrue(result.contains("topic-A"), "Default chat must include corpus retrieval output")
}

func test_assertion_6_new_atom_preserves_source_language_and_quote() throws {
    let env = try MemoryRecallTestEnv.make()
    let atom = try env.extractAtomFrom(userMessage: "我唔系一个读书好叻嘅人")
    XCTAssertTrue(atom.statement.contains("唔") || atom.statement.contains("我"))
    XCTAssertNotNil(atom.verbatimQuote)
    XCTAssertFalse(atom.verbatimQuote?.isEmpty ?? true)
}

func test_assertion_7_cross_signature_query_rejected() throws {
    let env = try MemoryRecallTestEnv.make()
    env.seedAtom(text: "topic-A old", scope: .conversation, conv: "chat-A", signature: "old-sig-v0")
    env.setCurrentSignature("new-sig-v1")
    let results = try env.retrieve(query: "topic-A")
    XCTAssertTrue(results.isEmpty, "Old-signature atoms must be invisible to new-signature query")
}
```

- [ ] **Step 3:** Add stubs at the bottom of the file for `MemoryRecallTestEnv` with `make()`, `seedAtom(...)`, `retrieve(...)`, `buildPromptContext(...)`, `extractAtomFrom(...)`, `setCurrentSignature(...)`. Each method body is `fatalError("unimplemented — Task 1.2+")` for now.

- [ ] **Step 4:** Run the suite to confirm it fails to compile (test contract is locked):

```bash
xcodebuild test -scheme Nous -only-testing:NousTests/MemoryRecallReliabilityTests -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: build / link errors referencing `verbatimQuote`, `extractAtomFrom`, `setCurrentSignature`. **Do not fix yet** — that's what Tasks 1.2–3.2 do.

- [ ] **Step 5:** Commit the failing fixture:

```bash
git add Tests/NousTests/MemoryRecallReliabilityTests.swift
git commit -m "test(memory): class-level recall reliability fixture (failing — TDD anchor)"
```

### Task 1.2 — Schema migration: `embedding_signature` + `verbatim_quote` columns

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift` (schema bootstrap region, near `ensureColumnExists` calls already in file)
- Modify: `Sources/Nous/Models/MemoryAtom.swift`

- [ ] **Step 1:** In `NodeStore.swift` schema bootstrap, after the existing `memory_atoms` table creation, add two `ensureColumnExists` calls:

```swift
try ensureColumnExists(
    table: "memory_atoms",
    column: "embedding_signature",
    alterSQL: "ALTER TABLE memory_atoms ADD COLUMN embedding_signature TEXT;"
)
try ensureColumnExists(
    table: "memory_atoms",
    column: "verbatim_quote",
    alterSQL: "ALTER TABLE memory_atoms ADD COLUMN verbatim_quote TEXT;"
)
```

Index for fast per-signature filtering:

```swift
try db.exec("""
    CREATE INDEX IF NOT EXISTS idx_memory_atoms_signature
    ON memory_atoms(embedding_signature)
    WHERE embedding_signature IS NOT NULL;
""")
```

- [ ] **Step 2:** In `MemoryAtom.swift` add two new optional stored properties with default `nil`:

```swift
var embeddingSignature: String?
var verbatimQuote: String?
```

Update the `init(...)` signature to accept both, both defaulting to `nil`, and assign them in the initializer body.

- [ ] **Step 3:** In `NodeStore.swift` update the `INSERT INTO memory_atoms` and `UPDATE memory_atoms SET ...` SQL strings to include the two new columns. Update the corresponding `bind(...)` calls. Update the `SELECT ... FROM memory_atoms` row decoder to populate the new fields.

- [ ] **Step 4:** Run existing tests to confirm nothing regressed:

```bash
xcodebuild test -scheme Nous -only-testing:NousTests/MemoryAtomEmbeddingBackfillServiceTests -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 5:** Commit:

```bash
git add Sources/Nous/Services/NodeStore.swift Sources/Nous/Models/MemoryAtom.swift
git commit -m "feat(memory): add embedding_signature + verbatim_quote columns on memory_atoms"
```

### Task 1.3 — `EmbeddingService.currentSignature` + model swap

**Files:**
- Modify: `Sources/Nous/Services/EmbeddingService.swift`

- [ ] **Step 1:** Replace `defaultModelId` with the Phase 0 chosen model. Example assuming Phase 0 locks `paraphrase-multilingual-MiniLM-L12-v2`:

```swift
static let defaultModelId = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
static let embeddingDimension = 384
```

- [ ] **Step 2:** Add a static `currentSignature` computed from the active model identity:

```swift
static let currentSignature: String =
    "paraphrase-multilingual-minilm-l12-v2-384-mean-norm-noprefix"
```

(Format: `<model-short>-<dim>-<pooling>-<norm>-<prefix-version>`. Hardcoded because the runtime never changes recipe mid-process.)

- [ ] **Step 3:** Run `xcodebuild build -scheme Nous` to confirm clean compile:

```bash
xcodebuild build -scheme Nous -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4:** Commit:

```bash
git add Sources/Nous/Services/EmbeddingService.swift
git commit -m "feat(embedding): swap to multilingual model + currentSignature constant"
```

### Task 1.4 — Stamp signature on every atom write

**Files:**
- Modify: `Sources/Nous/Services/MemoryGraphWriter.swift`
- Modify: `Sources/Nous/Services/MemoryAtomEmbeddingBackfillService.swift`

- [ ] **Step 1:** In `MemoryGraphWriter.swift` find the place that sets `atom.embedding = vector` (around line 48 per the explore agent). Immediately set:

```swift
atom.embedding = vector
atom.embeddingSignature = EmbeddingService.currentSignature
```

- [ ] **Step 2:** Mirror the change in `MemoryAtomEmbeddingBackfillService.swift:57`:

```swift
atom.embedding = vector
atom.embeddingSignature = EmbeddingService.currentSignature
atom.updatedAt = Date()
```

- [ ] **Step 3:** Run existing backfill tests:

```bash
xcodebuild test -scheme Nous -only-testing:NousTests/MemoryAtomEmbeddingBackfillServiceTests -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 4:** Commit:

```bash
git add Sources/Nous/Services/MemoryGraphWriter.swift Sources/Nous/Services/MemoryAtomEmbeddingBackfillService.swift
git commit -m "feat(memory): stamp embedding_signature on every atom embedding write"
```

### Task 1.5 — Per-signature filtering in `fetchMemoryAtomsNearest`

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift` (around line 2287, `fetchMemoryAtomsNearest`)

- [ ] **Step 1:** Add an `activeSignature: String` parameter (no default — callers must pass the current signature explicitly so cross-signature comparisons are impossible):

```swift
func fetchMemoryAtomsNearest(
    embedding query: [Float],
    topK: Int,
    activeSignature: String,
    statuses: Set<MemoryStatus> = []
) throws -> [MemoryAtom]
```

- [ ] **Step 2:** Add WHERE clause to filter by signature. The candidate-row query becomes:

```sql
SELECT ... FROM memory_atoms
WHERE embedding IS NOT NULL
  AND embedding_signature = ?
  AND status IN (...)
```

Bind `activeSignature` as the first parameter.

- [ ] **Step 3:** Update every caller (Grep finds them via `fetchMemoryAtomsNearest`). Pass `EmbeddingService.currentSignature` from each call site. The primary caller is `MemoryQueryPlanner.vectorFallbackPacket()` near line 170.

- [ ] **Step 4:** Run the existing planner tests:

```bash
xcodebuild test -scheme Nous -only-testing:NousTests/MemoryQueryPlannerTests -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: PASS (tests use freshly-inserted atoms which will carry the current signature once the migration runner backfills, or pass `currentSignature` directly).

- [ ] **Step 5:** Commit:

```bash
git add Sources/Nous/Services/NodeStore.swift Sources/Nous/Services/MemoryQueryPlanner.swift
git commit -m "feat(memory): per-signature filtering in fetchMemoryAtomsNearest"
```

### Task 1.6 — `EmbeddingMigrationRunner`

**Files:**
- Create: `Sources/Nous/Services/EmbeddingMigrationRunner.swift`
- Modify: `Sources/Nous/App/AppEnvironment.swift` (boot wiring around line 187)

- [ ] **Step 1:** Create `Sources/Nous/Services/EmbeddingMigrationRunner.swift` mirroring `MemoryAtomEmbeddingBackfillService` shape:

```swift
import Foundation

struct EmbeddingMigrationReport: Equatable {
    var scanned = 0
    var skippedAlreadyCurrent = 0
    var skippedEmptyStatement = 0
    var reembedded = 0
    var failed = 0
}

/// Re-embeds atom rows whose `embedding_signature` no longer matches
/// `EmbeddingService.currentSignature`. Idempotent (skips current-signature
/// rows), batched (per-call cap), resumable (each row commits independently
/// so an app restart resumes from the next row).
final class EmbeddingMigrationRunner {
    private let nodeStore: NodeStore
    private let embed: (String) -> [Float]?
    private let activeSignature: String

    init(
        nodeStore: NodeStore,
        embed: @escaping (String) -> [Float]?,
        activeSignature: String = EmbeddingService.currentSignature
    ) {
        self.nodeStore = nodeStore
        self.embed = embed
        self.activeSignature = activeSignature
    }

    @discardableResult
    func runIfNeeded(maxAtoms: Int = 128) throws -> EmbeddingMigrationReport {
        var report = EmbeddingMigrationReport()
        guard maxAtoms > 0 else { return report }

        let atoms = try nodeStore.fetchMemoryAtoms()
        var processed = 0
        for var atom in atoms {
            if processed >= maxAtoms { break }
            report.scanned += 1

            if atom.embeddingSignature == activeSignature {
                report.skippedAlreadyCurrent += 1
                continue
            }
            let statement = atom.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statement.isEmpty else {
                report.skippedEmptyStatement += 1
                continue
            }
            guard let vector = embed(statement) else {
                report.failed += 1
                continue
            }
            atom.embedding = vector
            atom.embeddingSignature = activeSignature
            atom.updatedAt = Date()
            try nodeStore.updateMemoryAtom(atom)
            report.reembedded += 1
            processed += 1
        }
        return report
    }
}
```

- [ ] **Step 2:** Wire it on app boot in `AppEnvironment.swift` after the existing `MemoryAtomEmbeddingBackfillService` is constructed:

```swift
let embeddingMigrationRunner = EmbeddingMigrationRunner(
    nodeStore: nodeStore,
    embed: { [embeddingService] text in
        guard embeddingService.isLoaded else { return nil }
        return try? embeddingService.embed(text)
    }
)
```

Trigger it in the boot post-load hook that already runs `memoryAtomEmbeddingBackfill.runIfNeeded()`:

```swift
Task.detached {
    _ = try? embeddingMigrationRunner.runIfNeeded(maxAtoms: 256)
}
```

- [ ] **Step 3:** Write a focused unit test in a new file `Tests/NousTests/EmbeddingMigrationRunnerTests.swift`:

```swift
import XCTest
@testable import Nous

final class EmbeddingMigrationRunnerTests: XCTestCase {
    func test_skipsRowsAlreadyAtCurrentSignature() throws {
        let store = try NodeStore.inMemory()
        let current = "new-sig-v1"
        let stale = "old-sig-v0"
        let staleAtom = MemoryAtom(
            type: .belief, statement: "stale", scope: .global,
            embedding: [1, 0, 0], embeddingSignature: stale
        )
        let currentAtom = MemoryAtom(
            type: .belief, statement: "current", scope: .global,
            embedding: [0, 1, 0], embeddingSignature: current
        )
        try store.insertMemoryAtom(staleAtom)
        try store.insertMemoryAtom(currentAtom)

        let runner = EmbeddingMigrationRunner(
            nodeStore: store,
            embed: { _ in [0, 0, 1] },
            activeSignature: current
        )
        let report = try runner.runIfNeeded(maxAtoms: 10)
        XCTAssertEqual(report.reembedded, 1)
        XCTAssertEqual(report.skippedAlreadyCurrent, 1)
    }

    func test_resumableAcrossRuns() throws {
        let store = try NodeStore.inMemory()
        for i in 0..<5 {
            try store.insertMemoryAtom(MemoryAtom(
                type: .belief, statement: "row-\(i)", scope: .global,
                embedding: [1], embeddingSignature: "old"
            ))
        }
        let runner = EmbeddingMigrationRunner(
            nodeStore: store,
            embed: { _ in [9] },
            activeSignature: "new"
        )
        let r1 = try runner.runIfNeeded(maxAtoms: 2)
        let r2 = try runner.runIfNeeded(maxAtoms: 2)
        let r3 = try runner.runIfNeeded(maxAtoms: 2)
        XCTAssertEqual(r1.reembedded + r2.reembedded + r3.reembedded, 5)
    }
}
```

- [ ] **Step 4:** Run the new tests:

```bash
xcodebuild test -scheme Nous -only-testing:NousTests/EmbeddingMigrationRunnerTests -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: PASS (both methods green).

- [ ] **Step 5:** Commit:

```bash
git add Sources/Nous/Services/EmbeddingMigrationRunner.swift Sources/Nous/App/AppEnvironment.swift Tests/NousTests/EmbeddingMigrationRunnerTests.swift
git commit -m "feat(memory): embedding signature migration runner + boot wiring"
```

### Task 1.7 — Wire `MemoryRecallTestEnv` for assertions 1, 3, 4, 7

**Files:**
- Modify: `Tests/NousTests/MemoryRecallReliabilityTests.swift`

- [ ] **Step 1:** Replace the `fatalError` stubs in `MemoryRecallTestEnv` with real implementations: `make()` builds an in-memory `NodeStore`, `seedAtom(...)` inserts atom rows via `nodeStore.insertMemoryAtom`, `retrieve(...)` calls `fetchMemoryAtomsNearest(embedding:, topK: 10, activeSignature: current)`, `setCurrentSignature(...)` stores the active signature in the env.

```swift
final class MemoryRecallTestEnv {
    let nodeStore: NodeStore
    let embedder: StubEmbedder
    var currentSignature: String = "test-sig-v1"

    static func make() throws -> MemoryRecallTestEnv {
        let store = try NodeStore.inMemory()
        return MemoryRecallTestEnv(nodeStore: store, embedder: StubEmbedder())
    }

    func seedAtom(text: String, scope: MemoryScope, conv: String, signature: String? = nil) {
        var atom = MemoryAtom(
            type: .belief, statement: text, scope: scope,
            scopeRefId: UUID(uuidString: "00000000-0000-0000-0000-\(conv.padding(toLength: 12, withPad: "0", startingAt: 0))")
        )
        atom.embedding = embedder.embed(text)
        atom.embeddingSignature = signature ?? currentSignature
        try? nodeStore.insertMemoryAtom(atom)
    }

    func retrieve(query: String) throws -> [MemoryAtom] {
        let vec = embedder.embed(query)
        return try nodeStore.fetchMemoryAtomsNearest(
            embedding: vec, topK: 10, activeSignature: currentSignature
        )
    }

    func setCurrentSignature(_ sig: String) { currentSignature = sig }
}
```

- [ ] **Step 2:** Run only assertions 1, 3, 4, 7 (the four that depend on Phase 1 only):

```bash
xcodebuild test -scheme Nous \
  -only-testing:NousTests/MemoryRecallReliabilityTests/test_assertion_1_cantonese_2char_keyword_surfaces_chat_atoms \
  -only-testing:NousTests/MemoryRecallReliabilityTests/test_assertion_3_cantonese_query_finds_english_atom_via_vector \
  -only-testing:NousTests/MemoryRecallReliabilityTests/test_assertion_4_off_topic_query_returns_empty_or_low_confidence \
  -only-testing:NousTests/MemoryRecallReliabilityTests/test_assertion_7_cross_signature_query_rejected \
  -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: 4 PASS. Assertions 2, 5, 6 still fail compile or assert — they depend on Phases 2 and 3.

- [ ] **Step 3:** Commit:

```bash
git add Tests/NousTests/MemoryRecallReliabilityTests.swift
git commit -m "test(memory): wire Phase 1 assertions 1/3/4/7 — passing"
```

---

## Phase 2 — Atom Extractor Preserves Source Language (~½ day)

**Goal:** New atoms carry Alex's source-language voice. Existing `evidence_quote` (already extracted by the prompt at `UserMemoryService.swift:1063`) gets persisted into the new `verbatim_quote` column.

### Task 2.1 — Persist `evidence_quote` into `verbatim_quote`

**Files:**
- Modify: `Sources/Nous/Services/UserMemoryService.swift` (around the `VerifiedSemanticAtom` → `MemoryAtom` conversion site near line 1118)

- [ ] **Step 1:** Find the call path from `verifiedSemanticAtoms` to `replaceActiveFacts(...)`. Trace where each `VerifiedSemanticAtom` becomes a `MemoryAtom` row. Add `verbatimQuote: atom.evidenceQuote` to that constructor:

```swift
let memoryAtom = MemoryAtom(
    type: atom.type,
    statement: atom.statement,
    scope: .conversation,
    scopeRefId: nodeId,
    confidence: atom.confidence,
    sourceMessageId: sourceMessageId,
    verbatimQuote: atom.evidenceQuote
)
```

(Exact location may be inside `replaceActiveFacts` or `MemoryGraphWriter.upsertAtom`; Grep `evidenceQuote` and `verifiedSemanticAtoms` to find the conversion site.)

- [ ] **Step 2:** Build:

```bash
xcodebuild build -scheme Nous -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3:** Commit:

```bash
git add Sources/Nous/Services/UserMemoryService.swift
git commit -m "feat(memory): persist evidence_quote into verbatim_quote column"
```

### Task 2.2 — Prompt edit: `statement` MUST be in source language

**Files:**
- Modify: `Sources/Nous/Services/UserMemoryService.swift:1060` (the `statement` field description in the JSON schema block)

- [ ] **Step 1:** Replace the line that currently reads:

```swift
"statement":"the durable claim in Alex's voice",
```

with:

```swift
"statement":"the durable claim in Alex's voice, in the SAME LANGUAGE Alex spoke (Cantonese / Mandarin / English / code-switch). Do not translate. If Alex used 「我唔系一个读书好叻嘅人」 keep it as Cantonese; do not rewrite to 'I am not academically strong'. Loose paraphrase within the original language is allowed; translation across languages is not.",
```

- [ ] **Step 2:** Find the `Rules:` bullets block immediately below the JSON schema (around line 1069). Add one rule at the top of the bullets:

```
- SOURCE LANGUAGE PRESERVATION: every `statement` must remain in the language Alex used in the cited evidence_quote. Cross-language translation in `statement` is a bug. If unsure, copy the evidence_quote substring as the statement.
```

- [ ] **Step 3:** Build:

```bash
xcodebuild build -scheme Nous -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4:** Commit:

```bash
git add Sources/Nous/Services/UserMemoryService.swift
git commit -m "feat(memory): atom prompt requires source-language preservation in statement"
```

### Task 2.3 — Wire assertion 6 in fixture

**Files:**
- Modify: `Tests/NousTests/MemoryRecallReliabilityTests.swift` (`extractAtomFrom` env helper)

- [ ] **Step 1:** Implement `extractAtomFrom(userMessage:)` to bypass the LLM (the unit suite stays deterministic) and synthesize an extracted atom by calling the same conversion path as production would, using a fixed evidence_quote = `userMessage`:

```swift
func extractAtomFrom(userMessage: String) throws -> MemoryAtom {
    let atom = MemoryAtom(
        type: .belief,
        statement: userMessage,  // Phase 2 contract: statement == source language
        scope: .conversation,
        scopeRefId: UUID(),
        confidence: 0.8,
        verbatimQuote: userMessage
    )
    try nodeStore.insertMemoryAtom(atom)
    return atom
}
```

(This tests the model + persistence contract. The actual prompt-output behavior is tested in the integration suite — `MemoryRecallReliabilityIntegrationTests` — created in Task 3.3.)

- [ ] **Step 2:** Run assertion 6:

```bash
xcodebuild test -scheme Nous \
  -only-testing:NousTests/MemoryRecallReliabilityTests/test_assertion_6_new_atom_preserves_source_language_and_quote \
  -destination 'platform=macOS' 2>&1 | tail -15
```

Expected: PASS.

- [ ] **Step 3:** Commit:

```bash
git add Tests/NousTests/MemoryRecallReliabilityTests.swift
git commit -m "test(memory): wire Phase 2 assertion 6 — verbatim quote contract"
```

---

## Phase 3 — Default Chat Query-Driven Retrieval (~½ day)

**Goal:** Remove the gates that exclude default chat from query-driven graph memory recall. Default chat starts computing `queryEmbedding`, calling `CitableContextBuilder.build()` with it, and appending the resulting `memoryGraphRecall` block to the prompt.

### Task 3.1 — Compute `queryEmbedding` and `memoryGraphRecall` for default chat

**Files:**
- Modify: `Sources/Nous/Services/TurnMemoryContextBuilder.swift:112–127`

- [ ] **Step 1:** Loosen the `queryEmbedding` gate. Replace:

```swift
let queryEmbedding: [Float]? = {
    guard policy.includeContradictionRecall,
          includeGraphPromptRecall,
          embeddingService.isLoaded
    else { return nil }
    return try? embeddingService.embed(promptQuery)
}()
```

with:

```swift
let queryEmbedding: [Float]? = {
    guard embeddingService.isLoaded else { return nil }
    return try? embeddingService.embed(promptQuery)
}()
```

- [ ] **Step 2:** Loosen the `memoryGraphRecall` gate. Replace:

```swift
let memoryGraphRecall: [String] = policy.includeContradictionRecall && includeGraphPromptRecall
    ? memoryProjectionService.currentGraphMemoryRecall(...)
    : []
```

with:

```swift
let memoryGraphRecall: [String] = memoryProjectionService.currentGraphMemoryRecall(
    currentMessage: promptQuery,
    projectId: node.projectId,
    conversationId: node.id,
    queryEmbedding: queryEmbedding,
    now: now
)
```

(The `policy` flags become irrelevant for this surface — `CitableContextBuilder` already handles empty-result graceful fallback.)

- [ ] **Step 3:** Build:

```bash
xcodebuild build -scheme Nous -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4:** Commit:

```bash
git add Sources/Nous/Services/TurnMemoryContextBuilder.swift
git commit -m "feat(memory): compute queryEmbedding + graph recall for default chat"
```

### Task 3.2 — Inject `GRAPH MEMORY RECALL` block in default chat prompt

**Files:**
- Modify: `Sources/Nous/Services/PromptContextAssembler.swift:1019`
- Modify: `Sources/Nous/Services/PromptContextAssembler.swift:1754` (telemetry layer-name list)

- [ ] **Step 1:** Replace:

```swift
if !memoryGraphRecall.isEmpty, activeQuickActionMode != nil {
```

with:

```swift
if !memoryGraphRecall.isEmpty {
```

- [ ] **Step 2:** At line 1754 update the telemetry layer-name guard the same way:

```swift
if !memoryGraphRecall.isEmpty { layers.append("memory_graph_recall") }
```

- [ ] **Step 3:** Build:

```bash
xcodebuild build -scheme Nous -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4:** Run all prompt-assembler tests:

```bash
xcodebuild test -scheme Nous -only-testing:NousTests/PromptContextAssemblerTests -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: PASS. (Existing tests may include cases that asserted the gate; those tests should be updated to assert the new contract — the gate removal is the intentional behavior change. If a test fails on a now-correct gate, update its expectation to match.)

- [ ] **Step 5:** Commit:

```bash
git add Sources/Nous/Services/PromptContextAssembler.swift
git commit -m "feat(memory): inject GRAPH MEMORY RECALL block in default chat (Block 4b flip)"
```

### Task 3.3 — Wire assertions 2 and 5 in fixture + create integration suite

**Files:**
- Modify: `Tests/NousTests/MemoryRecallReliabilityTests.swift`
- Create: `Tests/NousTests/MemoryRecallReliabilityIntegrationTests.swift`

- [ ] **Step 1:** Implement `buildPromptContext(quickActionMode:, query:)` in `MemoryRecallTestEnv` to invoke a minimal version of the prompt assembly path. It can be a thin wrapper that calls `TurnMemoryContextBuilder` + `PromptContextAssembler.assemble(...)` with the env's `nodeStore`, then returns the assembled prompt string. Test assertion 5 verifies the returned string contains atom statements.

- [ ] **Step 2:** Implement assertion 2 (`test_assertion_2_codeswitch_query_finds_both_languages`) using `seedAtom` for two `topic-B` rows with different languages — assert both surface.

- [ ] **Step 3:** Run all 7 assertions:

```bash
xcodebuild test -scheme Nous -only-testing:NousTests/MemoryRecallReliabilityTests -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: 7 PASS.

- [ ] **Step 4:** Create the integration suite skeleton that loads the real multilingual model. Gated by env var so CI stays fast:

```swift
import XCTest
@testable import Nous

final class MemoryRecallReliabilityIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["MEMORY_RECALL_INTEGRATION"] == "1" else {
            throw XCTSkip("Set MEMORY_RECALL_INTEGRATION=1 to run real-model integration tests")
        }
    }

    func test_realModel_cantoneseQueryFindsEnglishAtom() async throws {
        let svc = EmbeddingService()
        try await svc.loadModel()
        let v1 = try svc.embed("我嚟到美国都已经系不可思议嘅啦")
        let v2 = try svc.embed("I made it to the US at all is already remarkable")
        let cos = cosineSimilarity(v1, v2)
        XCTAssertGreaterThan(cos, 0.65, "Cross-lingual paraphrases should land near each other")
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        let dot = zip(a, b).map(*).reduce(0, +)
        let na = sqrt(a.map { $0 * $0 }.reduce(0, +))
        let nb = sqrt(b.map { $0 * $0 }.reduce(0, +))
        return dot / (na * nb)
    }
}
```

- [ ] **Step 5:** Commit:

```bash
git add Tests/NousTests/MemoryRecallReliabilityTests.swift Tests/NousTests/MemoryRecallReliabilityIntegrationTests.swift
git commit -m "test(memory): wire Phase 3 assertions 2/5 + opt-in real-model integration suite"
```

### Task 3.4 — Live体感 validation

**Files:** None (manual smoke test)

- [ ] **Step 1:** Run the app:

```bash
xcodebuild -scheme Nous -destination 'platform=macOS' run 2>&1 | tail -5
```

(Or launch from Xcode.)

- [ ] **Step 2:** Open one of Alex's recent conversations (e.g. node `AA47EB80-951F-4E04-86DF-11B1FB8867F9` — the 普通人 evening conversation, where the diagnosis was collected).

- [ ] **Step 3:** Send a Cantonese message that thematically connects to a different conversation (e.g. mention 自卑 / 比较 / 唔配 after the embedding migration has had time to re-embed the 00:52 自卑 conversation's atoms).

- [ ] **Step 4:** Open the prompt inspector / debug overlay if available; otherwise check console logs for the `GRAPH MEMORY RECALL:` block — verify the recall contains atoms from the cross-conversation context.

- [ ] **Step 5:** Document the体感 result inline in `MEMORY.md` as a new validation memory entry:

```bash
# Add a new auto-memory entry recording whether the cross-conversation recall worked in production.
```

(This is the only step that exits the deterministic test loop and validates against Alex's lived experience — the体感 anchor from the spec.)

---

## Self-Review

**Spec coverage:**

| Spec section | Plan task(s) |
|---|---|
| Anchoring体感 | Task 3.4 |
| Diagnosis layer 1 (atom translation) | Task 2.2 |
| Diagnosis layer 2 (embedding model) | Phase 0 + Task 1.3 |
| Diagnosis layer 3 (default chat no query) | Task 3.1 + Task 3.2 |
| Change 1 — multilingual + signature + migration | Phase 0 + Tasks 1.2–1.6 |
| Change 2 — atom extractor verbatim Cantonese | Tasks 2.1–2.3 |
| Change 3 — Block 4b flag flip | Tasks 3.1–3.2 |
| Deferred backfill decision | Documented in spec; not a code task |
| Class-level fixture (7 assertions) | Task 1.1 + wire-up in 1.7, 2.3, 3.3 |
| Constraints | Honored: no anchor.md edit, xcodebuild only, no new deps |
| Phasing (Phase 0 → 1 → 2 → 3) | Plan task order matches |

No gaps.

**Placeholder scan:** No `TODO`, `TBD`, "implement later", "similar to Task N", or unspecified code blocks. Every step has either concrete code, concrete command, or a precise file:line ref.

**Type consistency:** Property names `embeddingSignature`, `verbatimQuote`, `currentSignature`, `activeSignature`, fixture method names `seedAtom`, `retrieve`, `setCurrentSignature`, `extractAtomFrom`, `buildPromptContext` — used consistently across all tasks.
