# Memory Retrieval vNext — Implementation Plan

> **For agentic workers:** Execute this as a narrow `C-lite` plan. Do not expand into a general retrieval rewrite. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the minimum retrieval changes that improve contradiction recall and thinking spark for proactive surfacing.

**Specs:**
- [2026-04-18-memory-retrieval-vnext.md](/Users/kochunlong/conductor/workspaces/Nous/new-york/docs/superpowers/specs/2026-04-18-memory-retrieval-vnext.md)
- [2026-04-17-proactive-surfacing-design.md](/Users/kochunlong/conductor/workspaces/Nous/new-york/docs/superpowers/specs/2026-04-17-proactive-surfacing-design.md)

## Preconditions

This plan assumes the proactive-surfacing substrate exists, either on `alexko0421/proactive-surfacing` or after that branch merges:

- `ProvocationJudge`
- `JudgeVerdict`
- `judge_events`
- `UserMemoryService.citableEntryPool(...)`
- `MemoryDebugInspector` judge review UI

If those pieces are not yet landed, stack this plan on that branch rather than implementing directly on current `main`.

## Critical Architecture Note

Current `memory_entries` has an important invariant: **at most one active entry per `(scope, scopeRefId)`**. Existing reads and tests depend on that invariant:

- `NodeStore.fetchActiveMemoryEntry(...)`
- `UserMemoryService.currentGlobal/currentProject/currentConversation(...)`
- tests asserting exactly one active row per scope+ref

Because of that, Phase 1 must **not** try to store sibling active `decision` / `boundary` rows in `memory_entries` alongside the canonical `thread` / `identity` summary row.

### Phase 1 implementation choice

Keep canonical `memory_entries` unchanged, and introduce a **sidecar fact table** for contradiction-oriented typed memory.

This preserves:

- the current read path
- the current one-active-entry invariant
- the existing context assembly logic

while still giving retrieval and the judge typed facts to work with.

## Scope

Phase 1 includes:

- add `decision` and `boundary` to `MemoryKind`
- add a sidecar typed fact substrate for contradiction recall
- hard recall active in-scope `decision` / `boundary` / `constraint` facts
- annotate top contradiction candidates before judge prompt assembly
- add a lightweight `provocation_kind` discriminator for contradiction review

Phase 1 excludes:

- entry-level vector indexing over all `memory_entries`
- full mixed-score reranking
- broad memory taxonomy expansion
- ask-back UX
- local-provider heuristics

## File Map

### New files

| Path | Responsibility |
|---|---|
| `Sources/Nous/Models/MemoryFactEntry.swift` | Sidecar typed fact model for contradiction recall |
| `Tests/NousTests/MemoryFactStoreTests.swift` | Round-trip tests for the fact table + helpers |
| `Tests/NousTests/ContradictionRecallTests.swift` | Retrieval + annotation tests for contradiction candidates |

### Modified files

| Path | Responsibility |
|---|---|
| `Sources/Nous/Models/MemoryEntry.swift` | Add `decision` / `boundary` cases to `MemoryKind` |
| `Sources/Nous/Services/NodeStore.swift` | Add `memory_fact_entries` table + CRUD/query helpers |
| `Sources/Nous/Services/UserMemoryService.swift` | Extract and retrieve contradiction facts; annotate candidates |
| `Sources/Nous/Services/GovernanceTelemetryStore.swift` | Add `provocation_kind` write/read support if `judge_events` already exists in branch |
| `Sources/Nous/Services/ProvocationJudge.swift` | Accept contradiction-candidate prompt hints; verdict schema unchanged |
| `Sources/Nous/ViewModels/ChatViewModel.swift` | Feed annotated contradiction candidates into judge flow |
| `Tests/NousTests/UserMemoryServiceTests.swift` | Add extraction and backwards-compat coverage |
| `Tests/NousTests/ProvocationOrchestrationTests.swift` | Add contradiction-oriented orchestration assertions |

## PR Structure

Ship this as 4 stacked PRs.

