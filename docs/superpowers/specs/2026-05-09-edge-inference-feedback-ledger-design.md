# Edge Inference Feedback Ledger — Design Spec

**Date**: 2026-05-09
**Status**: shipped (Phase A)
**Phase**: A (telemetry + feedback infrastructure; precursor to Phase A2 threshold/prompt tuning)

---

## Problem

Connect-the-dots inference accuracy in Nous is weak across two dimensions:

- **Galaxy edges**: both false positives (noise edges) and false negatives (sparse graph). When a node is selected, often only a single 1-hop edge is visible because the underlying inference is conservative (semantic threshold 0.75) and rate-limited (manualRefinementCandidateLimit=12, queued=4).
- **Chat citations**: `CorpusAtomCardListView` surfaces atoms used as retrieval context under model replies, but their accuracy and relevance go uncalibrated — there is no ground truth signal flowing back from the user.
- **Generic explanations**: when atom-pair judging misses, fallback `topicSimilarity` produces the generic explanation "这只是语义相似，不是强结论；需要更多证据才能判断真正关系" — visually present but semantically empty.

Past pattern: `validation_phase21_shipped` and Block 8 deferred items established that threshold tuning at this level should be **telemetry-informed**, not gut-tuned. There is currently no per-edge / per-citation telemetry persisted, so no baseline exists.

## Goal

Build the infrastructure to collect ground-truth signal on connect-the-dots quality across both galaxy and chat surfaces. Phase A is **infrastructure only** — it does not change inference accuracy directly. Phase A2 (out of scope here) consumes the resulting dataset to tune thresholds, prompts, and eventually fine-tune a personalized judge.

The long-term moat: per-user thumb judgments on relations and citations become a personalized ground-truth dataset that compounds over time. Public LLM judges improve generally but slowly; this dataset is uniquely Alex's signal.

## Architecture

Add a **judgment ledger** layer that covers two surfaces (galaxy edge inspector + chat atom card). User-side gestures and SwiftUI components are fully shared; data-side storage uses two narrowly-keyed tables for each side. Two layers evolve independently: shared UX builds muscle memory; clean schema keeps future judge training free of NULL pollution.

```
USER LAYER (shared) ─────────────────────────────────────────

  ThumbFeedbackView  + ThumbVerdict (.up/.down/.unset)
  + optional note textbox + telemetry hook

  Mounted once each in GalaxyInspector and CorpusAtomCardListView

GENERATION / TELEMETRY (split, parallel) ────────────────────

  GalaxyEdgeEngine ──> EdgeJudgeTrace.append
       │
       └─ GalaxyRelationJudge

  CitableContextBuilder ──> CitationJudgeTrace.append
       │
       └─ retrieval scoring

USER FEEDBACK STORAGE (split) ───────────────────────────────

  EdgeFeedbackStore       CitationFeedbackStore
  key: (normalized        key: (conversationId,
        nodeA, nodeB,           turnId, atomId)
        relationKind)

  Each owns its lifecycle and query path
  Share ThumbVerdict enum + telemetry recorder protocol

DATASET CONSUMERS (future, out of Phase A) ──────────────────

  EdgeFeedback   → tune GalaxyRelationJudge threshold/prompt
  CitationFeedback → tune CitableContextBuilder retrieval
```

**Stability invariant**: feedback keys include `surface` + a stable entity identity.
- Galaxy: `(normalized(sourceId, targetId), relationKindAtFeedback)` — regen producing the same kind carries feedback over; regen producing a different kind starts fresh, with the prior thumb preserved in trace history as a negative example for that earlier judgment.
- Chat: `(conversationId, turnId, atomId)` — immutable per turn.

## Data Model

Four new tables, fresh `CREATE TABLE IF NOT EXISTS` migration. No changes to existing `node_edge`, atom, or conversation schemas. No backfill — old edges and old turns have unknown trace; collection is forward-only.

### Shared Swift types

