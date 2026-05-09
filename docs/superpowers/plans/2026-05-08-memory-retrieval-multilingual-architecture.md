# Memory Retrieval Multilingual Architecture — Long-Term Stability Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **This plan was reviewed by `/plan-eng-review` on 2026-05-08 with codex outside voice.** Decisions D1–D7 below are locked. Phase ordering was revised after review (lexical-first); see Phasing section.

**Goal:** Restore trust in Nous memory retrieval for Alex's primary use case (Cantonese / Mandarin / English code-switching with mixed personal-chat + curated-source corpus). Replace single-pathway English-only vector retrieval with a multilingual hybrid pipeline that can survive future model swaps.

**Bar:** 長期安穩, not 即時止血. Patches that solve today's symptom but leave the same class of failure latent are explicitly out of scope.

**Tech Stack:** Swift 6, MLX Swift / MLXEmbedders, SQLite (via existing `NodeStore`), XCTest, no new third-party dependencies expected (FTS5 is built into SQLite).

---

## Failure Evidence

Screenshot 2026-05-08: User mid-conversation about roommate problems in Cantonese / Mandarin code-switching. Memory retrieval surfaced two citations:

1. **Chat: `打朋評`** — plausibly relevant by chat title token overlap.
2. **Source: `Kai Trump on Donald Trump's 3rd Term, Dating with 24/7 Secret Service, Golfing w/ the P...`** — fully irrelevant English news article about an unrelated political topic.

**Crucially:** the user's sidebar shows a previous chat literally titled `室友返反應差生...` (roommate reaction problems). That chat was **not retrieved**. So retrieval failed in two directions simultaneously:

- **False positive:** Kai Trump article scored high enough to enter top-K against a Cantonese roommate query.
- **False negative:** A directly relevant chat with `室友` in the title was not surfaced.

## Root Cause — LEADING HYPOTHESIS, PENDING PHASE -1 TRACE

> **Codex review challenge accepted:** Original plan asserted CJK embedding noise as confirmed root cause. Codex correctly noted this is plausible, not proven. Phase -1 Forensic Trace (added below) empirically validates before architecture commits.

Five baked-in single-language assumptions are the leading hypothesis:

1. **`Sources/Nous/Services/EmbeddingService.swift:17`** — `defaultModelId = "sentence-transformers/all-MiniLM-L6-v2"`. Trained on English. CJK characters tokenized one-per-token by BERT's pre-tokenizer but produce uninformative embeddings.

2. **`Sources/Nous/Services/VectorStore.swift:329-346`** — Hardcoded thresholds (`semanticFloor = max(0.42, top - 0.28)`, `hasStrongTopHit ≥ 0.58`, `solidMatchCount ≥ 0.50`) calibrated for English MiniLM. Not portable across embedding models.

3. **`Sources/Nous/Services/VectorStore.swift:142-219`** — Single-pathway vector-only retrieval. Short queries (5–10 chars Cantonese) provide too little signal regardless of model quality. No lexical fallback exists.

4. **`Sources/Nous/Services/VectorStore.swift:264-282`** — `mergedChatCitationCandidates` ranks chat nodes and source chunks together on raw cosine similarity with no type-aware penalty. Public source content can crowd out private chat memory at equal scores. This regression entered with `edf0f14 Harden memory trust and source connections`.

5. **`Tests/NousTests/VectorStoreTests.swift`** — 39 LOC, no multilingual fixtures, no cross-type ranking tests. Silent regression had no detection gate.

**Alternate hypotheses Phase -1 will rule in or out:**
- 室友 chat may have no embedding stored (older than EmbeddingService rollout, commit `54cd82d`)
- 室友 chat may be excluded by project filter at retrieval boundary
- Citation assembly limit may have truncated it before display
- Title-only signal may be invisible to current retrieval (which indexes content, not title)

## Constraints

- Do **not** modify `Sources/Nous/Resources/anchor.md` (frozen — see `AGENTS.md:39, 131`).
- Do **not** add third-party dependencies. SQLite FTS5 is built-in and acceptable.
- Do **not** wire feature flags or backwards-compatibility shims for the old single-language pipeline; replace it cleanly.
- Schema migration must include `embedding_signature` (NOT just version) capturing model_id + dim + pooling + normalization + instruction_prefix as a single composite identifier. Cosine scores from different signatures are incomparable; this is enforced.
- Re-embedding the corpus is acceptable and expected. Migration must enumerate failure semantics (restart, partial batch, user interrupt, corrupted blob, model download failure, rollback).
- FTS5 must index titles separately from content with field-level BM25 weighting (titles weighted higher than body).
- Plan must produce a multilingual regression test fixture before any model change ships, using **deterministic fake embeddings** for retrieval-mechanics unit tests. Real-model integration tests are opt-in (`xcodebuild` scheme tag).
- Keep `MLXEmbedders` Swift package as the embedding runtime. Phase 0 verifies model architecture, tokenizer, pooling, safetensors path, memory footprint, latency before locking choice.

