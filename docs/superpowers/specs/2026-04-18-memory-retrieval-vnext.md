# Memory Retrieval vNext

**Date:** 2026-04-18
**Status:** Draft
**Branch target:** TBD
**Schema dependency:** judge-side surfacing fields (`provocation_hint`) are defined in `2026-04-18-judge-verdict-v2-schema.md` and shared with the Companion v2 design.

## Thesis

Nous should be **vector-first**, but not **vector-only**.

Vector search is the right substrate for semantic discovery: surfacing old ideas, finding latent connections, and recalling memories that are conceptually related even when the wording changed. But some memories should not depend on similarity scoring to earn recall at all.

One-line summary:

- vector should discover
- rules should protect
- types should prioritize
- scope should bound

## Goal

Improve two things:

1. **Memory recall quality**
   Retrieve memories that are actually relevant to the current turn, not just semantically nearby.
2. **Judge pool quality**
   Give `ProvocationJudge` a smaller, more grounded, more trustworthy pool of raw `memory_entries`.

## Problem

Today the system is already partially vectorized, but at a coarse grain:

1. embed the current query
2. run `VectorStore.search(...)`
3. get back `NousNode` hits
4. bridge from node hits back to `memory_entries`

This is simple, but it has clear limits:

- retrieval happens at the node level, not the memory-entry level
- semantic similarity is doing too much work too early
- decisions, preferences, boundaries, and constraints should often be recalled deterministically, not only because they happened to embed near the current query

So the issue is not "too much vector" at the storage layer. The issue is that **vector currently dominates the wake-up path at too coarse a granularity**.

## Design

Each turn should retrieve memory through 3 lanes.

### Lane A: Hard Recall

Deterministic, non-vector recall for memories that should be remembered on principle.

Examples:

- active conversation memory
- active project memory
- global identity memory
- memory boundaries
- high-confidence preferences
- high-confidence decisions
- active constraints

These are "should remember" memories.

### Lane B: Vector Recall

Semantic retrieval over embedded memory content.

Examples:

- old but relevant ideas
- contradiction candidates
- relevant-but-unused concepts
- cross-project or cross-thread latent connections

These are "worth discovering" memories.

### Lane C: Recency Seed

A small backstop for recent active entries that might not rank highly by vector similarity yet.

This prevents the system from being blind to newly formed memory that has not had time to become semantically central.

## Memory Type System

Each `memory_entry` should participate in retrieval with an explicit recall class.

Suggested types:

- `identity`
- `preference`
- `decision`
- `constraint`
- `boundary`
- `project_context`
- `thread_state`
- `hypothesis`

Suggested retrieval behavior:

- `identity`, `preference`, `decision`, `constraint`, `boundary`
  Eligible for Hard Recall when confidence and scope permit
- `project_context`, `thread_state`
  Eligible for Hard Recall or Recency Seed depending on scope and freshness
- `hypothesis`
  Never forced into Hard Recall; low-priority candidate only

## Retrieval Policy

For each turn:

1. collect Hard Recall entries
2. run Vector Recall top-K
3. add Recency Seed entries
4. merge and dedupe
5. rerank
6. split results into:
   - summary/context inputs for the main prompt
   - raw citable pool for the judge

## Ranking

Merged candidates should not be ranked by vector similarity alone.

Use a mixed score combining:

- `scope_match`
- `memory_type_priority`
- `confidence`
- `recency`
- `vector_similarity`

Interpretation:

- scope correctness matters most
- type priority matters a lot
- confidence matters a lot
- recency is meaningful but secondary
- vector similarity is important, but not sovereign

## Pool Composition

### Main prompt summary pool

Suggested composition:

- 2-4 hard-recall entries
- 3-5 vector-recall entries
- 1-2 recency-seed entries

This pool feeds summary/context assembly, not raw citation.

### Judge citable pool

Suggested composition:

- 3-5 hard-recall entries
- 5-8 vector-recall entries
- 1-2 recency-seed entries

The judge pool should stay small and precise. The goal is not coverage-at-all-costs; the goal is giving the judge the right set of choices.

## Entry-Level Vectorization

Long-term, retrieval should move from node-level vector search to memory-entry-level vector search.

### Phase 1

Keep the current node-level search, but improve policy around it:

- add Hard Recall lane
- add Recency Seed lane
- rerank with scope/type/confidence
- improve judge-pool composition

### Phase 2

Add embeddings directly on `memory_entries`.

At that point:

- judge pool can be built from direct entry retrieval
- main recall no longer needs node-hit bridging
- semantic discovery becomes finer-grained and less lossy

### Phase 3

Tune weights and pool composition from telemetry:

- thumbs-down on provoked replies
- wrong-memory surfacing
- false-negative judge reviews
- continuity quality in reopened conversations

## Precision Rules

The following rules should hold regardless of vector score:

- boundary memory must not be ranked out by vector-only logic
- hypothesis memory cannot be hard-recalled
- assistant-authored content must not become primary evidence
- project-local memory must not silently act like global identity memory
- uncertain recall should bias toward omission over false recall

## Success Metrics

This design is working if it produces:

- fewer wrong-memory surfacings
- fewer judge false positives
- fewer "semantically similar but actually irrelevant" recalls
- lower thumbs-down rate on provoked replies
- stronger continuity when reopening old conversations

## Recommendation

Nous should move toward:

**vector-first substrate, hybrid retrieval policy**

That means:

- use vector search as the main discovery engine
- do not let vector similarity be the only law
- keep hard-recall guarantees for memory that must remain reliable
- use types, scope, and confidence as brakes and steering

## Non-goals

- removing vector search
- replacing semantic retrieval with regex or keyword-only logic
- introducing a full entry-level vector index immediately
- redesigning the whole memory schema in one step

## Deferred

- full entry-level embedding pipeline
- learned ranking weights
- local-provider-specific retrieval heuristics
- automatic memory-type inference from judge telemetry