```swift
enum ThumbVerdict: String, Codable {
    case up      // 啱 — connection is real
    case down    // 唔啱 — connection doesn't hold or explanation is wrong
    case unset   // user has not weighed in (default)
}

enum JudgePath: String, Codable {
    case atom        // GalaxyRelationJudge.judgeAtomRelationship hit
    case llm         // judgeRefined LLM upgrade succeeded
    case fallback    // similarity-only fallback (topicSimilarity)
    case retrieval   // chat-side CitableContextBuilder (chat-only value)
}
```

### Table 1: `edge_feedback` (user signal, galaxy edges)

| column | type | notes |
|---|---|---|
| `node_a_id` | TEXT | normalized: `min(source, target)` |
| `node_b_id` | TEXT | normalized: `max(source, target)` |
| `relation_kind` | TEXT | snapshot at feedback time |
| `verdict` | TEXT | ThumbVerdict |
| `note` | TEXT? | optional free text |
| `verdict_at` | TIMESTAMP | last update |
| `verdict_count` | INT | accumulated update count (history hint when user changes mind) |

PRIMARY KEY `(node_a_id, node_b_id, relation_kind)`. UPSERT on conflict, bump `verdict_count`.

### Table 2: `citation_feedback` (user signal, chat atom cards)

| column | type | notes |
|---|---|---|
| `conversation_id` | TEXT | |
| `turn_id` | TEXT | model reply turn |
| `atom_id` | TEXT | the surfaced atom |
| `verdict` | TEXT | ThumbVerdict |
| `note` | TEXT? | optional |
| `verdict_at` | TIMESTAMP | |

PRIMARY KEY `(conversation_id, turn_id, atom_id)`. UPSERT on conflict.

### Table 3: `edge_judge_trace` (system telemetry, append-only)

Every iteration of `GalaxyEdgeEngine.generateSemanticEdges` appends one row, including rejections (`relation_kind = NULL` indicates judge decided no connection). Critical for distinguishing "judge didn't try" from "judge said no".

| column | type |
|---|---|
| `id` | INTEGER PRIMARY KEY AUTOINCREMENT |
| `node_a_id` / `node_b_id` | TEXT (normalized) |
| `relation_kind` | TEXT? (NULL = judge rejected) |
| `judge_path` | TEXT |
| `similarity` | REAL |
| `confidence` | REAL? |
| `judged_at` | TIMESTAMP |

INDEX on `(node_a_id, node_b_id, judged_at DESC)` for "latest verdict + history" queries.

### Table 4: `citation_judge_trace` (system telemetry, append-only)

Every candidate atom from `CitableContextBuilder` appends one row, including atoms filtered out by `AttributionDisplay.cascade` floor/cap (with `was_displayed = false`).

| column | type |
|---|---|
| `id` | INTEGER PRIMARY KEY AUTOINCREMENT |
| `conversation_id` / `turn_id` / `atom_id` | TEXT |
| `confidence` | REAL |
| `was_displayed` | BOOL |
| `judged_at` | TIMESTAMP |

INDEX on `(turn_id, judged_at)`.

### Why telemetry and feedback are not unified

Telemetry is append-only history (the same node pair may have N rows tracking judge re-runs); feedback is latest-state (one verdict per pair, mutable). Read/write patterns differ enough that a unified table makes both queries harder.

## UI Surface Changes

Both surfaces mount the same `ThumbFeedbackView` SwiftUI component but use different `Style` modes for placement and visual treatment.

### Galaxy inspector

Added at the bottom of the inspector, below evidence cards:

```
─── existing inspector body ───
关系: supports
explanation: ...
[source evidence card]
[target evidence card]
[前往节点 →]

─── new feedback section ───

   呢条关联啱吗？

   ┌───────┐  ┌───────┐
   │ 👍 啱 │  │ 👎 唔啱│       ← unselected: outline only
   └───────┘  └───────┘          selected: Morandi dusty rose fill

   ┌────────────────────────────────────┐
   │ 想补充？                            │   ← collapsed 1-line
   └────────────────────────────────────┘      expands on focus

   相似度 0.78 · 路径 atom→llm · 信心 0.82
   判断於 14:32 · 之前已表态 1 次          ← AppColor.secondaryText 11pt
```

Color: per the `Galaxy — no colaOrange anywhere` invariant, selected thumb fill uses Morandi dusty rose, never colaOrange. Telemetry strip is muted secondary text.