## Decisions Locked from Eng Review (2026-05-08)

- **D1**: Full 4-move scope (vs reduced or split). Rationale: 長期安穩 bar.
- **D2**: Phase 0 verifies MLX Swift XLM-RoBERTa support before locking model. Bge-m3 only chosen after deep compatibility verification (not just architecture name match).
- **D3 (revised by D7)**: Mid-flight migration uses **per-version querying** — queries hit only same-signature rows; un-migrated rows reach via lexical lane. Banner UI optional.
- **D4**: Type-aware quotas routed through `QuickActionMemoryPolicy` (per-mode overridable). Default 3 chat / 2 source slots; modes that want different mix override.
- **D5**: Codex outside voice run; findings folded into this plan.
- **D6**: Phase -1 Forensic Trace added before architecture commits.
- **D7**: Phase ordering revised — Move 1 (hybrid) + Move 3 (type-aware) + Move 4 (regression fixture) ship first; Move 2 (model swap) ships in Phase 2 only after Phase 1 measured.

---

## Phase -1 — Forensic Trace (COMPLETE — 2026-05-08)

**Status:** Done. Memo: `~/.gstack/projects/alexko0421-Nous/forensic-trace-2026-05-08.md`.

**Verdict:** CJK noise + dead lexical infrastructure + missing title indexing + chunk-volume imbalance. All four contribute. Trivial alternatives ruled out.

**Key findings folded back into plan:**
- 室友 chat HAS embedding (1536 bytes / 384-dim) — refutes missing-embedding hypothesis
- 室友 chat and active conversation both have `projectId=NULL` — refutes scope-filter hypothesis
- `messages_fts` virtual table EXISTS with INSERT + DELETE triggers populating 806 rows; **functionally broken for CJK** (`MATCH '室友'` → 0 hits, `MATCH 'roommate'` → 2 hits) and **not wired into retrieval** (zero `messages_fts` references in `Sources/`). Materially shrinks Move 1.
- `messages_fts` indexes content only, NOT titles. Title is exactly where 室友 signal lives strongest.
- 104 source chunks vs 52 chat embeddings → 2:1 ranking pool imbalance.

**Original Phase -1 spec preserved below for reference.**

---

**Original spec:** No code changes. ~30-60 min. Output: a written memo confirming or refuting the leading hypothesis.

**Steps:**

- [ ] Identify the conversation node ID for the `室友返反應差生...` chat from production DB (or local dev DB if production unavailable for this user).
- [ ] Verify `nodes.embedding IS NOT NULL` for that node. If null: missing-embedding case, scope changes.
- [ ] Identify the conversation node ID + recent message used as the retrieval query at the time of the screenshot. Re-embed that query string with current MiniLM-L6-v2.
- [ ] Compute cosine similarity between the query embedding and the 室友 chat's stored embedding. **Record exact score.**
- [ ] Compute cosine similarity between the query embedding and the Kai Trump source chunks. **Record exact scores.**
- [ ] Check `searchForChatCitations` parameters at the time: `topK`, `excludeIds`, `candidatePoolSize`. Walk through `surfacedChatCitations` filter logic with actual scores; identify exact gate that excluded 室友 (semantic floor, long-gap floor, or top-K cutoff).
- [ ] Verify project scope filter behavior — is 室友 chat in the same project as the active conversation? If not, retrieval correctly excluded it (different bug then).
- [ ] Check `UserMemoryService.citableEntryPool(...)` retrieval path (per prior learning `nous-retrieval-entry-point`). Was 室友 chat in the broader citable pool but not in the chat-citation chips? Different bug class.
- [ ] Add diagnostic logging temporarily to `VectorStore.searchForChatCitations` printing per-result `(node.id, similarity, lane, type)`. Reproduce the failing case. Save log to memo.

**Memo deliverable:** `~/.gstack/projects/alexko0421-Nous/forensic-trace-2026-05-08.md`

**Decision gate:**
- If **CJK noise confirmed** (low cosines for 室友, ~equal cosines for Kai Trump and 室友): proceed to Phase 0 + 1 as planned.
- If **missing embedding**: Phase 1 narrows to "ensure all nodes have embeddings + add lexical fallback for those that don't." Skip model swap in Phase 2 unless other evidence emerges.
- If **project filter / scope issue**: this is a different bug class; pause this plan and write a focused fix plan.
- If **title-only signal**: Phase 1 (lexical with title weighting) directly fixes; model swap deprioritized.