1. **PR 1 — Fact Substrate**
   Add `decision` / `boundary` to `MemoryKind`, introduce `memory_fact_entries`, and keep canonical `memory_entries` untouched.
2. **PR 2 — Fact Extraction**
   Teach `UserMemoryService` to extract contradiction facts into the sidecar table.
3. **PR 3 — Contradiction Recall + Annotation**
   Build hard-recall + annotation helpers for the judge pool.
4. **PR 4 — Judge Integration + Telemetry**
   Pass contradiction candidates into `ProvocationJudge` and review tooling.

## PR 1 — Fact Substrate

### Task 1.1: Extend `MemoryKind`

**Files:**
- Modify: `Sources/Nous/Models/MemoryEntry.swift`
- Test: `Tests/NousTests/UserMemoryServiceTests.swift`

- [ ] Add:
  - `case decision`
  - `case boundary`
- [ ] Keep existing cases unchanged.
- [ ] Add serialization tests proving:
  - new kinds encode/decode correctly
  - old rows still decode safely

### Task 1.2: Add `MemoryFactEntry`

**Files:**
- Create: `Sources/Nous/Models/MemoryFactEntry.swift`

Suggested shape:

```swift
struct MemoryFactEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var scope: MemoryScope
    var scopeRefId: UUID?
    var kind: MemoryKind          // Phase 1 only: decision / boundary / constraint
    var content: String
    var confidence: Double
    var status: MemoryStatus
    var stability: MemoryStability
    var sourceNodeIds: [UUID]
    let createdAt: Date
    var updatedAt: Date
}
```

### Task 1.3: Add `memory_fact_entries` table

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift`
- Test: `Tests/NousTests/MemoryFactStoreTests.swift`

- [ ] Add a new SQLite table:
  - `id`
  - `scope`
  - `scopeRefId`
  - `kind`
  - `content`
  - `confidence`
  - `status`
  - `stability`
  - `sourceNodeIds`
  - `createdAt`
  - `updatedAt`
- [ ] Add indexes for:
  - `(scope, scopeRefId, status)`
  - `kind`
  - `updatedAt`
- [ ] Add helper methods:
  - `insertMemoryFactEntry(_:)`
  - `updateMemoryFactEntry(_:)`
  - `fetchMemoryFactEntries(...)`
  - `fetchActiveMemoryFactEntries(scope:scopeRefId:kinds:)`
- [ ] Keep `memory_entries` invariant unchanged.

### Task 1.4: PR 1 check

- [ ] Full test suite green
- [ ] Open stacked PR with no behavior change claim

## PR 2 — Fact Extraction

### Task 2.1: Conversation fact extraction

**Files:**
- Modify: `Sources/Nous/Services/UserMemoryService.swift`
- Test: `Tests/NousTests/UserMemoryServiceTests.swift`

- [ ] Add a new extraction path that runs after `refreshConversation(...)` writes the canonical thread row.
- [ ] Input source remains **Alex-only** message evidence.
- [ ] Extraction target is the sidecar fact table, not canonical `memory_entries`.
- [ ] Phase 1 fact kinds allowed here:
  - `decision`
  - `boundary`
  - `constraint`
- [ ] Do not emit `identity`, `preference`, `relationship`, or `thread` facts through this path.

Recommended implementation:

- one small LLM call returning strict JSON array of facts
- each fact includes:
  - `kind`
  - `content`
  - `confidence`

### Task 2.2: Project fact roll-up

**Files:**
- Modify: `Sources/Nous/Services/UserMemoryService.swift`
- Test: `Tests/NousTests/UserMemoryServiceTests.swift`

- [ ] When project memory refreshes, optionally roll up durable `decision` / `boundary` / `constraint` facts from child conversation facts into project-scoped fact rows.
- [ ] Keep global identity path unchanged in Phase 1.
- [ ] Do not add a second generic project summary system.

### Task 2.3: Migration fixtures

**Files:**
- Modify: relevant tests / fixtures

- [ ] Add sample fact extraction fixtures for:
  - one `decision`
  - one `boundary`
  - one `constraint`
- [ ] Add backwards-compat test that old data with no fact rows still works.

### Task 2.4: PR 2 check

- [ ] Full suite green
- [ ] Open stacked PR with extraction-only behavior change

## PR 3 — Contradiction Recall + Annotation

### Task 3.1: Hard recall helper

**Files:**
- Modify: `Sources/Nous/Services/UserMemoryService.swift`
- Create: `Tests/NousTests/ContradictionRecallTests.swift`

- [ ] Add a helper that fetches active in-scope fact rows for:
  - `decision`
  - `boundary`
  - `constraint`
- [ ] `stable` vs `temporary` is **not** a recall gate in Phase 1.
- [ ] Enforce scope and active-status filtering.

Suggested helper:

```swift
func contradictionRecallFacts(
    projectId: UUID?,
    conversationId: UUID
) throws -> [MemoryFactEntry]
```

### Task 3.2: Annotation helper

**Files:**
- Modify: `Sources/Nous/Services/UserMemoryService.swift`
- Test: `Tests/NousTests/ContradictionRecallTests.swift`

- [ ] Add a testable helper that runs **after pool construction** and **before judge prompt assembly**.
- [ ] Preferred home:
  `UserMemoryService.annotateContradictionCandidates(...)`
- [ ] Mark the top 1-3 most relevant contradiction facts in the current pool.
- [ ] Use **relative ranking in-pool**, not a fixed global similarity threshold.

Suggested return shape:

```swift
struct AnnotatedCitableEntry {
    let entry: CitableEntry
    let isContradictionCandidate: Bool
}
```

### Task 3.3: Merge into judge pool assembly

**Files:**
- Modify: `Sources/Nous/Services/UserMemoryService.swift`
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`