For old edges (pre-Phase A) the telemetry strip displays `判断路径: 未记录（Phase A 之前）` instead. Feedback buttons remain functional — feedback is forward-collectable regardless of whether trace exists.

### Chat atom card (`CorpusAtomCardListView`)

Thumb buttons added to the right edge of each atom row header (compact, icon-only, do not steal visual weight from the statement):

```
─── existing atom row ─────────────────────────────────
  preference · 2026-04-22 · 0.84       👍 👎  ← new
  Alex 偏好喺 chat reply 用「啦」、「咯」
  类语气词，唔好用 ChatGPT 嘅啰嗦句式

  ↓ on thumb-down, row reveals below:
  📝 ┌────────────────────────────────────────┐
     │ 关联唔到呢条 message？                 │
     └────────────────────────────────────────┘
```

Chat does not display a telemetry strip — chat is a daily-use surface and inline technical metadata would break reading flow. Telemetry is recorded silently to `citation_judge_trace`; surfacing it is reserved for a Phase A2 dedicated debug view.

Color: chat-side thumb selected state uses the same dusty rose as galaxy for cross-surface consistency, but unselected state uses `AppColor.secondaryText` to blend with the existing chip palette.

### `ThumbFeedbackView` component shape

```swift
struct ThumbFeedbackView: View {
    @Binding var verdict: ThumbVerdict
    @Binding var note: String
    let style: Style          // .galaxy (full size + telemetry strip)
                              // .chat (compact, icon-only thumbs)
    let telemetry: TelemetryStrip?  // nil = chat mode
    let onChange: (ThumbVerdict, String) -> Void
}
```

`Style` determines size, label vs icon-only, and whether the telemetry strip renders. One component, two visual modes.

## Telemetry Capture Points and Write Paths

### `EdgeJudgeTrace.append` — 4 capture points

| Where | When | What gets logged |
|---|---|---|
| `GalaxyEdgeEngine.generateSemanticEdges` for-loop | Every candidate neighbor processed | Both accept and reject (`relation_kind = NULL` for reject) |
| `GalaxyRelationJudge.judgeAtomRelationship` returns verdict | Atom path hit | `judge_path = .atom`, confidence + similarity |
| `GalaxyRelationJudge.judgeRefined` LLM success | LLM upgrade verdict | `judge_path = .llm`, LLM confidence |
| Same function, fallback branch | LLM call failed / similarity-only | `judge_path = .fallback` |

`GalaxyRelationJudge` already accepts `telemetry: GalaxyRelationTelemetry?` injection. Add a parallel `judgeTraceWriter: EdgeJudgeTraceWriter?` injection following the same pattern. New trace appends sit alongside existing `telemetry?.record(...)` calls — the trace is supplementary, not a replacement.

### `CitationJudgeTrace.append` — capture points

| Where | When | What gets logged |
|---|---|---|
| `CitableContextBuilder.build` after ranking | Once per turn | One trace row per candidate atom |
| `AttributionDisplay.cascade` post-decision | After UI cascade | `was_displayed` flag patched per atom |

**Wire approach**: deferred single write (rejected the two-phase write alternative). `CitableContextBuilder` does not write trace itself; it returns the candidate list to `ChatViewModel`, which writes all N rows once after `cascade` resolves `was_displayed`. Trade-off: `ChatViewModel` takes on a small telemetry write responsibility. Benefit: one DB write per turn, all logic in one place, no row-id round-trip.

### Feedback write paths

```
ThumbFeedbackView.onChange(verdict, note)
        │
        ├─ Galaxy mode ─> EdgeFeedbackStore.upsert(
        │                    nodeAId, nodeBId (normalized),
        │                    relationKindAtFeedback,
        │                    verdict, note)
        │
        └─ Chat mode  ──> CitationFeedbackStore.upsert(
                             conversationId, turnId, atomId,
                             verdict, note)
```

Both stores are thin SQLite wrappers using `INSERT ... ON CONFLICT(...) DO UPDATE`. Galaxy upsert bumps `verdict_count`; chat does not (chat feedback is one-row-per-turn and the bump would be meaningless).