---

## The Four Architectural Moves

### Move 1 — Hybrid retrieval (vector + lexical, fused with RRF) — REVISED PER PHASE -1

**Why structural:** Embedding models always have distribution gaps (short queries, code-switch, rare names, novel terminology). Lexical retrieval rescues the cases vector cannot.

**Pre-existing infrastructure (Phase -1 finding):**

- `messages_fts(messageId, nodeId, content)` virtual table — already exists, populated.
- `messages_fts_insert` and `messages_fts_delete` triggers — already exist.
- Default tokenizer (no explicit `tokenize` clause = `unicode61` with default config) — **broken for CJK queries**.
- **Zero references in `Sources/`** — table is dead infrastructure, never read.

**Implementation surface (revised):**

- **`Sources/Nous/Services/LexicalIndex.swift` (NEW):** SQLite FTS5 wrapper. Re-creates `messages_fts` with new tokenizer (`DROP` + `CREATE` + repopulate from `messages` table) AND adds new `nodes_fts(nodeId, type, title)` virtual table for title indexing AND adds new `source_chunks_fts(chunkId, sourceNodeId, text)` for source chunk lexical lookup.
  - **Field separation strategy:** Use parallel FTS5 tables (one per row source) rather than denormalize. Cleaner triggers, simpler queries, easier to drop/recreate during tokenizer migration. BM25 weight tuning happens at the `searchHybrid` fusion layer rather than per-table.
  - **Cross-table fusion weights:** node title match weight = 3.0, message content match weight = 1.0, source chunk match weight = 0.6 (down-weighted because public sources should not displace private chat lexical hits at equal rank).
  - **Tokenizer choice (Phase 0 benchmark, plan locks one):**
    - Option A: `unicode61` with explicit `tokenchars` and `categories 'L* N* M* Co'` — fast but still doesn't segment Chinese into 2-char tokens.
    - Option B: `trigram` — Chinese-friendly without language tagging. Index size ~2-3x. Changes BM25 score semantics. **Initial preference based on Phase -1 evidence: trigram.**
    - Phase 0 deliverable: benchmark on the 8 locked golden cases from Move 4 (which we can run before any model swap), document score distributions, lock choice.
  - **NEW: UPDATE trigger.** Phase -1 confirmed only INSERT + DELETE triggers exist on `messages_fts`. Move 1 adds `messages_fts_update` (and equivalents for the two new FTS5 tables) so message edits don't drift the index.
  - All FTS5 maintenance MUST run inside the same `db.transaction { ... }` block as the source row write. Bundle existing TODO `Audit NodeStore.deleteNode cascade atomicity` (2026-04-22) here.
- **`Sources/Nous/Services/QueryNormalizer.swift` (NEW):** Applied before BOTH lanes. Performs: NFC unicode normalization, full-width → half-width, traditional ↔ simplified Chinese mapping (one-direction is fine, default trad→simp), strip emoji, normalize CJK punctuation. Deterministic, no model needed.
- **`Sources/Nous/Services/VectorStore.swift`:**
  - New `searchHybrid(queryText: String, queryEmbedding: [Float], topK: Int, ...) throws -> [SearchResult]` that runs vector lane + lexical lane separately, applies per-lane confidence gates, then fuses.
  - **Per-lane gates BEFORE fusion (Codex finding):** Vector lane drops if no result above its semantic floor; lexical lane drops if no result above BM25 score floor. RRF only fuses lanes that both produced confident hits, OR uses the one lane that did with its own ranking.
  - **RRF with chunk-granularity normalization:** scores per result divided by `log(1 + token_count / median_token_count)` so short titles don't always dominate long source chunks. RRF `k=60` (industry default).
  - `searchForChatCitations` switches to call `searchHybrid` with `QuickActionMemoryPolicy` quotas (D4).

### Move 2 — Multilingual embedding model + signature column

**Why structural:** Current model is fundamentally wrong-typed for the use case. Schema must record full signature so future swaps don't silently produce comparable-looking-but-incomparable embeddings.

**Schema migration:**

