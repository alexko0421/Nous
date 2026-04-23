# Memory Retrieval vNext

**Date:** 2026-04-18
**Status:** Phase 1 substrate shipped (via PR #10 + PR #13, 2026-04-19). Hard Recall lane + Pool composition + annotation pass deferred pending real pain signal — see "Shipped State" below.
**Branch target:** main (already landed)

## Thesis

Typed retrieval for contradiction recall and thinking spark.

Vector search is still the right substrate for semantic discovery, but contradiction and reflexive provocation should not depend on similarity score alone. This design narrows retrieval work to one product outcome: make it easier for `ProvocationJudge` and the main model to see the past decisions, boundaries, and constraints that matter enough to surface back to Alex.

One-line summary:

- types are the substrate for contradiction
- hard recall protects what the judge must always see
- vector discovers latent connections worth surfacing
- scope still bounds everything

## Goal

Improve two things that directly serve the thinking-companion product:

1. **Contradiction recall**
   The system should reliably surface prior `decision`, `boundary`, and `constraint` memories when the current turn pushes against them.
2. **Thinking spark quality**
   The judge pool should contain better raw entries for provocation: smaller, more grounded, and more likely to support "you said X before, but now you're saying Y."

## Shipped State (2026-04-19)

This spec was written 2026-04-18. By 2026-04-19, the substrate it called for had already landed on `main` via two unrelated-looking PRs:

**Shipped (PR #10 — proactive surfacing):**
- `decision` and `boundary` added to `MemoryKind` enum (`Sources/Nous/Models/MemoryEntry.swift:13-14`)
- `MemoryFactStoreTests.testMemoryKindJSONRoundTripsNewCases` covers Codable round-trip + legacy decode
- Conversation-scope write prompt teaches the LLM when to emit `decision` vs `boundary` vs `constraint` (`UserMemoryService.swift:1020-1048`)
- `contradictionFactKinds = [.decision, .boundary, .constraint]` constant exists (`UserMemoryService.swift:23`)
- Fixture `01-clear-contradiction-deciding.json` exercises a real `decision`-shaped contradiction

**Shipped (PR #13 — provocation_kind discriminator):**
- Telemetry: `provocation_kind: contradiction | spark | neutral` on every JudgeVerdict
- Deterministic Swift derivation; SQL filter via `json_extract`; Memory Debug Inspector picker rows

**Deferred (no current pain signal):**
- Lane A: Hard Recall (deterministic type-based recall regardless of vector score)
- Pool composition with hard/vector/recency split
- Lane B/C explicit definition (currently vector retrieval is unchanged from pre-spec state)
- Contradiction-candidate annotation pass (`UserMemoryService.annotateContradictionCandidates(...)`)
- `[contradiction-candidate] id=<entry-id>` prompt marker

**Reason for deferral:** Per Alex's pain test (2026-04-19), current memory volume is small enough that vector retrieval feels adequate. Building Hard Recall + annotation now is forward-looking work; the false-positive cost (Nous becoming nag-prone) outweighs the benefit until accumulated `decision`/`boundary` rows make vector noise dominant. Revisit when Alex experiences "Nous should have caught this" in real use.

---

## Non-goals

- A full memory retrieval overhaul
- Entry-level vector indexing in Phase 1
- A large new taxonomy of memory types
- Local-provider heuristics
- Ask-back UX itself

## Problem

Today the system is already partially vectorized, but at a coarse grain:

1. embed the current query
2. run `VectorStore.search(...)`
3. get back `NousNode` hits
4. bridge from node hits back to `memory_entries`

That is good enough for broad semantic discovery, but too blunt for contradiction recall:

- retrieval happens at the node level, not the memory-entry level
- semantic similarity is doing too much work too early
- the memories that matter most for provocation should not disappear just because they scored poorly on the current query

The issue is not "too much vector" in storage. The issue is that **vector currently dominates wake-up at too coarse a granularity**.

## Phase 1 Scope

Phase 1 is intentionally narrow. It exists to support proactive surfacing, not to build a grand unified retrieval engine.

Phase 1 includes:

- add `decision` and `boundary` to `MemoryKind`
- hard recall for `decision`, `boundary`, and existing `constraint`
- keep vector recall as a second lane
- add a lightweight contradiction-candidate annotation pass for the judge pool

Phase 1 does not include:

- learned reranking weights
- full mixed-score retrieval engine
- broad new memory kinds beyond what contradiction needs
- entry-level vector storage or indexing

## Memory Type System

Phase 1 aligns with the existing `MemoryKind` enum in [MemoryEntry.swift](/Users/kochunlong/conductor/workspaces/Nous/new-york/Sources/Nous/Models/MemoryEntry.swift:9).

### New in Phase 1

- `decision`
  Explicit choices Alex made.
  Example: "We are not competing on price."
- `boundary`
  Red lines or do-not-cross constraints expressed as principles or operating rules.
  Example: "Do not auto-commit code without approval."

### Already present and unchanged

- `identity`
- `preference`
- `constraint`
- `relationship`
- `thread`
- `temporaryContext`

### Deferred

These were discussed, but are not needed for Phase 1 contradiction recall:

- `project_context`
- `thread_state`
- `hypothesis`

## Phase 1 Migration

Phase 1 is intentionally small, but it still crosses several implementation seams. The migration checklist is:

- ✅ **Enum + serialization** (PR #10)
  `decision` and `boundary` added to `MemoryKind`. Codable round-trip + legacy decode tested in `MemoryFactStoreTests.testMemoryKindJSONRoundTripsNewCases`.
- ✅ **Write-path / governance refresh prompt** (PR #10)
  Conversation-scope refresh in `UserMemoryService.swift:1020-1048` instructs the LLM to emit `decision` / `boundary` / `constraint` with explicit definitions.
- ✅ **Fixture bank** (PR #10)
  `Tests/NousTests/Fixtures/ProvocationScenarios/` has 6 scenarios; `01-clear-contradiction-deciding.json` exercises a `decision`-shaped contradiction directly.
- ⚠️ **Backwards-compat tests** (partial)
  Existing `MemoryKind` round-trip is covered. True unknown-kind robustness (e.g., a future `hypothesis` value in a row this client does not recognise) is NOT covered — `MemoryKind` will throw on unknown raw values. Defer until a second client version exists.

## Retrieval Lanes

Each turn retrieves memory through 3 lanes.

### Lane A: Hard Recall

Type-based, deterministic recall for entries the judge must always see if they are in scope.

Phase 1 hard-recalls only:

- `decision`
- `boundary`
- `constraint`

This lane is not responsible for replaying all scoped memory. Its only job is to guarantee that contradiction substrate remains visible even when vector similarity is weak.

Important exclusions:

- `identity` and `preference` continue to flow through normal context assembly; they are not force-injected into the judge pool just because they exist
- `relationship`, `thread`, and `temporaryContext` are not contradiction-critical in Phase 1

### Lane B: Vector Recall

Semantic retrieval over the current node-level vector path.

This lane is still useful because contradiction is not the only spark we care about. Vector recall remains responsible for:

- relevant-but-unused ideas
- latent semantic neighbors
- old but relevant memories
- candidate contradictions that were not tagged explicitly enough to enter Hard Recall

### Lane C: Recency Seed

A small backstop of recent active entries so the pool is not blind to newly formed memory.

This matters most when a recent decision or constraint has not had enough time to become semantically central.

## Hard Recall vs Existing Context Assembly

This design does not replace existing scope-based memory assembly in `ChatViewModel.assembleContext(...)`.

The split of responsibilities is:

- context assembly:
  stable scoped memory for the main prompt
- retrieval vNext:
  contradiction-oriented entry selection for the judge pool

That keeps Phase 1 small and avoids duplicating work already done by current global/project/conversation context layers.

## Pool Composition

### Judge Pool

Phase 1 judge pool should be small and precise.

Suggested composition:

- 2-4 hard-recall entries
- 4-6 vector-recall entries
- 1-2 recency-seed entries

**Graceful degradation:** Hard Recall returning 0 entries is the common case early on (before the user has accumulated `decision` / `boundary` history). When that happens, vector and recency expand to fill up to `citableEntryPool` capacity (15). Phase 1 must not ship a half-empty judge pool just because contradiction substrate is sparse.

The goal is not maximum coverage. The goal is making sure the judge can see:

- what Alex decided
- where Alex drew a line
- what constraints are active now
- what semantically relevant old idea might still be worth surfacing

## Provocation Hooks

This section is the reason the retrieval work exists at all. If retrieval changes do not make provocation easier, they do not belong in Phase 1.

### A. Contradiction-candidate annotation

After building the judge pool, run a lightweight annotation pass over entries of kind:

- `decision`
- `boundary`
- `constraint`

The goal is not to declare a contradiction in retrieval code. The goal is to flag likely contradiction candidates so the judge prompt can reason over them explicitly.

Phase 1 recommendation:

- annotate the top 1-3 most relevant hard-recall candidates in the current pool
- use relative ranking inside the pool instead of a fixed global similarity threshold

Implementation shape:

- keep pool construction and prompt-building separate
- add a testable helper after pool construction and before judge prompt assembly
- preferred home: `UserMemoryService.annotateContradictionCandidates(currentMessage: String, facts: [MemoryFactEntry], maxCandidates: Int = 3) -> [AnnotatedContradictionFact]`. Returns each in-pool fact wrapped with an `isContradictionCandidate` flag and a relative `relevanceScore` so the debug inspector and any future ask-back surface can both read scores back. The call site (today: `ChatViewModel`) collects flagged IDs into a `Set<String>` and feeds them to `citableEntryPool(...)` via `contradictionCandidateIds:`, which is what becomes the `[contradiction-candidate] id=<entry-id>` prompt marker. Keeps annotation ranking out of prompt formatting code.

Example prompt hint:

`[contradiction-candidate] id=<entry-id>`

This is intentionally light-touch. Retrieval proposes candidates; the judge still decides whether tension exists.
This is a prompt-input annotation, **not** a `JudgeVerdict` field. `JudgeVerdict` schema is unchanged in Phase 1.

### B. Future hooks for surfacing and ask-back

`decision` and `boundary` entries, once typed and retrievable, make later provocation work cheaper:

- surfacing:
  "You said this before."
- contradiction:
  "This seems to cut against your earlier decision."
- ask-back:
  "What changed?"

Phase 1 does not ship ask-back UX, but the substrate should make later ask-back feel like a prompt/rendering layer, not a retrieval re-architecture.

## Precision Rules

The following rules hold regardless of vector score:

- `decision`, `boundary`, and `constraint` may be hard-recalled only if they are active and in scope
- `stable` vs `temporary` is not a hard-recall gate in Phase 1; if an in-scope `decision`, `boundary`, or `constraint` is active, it may be hard-recalled
- project-local entries must not silently behave like global identity memory
- uncertain candidates should bias toward omission over false contradiction
- assistant-authored summaries must not become primary evidence

## Success Metrics

Phase 1 should add a lightweight telemetry discriminator for provocation review:

- `provocation_kind: contradiction | spark | neutral`

This does not need a large telemetry redesign, but it gives review tooling a way to separate contradiction-oriented interjections from generic sparks when reading thumbs-down rates and manual review samples.

This design is working if it leads to:

- fewer missed contradiction opportunities in review
- fewer wrong-memory provocation attempts
- lower thumbs-down rate on contradiction-style interjections
- a judge pool that is easier to review and explain

## Recommendation

Proceed with `C-lite`:

- typed retrieval for contradiction
- not a full retrieval-engine rewrite
- vector-first substrate, but not vector-only governance

## Deferred

- entry-level embeddings on `memory_entries`
- full mixed-score reranking
- broad taxonomy expansion
- local-provider heuristics
- ask-back UX