### Threading

- **Telemetry append**: same thread as the calling judge. `generateSemanticEdges` already runs on a background queue; trace writes piggyback there.
- **Feedback upsert**: SwiftUI callback writes synchronously on main thread. Single-row SQLite upsert is sub-millisecond and will not block UI.

### Explicitly not done in Phase A

- ❌ Async/Future wrapping of trace writes — synchronous SQLite is fast enough
- ❌ In-memory batch buffers — every verdict writes immediately to disk to avoid crash data loss
- ❌ Trace rotation / TTL — Phase A imposes no size limit; revisit if rows exceed 100k

## Testing Strategy

### Unit tests (NousTests pattern)

| What | How |
|---|---|
| `EdgeFeedbackStore` upsert / query | In-memory SQLite, two writes same key verifies update vs insert, `verdict_count` bump |
| `CitationFeedbackStore` upsert / query | Same |
| `EdgeJudgeTraceStore` append + latest-verdict query | Verifies append-only + index-backed latest query |
| `CitationJudgeTraceStore` append + by-turn query | Same |
| `ThumbFeedbackView` callback wiring | SwiftUI snapshot + tap simulation: tap thumb-up triggers callback verdict = .up; note input syncs |
| Node-pair normalization | `(B, A)` and `(A, B)` inputs land in same row |
| Regen carry-over invariant | Insert edge → upsert thumb → simulate regen (delete + reinsert same kind) → feedback persists; regen with different kind → feedback for prior kind preserved, new kind has fresh state |

### Integration tests

- After `GalaxyEdgeEngine.generateSemanticEdges` runs, `edge_judge_trace` row count equals processed candidate count (including rejections)
- After `CitableContextBuilder` + `AttributionDisplay.cascade`, `citation_judge_trace` has one row per candidate atom and `was_displayed` matches the UI cascade decision

### Manual QA checklist

1. Galaxy: open inspector on a verified edge → see thumb section + telemetry strip → tap 👎 → reload inspector → selected state persists
2. Galaxy: open same edge again → tap 👍 (change of mind) → `verdict_count = 2`
3. Chat: send a message that triggers retrieval → see atom card → tap 👎 → row reveals note textbox → enter text → close + reopen card → selected state persists
4. Galaxy: restart app → feedback persists
5. Telemetry sanity: query SQLite CLI directly to confirm trace rows accumulate

## Scope Boundary

### In scope (Phase A)

- 4 new tables + migration (schema version bump in NodeStore)
- `ThumbVerdict` / `JudgePath` enums + shared `ThumbFeedbackView` component
- 2 feedback stores + 2 trace stores
- Galaxy inspector + chat atom card UI integration
- Telemetry capture wire-up (4 sites in galaxy judge + 1 site in chat citation flow)
- Test coverage as listed above

### Out of scope (Phase A2 or later)

- Using collected datasets to tune thresholds, prompts, or fine-tune judges (this is the telemetry-first commitment's follow-through)
- Voice surface feedback
- Inspector "feedback history" tab
- "Suggest correct verdict" quick-pick buttons (e.g., tap thumb-down then pick correct relation kind from a menu)
- Trace rotation / TTL
- Dataset export tooling (CSV/JSON dump for fine-tuning)
- Per-user reflection job that uses feedback to re-score old edges

### Risks

- **Feedback rate may be far lower than expected.** Mitigation: in Phase A2, consider an inline prompt that proactively asks "is this edge correct?" every N edges viewed, but resist this in Phase A to avoid prompt fatigue corrupting the natural-rate signal.
- **`was_displayed` accuracy depends on cascade and trace write ordering.** Integration tests must cover this explicitly; the deferred-write approach makes correctness easier to verify than two-phase write would.
- **Old edges have no trace.** UI handles this gracefully ("未记录（Phase A 之前）"), but Phase A2 dataset analysis must filter by trace presence.

## Commitment

This spec is only worthwhile if Phase A2 follows. Ship Phase A → dogfood for 1-2 weeks → look at the trace and feedback data → decide what to tune next (false positives, false negatives, or explanation depth) based on what the data shows. Without this follow-through, Phase A becomes dead infrastructure.