- Add `embedding_signature TEXT NOT NULL DEFAULT 'minilm-l6-v2-mean-norm-noprefix'` to all tables holding embeddings (`nodes`, `source_chunks`, any others audited in Phase 0).
- Format: `<model_id_short>-<dim>-<pooling>-<norm>-<prefix_version>`. Examples:
  - Current: `minilm-l6-v2-384-mean-norm-noprefix`
  - bge-m3 default: `bge-m3-1024-cls-norm-noprefix`
  - bge-m3 with retrieval prefix: `bge-m3-1024-cls-norm-bgePassageV1`
- `EmbeddingService.currentSignature` is the single source of truth. `NodeStore.upsertNode(...)` and chunk equivalents read it; migration script reads it.
- **Per-version querying enforcement:** Vector search queries with signature S only compare against rows with same signature. Cross-signature comparisons are forbidden at the query layer. During migration, un-migrated rows are unreachable by vector lane but still reachable via lexical lane.
- Add migration runner `EmbeddingMigrationRunner` with idempotency, resumability, progress reporting, and these failure semantics:
  - **App restart mid-migration:** runner resumes from last committed batch.
  - **Partial batch failure:** failed batch logged, skipped, retried on next run.
  - **User interrupt (app close):** runner gracefully halts at batch boundary.
  - **Corrupted embedding blob:** affected row marked `embedding_signature='migration_failed'`, surfaced in HarnessHealth.
  - **Model download failure:** runner aborts with clear error; existing rows untouched.
  - **Rollback:** new old-signature rows are NOT deleted during migration; if rollback needed, set `EmbeddingService.currentSignature` back to old value, all old rows usable, new-signature rows become unreachable.

**Model selection (gated by Phase 0 deep compatibility check):**

| Model | Dim | Verification depth required (Codex challenge) |
|---|---|---|
| `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` | 384 | Drop-in (BERT-base same family). Verify: tokenizer + mean pooling supported. |
| `intfloat/multilingual-e5-base` | 768 | XLM-RoBERTa. Verify: tokenizer, mean pooling, normalization, **instruction prefix support** (`query:` / `passage:`). |
| `BAAI/bge-m3` | 1024 | XLM-RoBERTa. Verify: tokenizer, **CLS pooling vs mean** (bge uses CLS by default), normalization, safetensors conversion path, memory footprint at first load (~2GB), inference latency on M-series, and **whether MLXEmbedders implements the exact embedding recipe** (not just architecture name match). |

**Decision rule:** Phase 0 produces a memo with all three rows scored on each verification axis. Plan locks the highest-scoring model that passes all checks. Falls back conservatively to MiniLM-L12 multilingual if uncertainty remains.

### Move 3 — Type-aware ranking via QuickActionMemoryPolicy

**Why structural:** Public source citations and private chat memory serve different purposes. They should not compete on identical cosine similarity. Quotas are policy, not retrieval mechanics — they belong where mode policy already lives.

**Implementation surface:**

- Extend `QuickActionMemoryPolicy` with:
  ```swift
  var citationChatQuota: Int = 3
  var citationSourceQuota: Int = 2
  var sourceDisplacementMargin: Float = 0.05  // source must beat chat similarity by ≥ this to displace it
  ```
- Per-mode defaults (initial guesses, refined empirically):
  - Default / 倾偈 / 日常: chat=3, source=2
  - Plan / Direction: chat=2, source=3 (more research-heavy)
  - Brainstorm: chat=2, source=2 (balanced)
- `mergedChatCitationCandidates` (`VectorStore.swift:264`) refactored to bucket by `node.type` then enforce quotas + per-bucket floor.
- `searchHybrid` reads quotas from passed-in `QuickActionMemoryPolicy`.
- **Note (Codex challenge):** Quotas alone can force irrelevant chats over highly relevant sources. The `sourceDisplacementMargin` is the safety valve — if a source's similarity exceeds the lowest-ranked chat by margin, it can displace despite quota. This handles "actually the source is much more relevant" cases while keeping default-bias toward private chat.

### Move 4 — Multilingual regression test fixture (TDD-FIRST)

**Why structural:** Silent retrieval regressions have no detection currently. Make the failure mode permanently visible. Ship FIRST so all subsequent moves have a contract.

**Implementation surface:**

- **`Tests/NousTests/MultilingualRetrievalRegressionTests.swift` (NEW)** — fast tests, deterministic fake embeddings only. Tests retrieval mechanics (RRF, quotas, gates, normalization), not model quality.
- **`Tests/NousTests/MultilingualRetrievalIntegrationTests.swift` (NEW, opt-in via `MULTILINGUAL_RETRIEVAL_INTEGRATION=1` env var)** — slow tests using real loaded model. Tests model quality on golden cases. Run manually before each model change ships.