- [ ] Update pool assembly so judge inputs include:
  - 2-4 contradiction hard-recall facts
  - 4-6 vector-recall items
  - 1-2 recency seeds
- [ ] Do **not** duplicate scope-based context assembly already feeding the main prompt.

### Task 3.4: PR 3 check

- [ ] Full suite green
- [ ] Open stacked PR with retrieval-layer behavior change

## PR 4 — Judge Integration + Telemetry

### Task 4.1: Prompt-input annotation only

**Files:**
- Modify: `Sources/Nous/Services/ProvocationJudge.swift`
- Test: `Tests/NousTests/ProvocationOrchestrationTests.swift`

- [ ] Pass contradiction-candidate hints into the judge prompt.
- [ ] Keep `JudgeVerdict` schema unchanged in Phase 1.
- [ ] Example prompt hint:
  `` `[contradiction-candidate] id=<entry-id>` ``

### Task 4.2: Telemetry discriminator

**Files:**
- Modify: `Sources/Nous/Services/GovernanceTelemetryStore.swift`
- Modify: NodeStore judge-event helpers if present on stacked branch

- [ ] Add lightweight `provocation_kind` support:
  - `contradiction`
  - `spark`
  - `neutral`
- [ ] This is review tooling, not a large telemetry redesign.

### Task 4.3: Orchestration tests

**Files:**
- Modify: `Tests/NousTests/ProvocationOrchestrationTests.swift`

- [ ] Add tests proving:
  - contradiction candidates reach the judge prompt
  - verdict schema does not change
  - contradiction provocation can be separated in review data

### Task 4.4: PR 4 check

- [ ] Full suite green
- [ ] Open stacked PR with contradiction-oriented judge improvement

## Success Criteria

Phase 1 is successful if it produces:

- fewer missed contradiction opportunities in review
- fewer wrong-memory contradiction attempts
- lower thumbs-down rate on contradiction-oriented interjections
- a judge pool that is easier to explain when reviewed by hand

## Do Not Expand

If implementation starts drifting into any of the following, stop and open a follow-up plan instead:

- full retrieval reranker
- entry-level vector index for all memory rows
- broad memory taxonomy redesign
- ask-back UX
- local heuristics
