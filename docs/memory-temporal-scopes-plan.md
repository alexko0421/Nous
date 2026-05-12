# Plan: Align Nous memory with the "Four Temporal Scopes" model

Context for the implementing agent: this plan came out of reviewing the TDS
article *"A Practical Guide to Memory for Autonomous LLM Agents"* (based on arXiv
2603.07670) against Nous's current memory stack. The article frames agent memory
as four scopes with different lifecycles: **working** (context window),
**episodic** (interaction history), **semantic** (distilled facts), **procedural**
(skills/workflows). Nous already has all four conceptually — see
`docs/memory-jurisdiction.md`. This plan is about closing the *gaps*, not a
rewrite. Do **not** restructure existing substrates; add the missing lifecycle
machinery on top.

## Where Nous already stands (don't redo these)

- Episodic→semantic distillation already exists: `MemorySynthesisService`
  (`refreshConversation` / `refreshProject` / `promoteToGlobal`),
  `WeeklyReflectionService`, `MemoryGraphWriter` + `memory_atoms` with
  supersession, `MemoryCurator` (write bar), `MemoryCuratorReviewService`
  (stale-entry review).
- Working-memory assembly: `TurnMemoryContextBuilder`, `MemoryProjectionService`
  (read-time budgets), `QuickActionMemoryPolicy`.
- Atoms carry `confidence`, `lastSeenAt`, `status`, `validFrom/validUntil`.

## Gaps to close (priority order)

### 1. Episodic decay / retention (highest ROI)
Problem: raw episodic data (`memory_recall_events`, full message history,
`memory_entries(scope=.conversation)`) accumulates forever. Once a conversation
has been distilled into a semantic summary / atoms, nothing down-weights or
prunes the raw trail, so recall and prompt assembly get noisier over time.

Do:
- Add a `MemoryRetentionService` (background, off main actor; model it on
  `MemoryCuratorReviewService` + `WeeklyReflectionService` idempotency style).
- Policy: for a conversation older than N days whose content is already covered
  by an active `memory_entries` summary AND/OR ≥1 active atom with a
  `sourceNodeId` pointing at it, mark its `memory_recall_events` as archived
  (new status, not deleted) and stop including archived rows in
  `MemoryQueryPlanner` / `TurnMemoryContextBuilder` candidate sets.
- Never touch the source messages themselves (audit trail) — only the recall
  index and conversation-scoped summaries.
- Add a counter/telemetry row via `BackgroundAIJobTelemetryStore`.
- Tests: `Tests/NousTests/MemoryRetentionServiceTests.swift` — covered vs
  uncovered conversation, idempotent re-run, archived rows excluded from query
  planner.

### 2. Importance / relevance signal on atoms
Problem: supersession handles *contradiction* but not *relevance decay*. A stale
`event` or `task` atom that nobody references stays at full weight.

Do:
- Add `accessCount: Int` (bump on each `memory_recall_events` hit that cites the
  atom) and derive a recency-weighted score in `MemoryQueryPlanner` ranking
  (don't store a denormalized score — compute from `confidence`, `lastSeenAt`,
  `accessCount`, `type`). Type-aware half-life: `event`/`task` decay fast,
  `identity`/`boundary`/`constraint` effectively never.
- `MemoryRetentionService` (from #1) demotes atoms whose derived score falls
  below a floor to `status = .dormant` (resurrect on next recall hit).
- Migration: additive column only; see `MemoryV2Migrator` / `MemoryEntriesMigrator`
  for the pattern.
- Tests: ranking changes, dormant→active resurrection, identity atoms never
  demoted.

### 3. Procedural memory is author-only
Problem: procedural knowledge (response modes in `anchor.md`, agent configs,
`AgentTool` registry, `QuickActionMemoryPolicy`) is hand-written and never
self-updates. The article's procedural scope expects slow but real evolution.

Do (smaller, more exploratory — get Alex's sign-off on scope before building):
- Don't auto-edit `anchor.md` — it's frozen by jurisdiction rules.
- Instead: let `WeeklyReflectionService` emit a separate `reflection_claim`
  subtype `procedural_hint` (e.g. "Alex repeatedly asks for the brainstorm agent
  to skip the recap"), surfaced in the memory inspector for manual promotion
  into agent config. No automatic behavior change.
- Tests: validator accepts/rejects procedural hints; inspector surfaces them.

### 4. Unified working-memory assembler (low priority, optional)
Problem: turn-context assembly logic is spread across `TurnMemoryContextBuilder`,
`MemoryProjectionService`, `QuickActionMemoryPolicy` with no single "belief-state"
entry point; eviction/priority rules are implicit.

Do (only if #1–#3 land cleanly): introduce a thin `BeliefStateAssembler` that
calls the existing builders in one place and owns the priority/eviction order
explicitly. Pure refactor, no behavior change, golden-test backed
(`Tests/NousTests` Bucket D shapes).

## Sequencing
1 → 2 (share `MemoryRetentionService`) → 3 (independent, needs Alex scope call)
→ 4 (optional cleanup). Each step is its own bead + commit.

## Verification
- `xcodebuild` / existing test buckets must stay green after each step.
- For #1/#2 add a behavior-eval fixture: a long-horizon conversation set where
  the right distilled fact still surfaces after many intervening turns and stale
  events don't crowd the prompt — wire into `BehaviorEvalRunner`.
- Run `scripts/agentic_workflow_check.sh` before each `beads_agent_workflow.sh finish`.

## Beads
Open one parent bead "Memory: temporal-scope lifecycle gaps" plus a child per
step (1–4). The parent description can be this file's path.