- **Fixture corpus (locked, ~15 nodes):**
  - 5 Cantonese conversations: roommate (`室友返反應差生`), career (`轉工掙扎`), Hong Kong food, family, money.
  - 3 Mandarin conversations: 决策效率, 朋友圈观察, 阅读心得.
  - 3 English conversations: career planning, dating context, learning Spanish.
  - 2 mixed code-switch conversations.
  - 2 English source articles: one tech essay, one political news (Kai Trump-style).

- **Golden cases (locked):**

  | # | Query | Expected top-3 | Must NOT include |
  |---|---|---|---|
  | 1 | `室友又惡咗我啊` (Cantonese, roommate) | 室友返反應差生 in top-1 | Kai Trump |
  | 2 | `roommate 真係搞我` (code-switch) | 室友返反應差生 in top-3 | political news |
  | 3 | `我嘅career點走好` (Cantonese career) | 轉工掙扎 in top-3 | unrelated chats |
  | 4 | `should I switch jobs` (English) | 轉工掙扎 OR career planning in top-3 | — |
  | 5 | `今天午餐什麼好` (Mandarin, no relevant content) | empty OR low-confidence flag | random source |
  | 6 | `跟朋友聚會` (broad, no specific match) | low-confidence flag | Kai Trump article |
  | 7 | Empty query | empty result | — |
  | 8 | `室友` (single 2-char query, lexical-only signal) | 室友返反應差生 in top-1 via lexical lane | Kai Trump |

- **Test discipline (Codex finding):**
  - Unit tests inject hand-crafted embeddings into a `FakeEmbeddingService` so retrieval mechanics are deterministic + fast (~ms per test).
  - Integration tests gated by env var, run real model, validate golden cases on actual quality.
  - CI runs unit tests only. Integration suite is a manual gate before model swap or threshold recalibration.

---

## Phasing (REVISED per D7 + Phase -1 outcomes)

```
Phase -1 — Forensic Trace ✓ DONE (2026-05-08)
  - Memo: ~/.gstack/projects/alexko0421-Nous/forensic-trace-2026-05-08.md
  - Verdict: CJK noise + dead lexical infra + missing title indexing + chunk-volume imbalance
  - Decision gate: PROCEED to Phase 0 + 1 with Move 1 scope reduced

Phase 0 — Research & audit ✓ MOSTLY DONE (2026-05-08)
  - ✓ Audit corpus size: 52 conversations, 4 sources, 104 source chunks, 1 NULL embedding (placeholder)
  - ✓ Audit citableEntryPool: consumes upstream nodeHits, does NOT do vector lookup
  - ✓ Audit RealtimeVoiceSession: separate retrieval path, no impact on this plan
  - ✓ Verify FTS5 triggers: INSERT + DELETE exist; UPDATE missing (Move 1 adds)
  - ⏳ DEFERRED to Phase 2 prep: MLXEmbedders deep compatibility for candidate multilingual models
  - ⏳ DEFERRED to Move 1 implementation: FTS5 unicode61+tokenchars vs trigram benchmark on Move 4 fixture (preferred: trigram)

Phase 1 — Lexical foundation (~1.5-2 days) [REORDERED]
  - Move 4: Write multilingual regression fixture FIRST with FakeEmbeddingService (TDD; will fail)
  - Move 1: LexicalIndex.swift + FTS5 virtual tables + triggers + QueryNormalizer
  - Move 1: VectorStore.searchHybrid with per-lane gates + chunk-length normalization + RRF
  - Move 3: QuickActionMemoryPolicy quotas + sourceDisplacementMargin
  - Wire searchForChatCitations through searchHybrid
  - Run Move 4 fixture; expect 室友 case to PASS via lexical lane (independent of model swap)
  - MEASURE: forensic trace cases pre/post, document delta

Phase 2 — Model swap (~1-1.5 days) [DEPRIORITIZED, only if Phase 1 leaves gaps]
  - Schema migration: embedding_signature column
  - Migration runner with full failure semantics
  - EmbeddingService model swap + per-version querying enforcement
  - Re-embed corpus
  - Re-run Move 4 fixture; expect quality improvement on edge cases
  - Real-model integration test suite passes

Phase 3 — Polish (~0.5 day) [as needed]
  - Threshold recalibration if Move 2 shipped
  - HarnessHealth surfaces for migration status
  - Final fixture pass on all golden cases
```

**Total estimate (revised per Codex): 3-5 working days.** Original 2-3 days was optimistic given depth uncovered.

---

## Coverage Diagram (from eng review)

```
CODE PATHS                                                  USER FLOWS
[+] EmbeddingService.swift                                    [+] Cantonese roommate query
  ├── loadModel() — model swap (Phase 2)                        ├── [GAP][CRITICAL] 室友 chat MUST be in top-3
  ├── embed() — embedding call                                  │   (regression fixture case 1)
  ├── currentSignature (NEW) — fail-loud signature              ├── [GAP][CRITICAL] Kai Trump must NOT appear
  └── currentModelDescriptor (NEW) — model recipe spec          └── [GAP] Code-switch query also surfaces 室友

[+] VectorStore.swift                                        [+] English query
  ├── searchHybrid() (NEW)                                      ├── [GAP] Discussed topic appears in top-3
  │   ├── [GAP][CRITICAL] RRF fuses both lanes correctly        └── [GAP] Out-of-corpus query → empty/flagged
  │   ├── [GAP][CRITICAL] Per-lane confidence gate
  │   ├── [GAP] Empty FTS lane → vector-only fallback         [+] Lexical-only short query
  │   └── [GAP] Chunk-length normalization                      └── [GAP][CRITICAL] "室友" 2-char query hits
  ├── mergedChatCitationCandidates() (REFACTORED)                  室友 chat via FTS5
  │   ├── [GAP] Quotas honored per QuickActionPolicy
  │   ├── [GAP] sourceDisplacementMargin works                [+] Migration mid-flight
  │   └── [GAP] Floor enforced per type                         ├── [GAP][CRITICAL] App opens during re-embed:
  └── surfacedChatCitations() — re-tuned thresholds             │   per-version querying works, lexical fills gaps
                                                                └── [GAP] Migration interrupted, resume completes
[+] LexicalIndex.swift (NEW)
  ├── FTS5 INSERT/UPDATE/DELETE triggers                     [+] Voice retrieval (Phase 0 audit)
  │   └── [GAP][CRITICAL] Run inside parent transaction         └── [GAP] Voice query gets same retrieval fix
  ├── Title field weighted higher than content
  └── Tokenizer choice (Phase 0 benchmark)                   [+] Forensic Trace memo
                                                                └── No test (output is documentation)
[+] QueryNormalizer.swift (NEW)
  ├── NFC + width + simp/trad + emoji + punctuation
  └── [GAP] Round-trip identity for already-normalized

[+] EmbeddingMigrationRunner (NEW, Phase 2)
  ├── [GAP] Idempotency (resume after kill)
  ├── [GAP] Progress reporting
  ├── [GAP] Concurrent write handling
  └── [GAP] Each failure semantic enumerated above

[+] QuickActionMemoryPolicy (extended)
  └── [GAP] Per-mode quotas honored end-to-end

COVERAGE TARGETS:
  Code paths: 18 paths
  User flows: 9 flows
  CRITICAL gaps (regression-class): 7 — all targeted by fixture cases 1-8

QUALITY: All entries currently ★ (none yet implemented). Move 4 fixture sets the bar.
```

---

## What Already Exists

- `VectorStore.swift` — single-pathway vector search (target of Move 1 + 3 changes)
- `EmbeddingService.swift` — model loading abstraction (good seam for swap; extend with currentSignature)
- `SourceIngestionService.swift` — chunking already done; chunks have embeddings
- `NodeStore.swift` — has SQLite access, no FTS5 infrastructure (Move 1 adds it)
- `QuickActionMemoryPolicy` — exists; Move 3 extends it with citation quotas
- `ShadowPatternLexicon.swift` (2026-04-30) — multilingual prompt-injection matching. Not directly reusable (it's keyword-pattern not semantic), but proves codebase has CJK-tokenization awareness; may inform QueryNormalizer.
- `UserMemoryService.citableEntryPool(...)` at `:1372` — second retrieval entry point (per prior learning `nous-retrieval-entry-point`). Phase 0 audits whether it shares vector lookup; if yes scope expands.
- Existing TODO `Audit NodeStore.deleteNode cascade atomicity` — bundled into Move 1 since FTS5 triggers reuse the transaction primitive.

---

## NOT in Scope (Explicitly)

- Re-thinking the broader memory architecture (graph atoms, supersedes, contradiction memory). They consume retrieval output; they do not influence this plan.
- Re-thinking `assembleContext` prompt assembly. Separate domain.
- Cross-conversation summarization quality (separate known issue: memory `project_nous_summarization_texture_loss.md`).
- UI changes to citation display.
- Source ingestion changes (chunking strategy, URL safety).
- ICU-based CJK word segmentation (defer if trigram FTS proves sufficient; flagged in TODOS).
- Probation-window dual-embedding for full reversibility (overkill for Alex-only product; flagged in TODOS).
- Voice-mode retrieval refactor if Phase 0 audit shows it has a separate fast path (separate plan).
- Replacing MLXEmbedders Swift package with another runtime (constraint: keep current package).

---

## Failure Modes Per New Codepath

| Codepath | Realistic production failure | Test? | Error handling? | User experience |
|---|---|---|---|---|
| `searchHybrid` per-lane gate | Both lanes return empty → returns empty | ✓ fixture case 7 | graceful empty | empty citation chip area (correct) |
| FTS5 trigger on UPDATE | Trigger fires but transaction aborts → index drift | ✓ Move 1 unit test | wrapped in same transaction | invisible to user (transaction rollback) |
| EmbeddingMigrationRunner crash mid-batch | App killed, batch half-committed | ✓ Move 2 idempotency test | resume from last committed batch | progress bar resumes |
| Per-version query miss | User query embedded with new sig, all rows still old sig | ✓ Move 2 mid-flight test | lexical lane provides results | no chips OR fewer chips with banner |
| QueryNormalizer NFC failure | Pathological emoji input crashes normalizer | ✓ Move 1 unit test (round-trip) | fallback to unnormalized | results may be slightly worse, no crash |
| `sourceDisplacementMargin` edge | Source margin = 0.05 exactly → undefined | ✓ Move 3 boundary test | strict `>` not `>=` | deterministic behavior |
| FTS5 tokenizer pathological input | All-emoji query produces empty index lookup | ✓ Move 1 fuzz test | empty lane, vector still tries | empty OR vector-only results |
| Model download failure | bge-m3 (~2GB) network interrupted | ✓ Move 2 failure-mode test | runner aborts, existing rows unchanged | clear error in HarnessHealth |
| Corrupted embedding blob | DB row has malformed bytes | ✓ Move 2 unit test | row marked `migration_failed`, surfaced in HarnessHealth | row excluded from results, visible in health UI |

**Critical gaps (no test AND no error handling AND silent):** none after this plan. All paths instrumented.

---

## Worktree Parallelization Strategy

| Step | Modules touched | Depends on |
|---|---|---|
| Phase -1 Forensic Trace | (read-only) | — |
| Phase 0 Research | (read-only) | Phase -1 |
| Move 4 fixture (Tests/NousTests/) | Tests/ | Phase 0 |
| Move 1 LexicalIndex (Sources/Nous/Services/, schema migration) | Sources/, schema | Move 4 fixture |
| Move 1 QueryNormalizer (Sources/Nous/Services/) | Sources/ | — (independent) |
| Move 1 VectorStore.searchHybrid (Sources/Nous/Services/VectorStore.swift) | Sources/ | LexicalIndex + QueryNormalizer |
| Move 3 QuickActionMemoryPolicy + bucketed merge | Sources/ (Models + Services) | searchHybrid |
| Move 2 schema + migration runner | schema + Sources/ | Phase 1 complete + measured |
| Move 2 model swap | Sources/Nous/Services/EmbeddingService.swift | migration runner |

**Lanes:**
- **Lane A (Move 4 fixture):** independent. Launch in parallel as soon as Phase 0 closes. ~half day work.
- **Lane B (Move 1 LexicalIndex + QueryNormalizer):** can run parallel with Lane A. Does NOT touch VectorStore yet. ~1 day work.
- **Lane C (Move 1 searchHybrid + Move 3):** sequential after Lane B (touches VectorStore). ~1 day work.
- **Lane D (Move 2):** sequential after Phase 1 measured.

**Conflict flags:** Move 1 searchHybrid and Move 3 bucketed merge both touch `VectorStore.swift`; merging Lane C as one workstream avoids merge conflict. Move 2 schema migration touches the schema file edited by Move 1 LexicalIndex (FTS5 triggers); resolve by sequencing Move 2 after Phase 1 fully merged.

**Recommended execution:** Lane A + Lane B in parallel worktrees. Merge both. Then Lane C. Measure. Then Lane D in its own worktree.

---

## Open Questions — All Resolved

1. ~~MLX Swift XLM-RoBERTa support~~ → **Resolved by D2:** Phase 0 verifies before Phase 2; bge-m3 only after deep-compat check.
2. ~~Re-embed migration cost~~ → **Resolved:** Phase -1 audit measured corpus (52 conversations + 4 sources + 104 source chunks). Re-embed scope is small; single sync run with progress reporting is sufficient. Full failure semantics enumerated in Move 2.
3. ~~FTS5 tokenizer choice~~ → **Resolved:** trigram preferred per Phase -1 evidence; Phase 0 benchmark on Move 4 fixture validates before locking.
4. ~~RRF parameter k~~ → **Resolved:** k=60 default per industry, per-lane gates handle the "garbage lane" Codex concern.
5. ~~Quotas in Move 3~~ → **Resolved by D4:** routed through QuickActionMemoryPolicy.
6. ~~Source citation surface area~~ → **Resolved:** `searchForRelatedContent` (`VectorStore.swift:221`) shares the same `mergedChatCitationCandidates` ranking path. Move 1's hybrid wiring extends to it transitively.
7. ~~Voice retrieval~~ → **Resolved by Phase 0 audit:** `RealtimeVoiceSession` does NOT call `VectorStore`, `searchForChatCitations`, or `embeddingService.embed` directly. Voice has a separate fast path. Plan unaffected; voice retrieval refactor (if ever wanted) is a separate plan.
8. ~~Title indexing~~ → **Resolved:** Move 1 adds `nodes_fts(nodeId, type, title)` virtual table with INSERT/UPDATE/DELETE triggers. Title weight 3.0 in cross-table fusion. Phase -1 confirmed `messages_fts` indexes content only.
9. ~~citableEntryPool retrieval path~~ → **Resolved by Phase 0 audit:** `UserMemoryService.citableEntryPool(...)` at `:1818` takes `nodeHits: [UUID]` as input — meaning it CONSUMES upstream vector retrieval results. It does NOT do its own vector lookup. Pass 2 is "node-hit bridging from the main vector retrieval." Fixing `searchForChatCitations` improves what citableEntryPool sees transitively. Plan scope unchanged.
10. ~~FTS5 UPDATE trigger~~ → **Resolved by Phase 0 audit:** confirmed only `messages_fts_insert` and `messages_fts_delete` exist. Move 1 adds UPDATE trigger (and equivalents for the two new FTS5 tables).

---

## TODOS (To be added via /plan-eng-review TODO discipline)

- **Probation-window dual-embedding for full migration reversibility.** What: keep both old and new embeddings during a probation period; rollback by setting active signature back. Why: belt-and-suspenders for production-critical migrations. Pros: safer. Cons: 2x embedding storage, complexity. Context: For Alex-only product probably overkill. Worth revisiting if Nous serves multiple users.
- **ICU-based CJK word segmentation in FTS5.** What: replace unicode61/trigram with ICU segmenter for higher-quality CJK tokenization. Why: trigram increases index size + has BM25 score quirks. Pros: better lexical matching. Cons: needs ICU dependency, breaks "no new deps" constraint. Context: Defer until trigram limitations are empirically observed.
- **Citation Provenance display in UI.** What: when a citation comes via lexical lane only, surface a small badge or tooltip. Why: helps Alex understand WHY a memory was retrieved (semantic vs lexical). Pros: trust + debuggability. Cons: UI work outside this plan's scope.
- **Re-evaluate `searchForRelatedContent` as a separate retrieval consumer.** What: after Phase 1 ships, audit if any other retrieval consumers (galaxy view, related notes, etc.) inherit this fix or need their own. Why: shared infrastructure ships once but each consumer has its own use cases. Context: Phase 0 audits but defer implementation if separate.

---

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | not run |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | issues_found | 17 findings via outside voice; 3 cross-model tensions resolved via D6/D7/D3-revision; 9 smaller findings folded as "I'll resolve" |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | clean | 8 architecture issues, 4 code-quality, 4 test gaps, 4 perf items; 18 code paths + 9 user flows mapped; 7 critical gaps all covered by fixture |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | n/a (no UI surface) |
| DX Review | `/plan-devex-review` | Developer experience | 0 | — | n/a (internal) |

**CODEX:** 17 findings (gpt-5.5, high reasoning). 3 created cross-model tension and revised the plan: (T1) Phase -1 Forensic Trace added; (T2) D3 mixed-pool revised to per-version querying; (T3) Phase ordering inverted — lexical first, model swap second.

**CROSS-MODEL:** Strong overlap on architectural seams (type-aware ranking necessity, missing title indexing, threshold portability concerns). Codex caught 3 issues eng review missed (forensic trace gap, mixed-pool math, phase ordering risk). Eng review caught 2 issues codex missed (per-mode quota policy layer, second retrieval entry point `citableEntryPool`).

**UNRESOLVED:** 0 unresolved decisions. All 7 D-decisions locked.

**VERDICT:** ENG CLEARED — ready to implement. Codex outside voice triggered substantive plan revisions; final plan reflects cross-model consensus where it existed and user judgment where it didn't. Estimate revised 2-3 days → 3-5 days.
