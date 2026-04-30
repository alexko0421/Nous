# SkillStore Lazy-Load — Mode-Scoped, Conversation-Sticky Index Design

**Date:** 2026-04-29
**Status:** P1 of a 5-tier Hermes-inspired memory upgrade roadmap. Builds on Phase 2.1 SkillStore (shipped 2026-04-28).
**Branch context:** Builds on `alexko0421/quick-action-agents`.
**Author:** Alex Ko, with assistance.

## Context

Origin: Hermes Agent's memory architecture article (2026-04-29) prompted a layered audit of Nous's memory systems. The audit identified Phase 2.1 SkillStore as the largest token-cost gap vs the Hermes pattern: every matched skill's full content (`payload.action.content`) is injected into every turn. Measured cost is roughly 5 skills × ~500 tokens = ~2,500 tokens per turn in matched modes, where a Hermes-style index would cost ~100 tokens.

Position in the roadmap: P1 (this spec) → P2 (anchor budget + usage banner) → P3 (anchor pre-write safety scan) → P4 (retrieval FTS5) → P5 (session compression). Each tier ships independently. P1 is highest-impact, lowest-risk because:

1. Phase 2.1 just shipped — refactor cost is fresh.
2. ~25× token reduction is a measurable win.
3. Risk surface contained to SkillStore + its consumers; no anchor / retrieval changes.
4. SkillStore Phase 2.1 has no production users beyond Alex (Path B), so no upgrade contract to honor.

This spec does **not** modify `Sources/Nous/Resources/anchor.md`; the anchor is frozen by design (`AGENTS.md:39, 131`).

## Design philosophy

Hermes's pattern: tool-call lazy-load with an index of every skill, session-sticky lifetime, file-based storage.

Nous P1 deviates on three deliberate axes:

- **Index scope** — Matcher pre-filters by mode (preserving the "per-mode not per-reply" balance principle); only matched skills enter the index.
- **Lifetime** — Conversation-sticky, not session-sticky. The NousNode is the natural boundary; "session" in Nous is ambiguous (app launch? conversation switch? user idle?).
- **Storage** — Relational tables (consistent with `memory_fact_entries`), not files.

Trade-off: cache stability for the skill block is slightly weaker than pure Hermes (mode switches invalidate Block 3), in exchange for stronger mode discipline. Block 1 (anchor + policies) and Block 2 (slow memory + memory evidence) remain cached for the duration of a conversation regardless of skill activity.

We label the resulting design **mode-scoped, conversation-sticky lazy-load**.

## Scope

### In scope

- New table `conversation_loaded_skills` for sticky persistence.
- Skill payload bump v1 → v2 with optional `useWhen` field.
- New `SkillStore` methods: `loadedSkills(in:)`, `markSkillLoaded(_:in:at:)`, `unloadAllSkills(in:)`.
- New filtering logic in `PromptContextAssembler.renderSkillIndex` to exclude already-loaded skills (matcher protocol unchanged).
- New `PromptContextAssembler` rendering for `ACTIVE SKILLS` and `SKILL INDEX` sections.
- New `loadSkill` tool registered with foreground LLM (Sonnet 4.6 via OpenRouter).
- Three `cache_control: ephemeral` breakpoints across the stable prefix (after Block 1, Block 2, and Block 3; volatile section unmarked).
- Removal of the full-injection path in `QuickActionAddendumResolver`.
- Build-time backfill script (Gemini 2.5 Pro) for `useWhen` field on existing seed skills.
- Unit, integration, and cache-wire-format tests.

### Out of scope

- Anchor character / token caps and usage banner (P2).
- Anchor pre-write safety scanning for credentials, prompt injection, invisible Unicode (P3).
- Retrieval FTS5 indexing (P4).
- Conversation-level summarization or pre-compression memory flush (P5).
- Skill Fold schema evolution (Codex 2026-04-27 flagged 3 top-killer bugs; tracked separately).
- USER.md as separate file, Honcho integration, `parent_session_id` lineage (Path B explicit reject).
- Active section LRU eviction (handle if/when bloat is observed).
- Per-turn `max_loadSkill_calls` soft cap (logs-driven addition if model spams).
- Super-long skill content chunking.
- User-facing "Reset skills" button (debug API only in P1).

## Schema changes

### New table

```sql
CREATE TABLE IF NOT EXISTS conversation_loaded_skills (
    conversation_id TEXT NOT NULL,
    skill_id TEXT NOT NULL,
    loaded_at REAL NOT NULL,
    PRIMARY KEY (conversation_id, skill_id),
    FOREIGN KEY (conversation_id) REFERENCES nodes(id) ON DELETE CASCADE,
    FOREIGN KEY (skill_id) REFERENCES skills(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_loaded_skills_conv
    ON conversation_loaded_skills(conversation_id);
```

Notes:

- `conversation_id` and `skill_id` are UUID strings (matches `skills` and `nodes` conventions).
- `loaded_at` is REAL epoch seconds (matches `NodeStore.swift:531` convention).
- Composite primary key gives idempotency for free: `INSERT OR IGNORE` won't create duplicates.
- Cascade delete handles conversation removal and skill deletion safely without orphan rows.

Rejected alternative: denormalized `nodes.loaded_skill_ids TEXT` (JSON array). The relational table wins because:

- Future analytics ("this skill loaded across N conversations") are direct queries.
- `loaded_at` per row supports future recency hints without re-engineering.
- JSON-column writes are not concurrency-safe in SQLite without extra locking.

### Skill payload bump v1 → v2

```jsonc
{
  "payloadVersion": 2,
  "name": "direction-skeleton",
  "description": "Direction Mode Quality Contract",
  "useWhen": "Use when: structuring direction-mode analysis.",
  "source": "alex",
  "trigger": { "kind": "mode", "modes": ["direction"], "priority": 90 },
  "action": { "kind": "promptFragment", "content": "..." },
  "rationale": "...",
  "antiPatternExamples": []
}
```

Field changes:

- `payloadVersion` bumped from `1` to `2`. Decoder accepts `1...2`.
- `useWhen: String?` added — optional one-line hint rendered in `SKILL INDEX`. Falls back to `description` if nil.

Backward compatibility: v1 payloads remain readable (`useWhen == nil`). At rendering time the index uses `useWhen ?? description`.

## Service interfaces

### `SkillStore`

```swift
protocol SkillStoring {
    // Existing — unchanged
    func fetchActiveSkills(userId: String) throws -> [Skill]
    func fetchSkill(id: UUID) throws -> Skill?
    func insertSkill(_ skill: Skill) throws
    func updateSkill(_ skill: Skill) throws
    func setSkillState(id: UUID, state: SkillState) throws
    func incrementFiredCount(id: UUID, firedAt: Date) throws

    // New
    func loadedSkills(in conversationID: UUID) throws -> [Skill]
    func markSkillLoaded(_ skillID: UUID, in conversationID: UUID, at: Date) throws
    func unloadAllSkills(in conversationID: UUID) throws
}
```

Semantics:

- `loadedSkills(in:)` returns skills present in `conversation_loaded_skills` for the given conversation, ordered by `loaded_at ASC`. Includes skills now `retired` or `disabled` (rendering tags them).
- `markSkillLoaded(_:in:at:)` performs `INSERT OR IGNORE` then, if a row was actually inserted, calls `incrementFiredCount` with the same timestamp. Returns idempotent success regardless.
- `unloadAllSkills(in:)` is a debug API. No user-facing UI in P1.

### `SkillMatcher`

The existing `SkillMatching` protocol stays as-is:

```swift
func matchingSkills(
    from skills: [Skill],
    context: SkillMatchContext,
    cap: Int
) -> [Skill]
```

Index-side filtering (excluding already-loaded skills) lives in `PromptContextAssembler.renderSkillIndex`, not in the matcher. Keeping the matcher unaware of conversation state preserves its single responsibility (mode + priority + cap selection) and makes both halves easier to test in isolation.

### `fired_count` semantic shift

Pre-P1: incremented when matcher selects a skill (no documented consumer).

P1: incremented only when `markSkillLoaded` actually inserts a new row — i.e. the model expressed intent to use the skill via tool call. The new semantic is "distinct conversations in which this skill was expanded by the model." More meaningful as a usage signal.

No data migration needed for existing rows (the prior count is loose anyway and fits the new semantic loosely).

## Tool registration

Tool definition handed to the foreground LLM:

```swift
LLMTool(
    name: "loadSkill",
    description: """
        Load the full content of a skill from SKILL INDEX so you can apply it to the current turn.
        Only call this if a skill in SKILL INDEX clearly fits the user's input.
        Skills already in ACTIVE SKILLS are loaded — do not call loadSkill for them again.
        Once loaded, the skill stays active for the rest of this conversation.
        """,
    parameters: [
        "name": ToolParameter(
            type: .string,
            description: "The exact skill name from SKILL INDEX, e.g. 'direction-skeleton'.",
            required: true
        )
    ]
)
```

Tool result contract:

| Outcome | Response shape |
|---|---|
| Newly loaded | `{"status": "loaded", "name": "...", "content": "<action.content>"}` |
| Already loaded (idempotent) | `{"status": "already_loaded", "name": "..."}` |
| Name not in current index | `{"status": "error", "code": "not_found", "available": [<index names>]}` |
| Skill retired or disabled | `{"status": "error", "code": "unavailable", "reason": "..."}` |
| Internal failure (DB error etc.) | `{"status": "error", "code": "internal", "retry": true}` |

`already_loaded` is intentionally not an error — the model occasionally misjudges and we don't want to surface false negatives.

## Prompt structure

### Block layout

System prompt assembly order, most stable to most volatile:

1. **Block 1** (`cache_control: ephemeral`) — `anchor.md` + policies (memory interpretation, safety, grounding, real-world decision, summary output, conversation-title output).
2. **Block 2** (`cache_control: ephemeral`) — slow memory (global / project / conversation) + memory evidence snippets.
3. **Block 3** (`cache_control: ephemeral`) — `ACTIVE SKILLS` section + `SKILL INDEX` section.
4. **Volatile** (no `cache_control`) — chat mode addendum (plain text only, no skill content) + citations + attachments + safety gate + interactive clarification UI + user message.

Sonnet supports up to 4 `cache_control` breakpoints. This layout uses 3 markers (after Block 1, Block 2, and Block 3); the volatile section is unmarked. The 4th breakpoint slot is reserved for future granularity (e.g., separating anchor from policies if memory governance later mutates policies more frequently).

### Block 3 rendering

```
═══════════════════════════════════════════════
ACTIVE SKILLS (loaded earlier this conversation)
═══════════════════════════════════════════════
▸ direction-skeleton — Direction Mode Quality Contract
<full content from skill.payload.action.content>

▸ decision-frame — Structured decision framing
<full content>

═══════════════════════════════════════════════
SKILL INDEX (this mode — call loadSkill(name) to use)
═══════════════════════════════════════════════
- planning-frame: Plan-level structure.
  Use when: user asks for a plan.
- contradiction-pause: Surface tension between user statement and prior facts.
  Use when: current input contradicts a hard-recall fact.
```

### Edge cases

| Scenario | Behavior |
|---|---|
| First turn, nothing loaded yet | `ACTIVE SKILLS` section omitted entirely (no header, no empty placeholder) |
| Current mode has zero matched skills | `SKILL INDEX` section omitted entirely |
| Skill matched in current mode but already in `ACTIVE` | Excluded from `SKILL INDEX` (visible only in `ACTIVE`) |
| All matched skills already in `ACTIVE` | `SKILL INDEX` section omitted |
| Loaded skill's `trigger.modes` does not include current mode | Stays in `ACTIVE` (sticky persists across mode switches; mode controls supply, sticky controls visibility) |
| Loaded skill becomes `retired` or `disabled` mid-conversation | Render in `ACTIVE` with `(retired)` tag at end of name; do NOT auto-evict (avoid mid-conversation content disappearing) |
| Skill's `useWhen` is nil | Index entry uses `description` only |

### Deterministic rendering

To preserve cache hits, Block 3 contents must be byte-identical when underlying state is unchanged:

- `ACTIVE` order: `loaded_at ASC` (new entries append to tail; never re-sort).
- `SKILL INDEX` order: `priority DESC, name ASC` (deterministic per mode).
- No timestamps in rendered text.
- No `loaded_skill_count` or similar derived counters in Blocks 1, 2, or 3.

## Cache strategy

Provider: OpenRouter Sonnet 4.6 (foreground), with `cache_control: {type: "ephemeral"}` on each block boundary.

Invalidation table:

| Trigger | Blocks invalidated |
|---|---|
| `anchor.md` modified (frozen, near-zero in practice) | 1, 2, 3 |
| Slow memory governance refresh (~weekly) | 2, 3 |
| New skill loaded (`ACTIVE` grows) | **3 only** |
| Mode switch (`SKILL INDEX` content changes) | **3 only** |
| New user turn | Volatile only (no cached prefix change) |

Invariant: within a single conversation, Block 1 + Block 2 hit cache from turn 2 onward regardless of any skill-related event.

Fallback: cache is an optimization, not a correctness guarantee. If Sonnet's cache misbehaves, the system degrades to "no caching" with full token cost — still ~70% cheaper than the current full-injection baseline.

## Migration

### Code changes (single PR)

| File | Change |
|---|---|
| `Sources/Nous/Services/NodeStore.swift` | Add `conversation_loaded_skills` table + migration step |
| `Sources/Nous/Services/SkillStore.swift` | Add `loadedSkills(in:)`, `markSkillLoaded(_:in:at:)`, `unloadAllSkills(in:)` |
| `Sources/Nous/Models/Skill.swift` | Bump `payloadVersion` accepted range to `1...2`; add `useWhen: String?` |
| `Sources/Nous/Services/SkillMatcher.swift` | No protocol change — existing `matchingSkills(from:context:cap:)` stays |
| `Sources/Nous/Services/PromptContextAssembler.swift` | Add `renderActiveSkills()`, `renderSkillIndex()`; index renderer queries `SkillStore.loadedSkills(in:)` and filters out loaded ids; insert before volatile section; place 3 `cache_control` markers |
| `Sources/Nous/Services/QuickActionAddendumResolver.swift` | Remove line 71 (`matched.map { $0.payload.action.content }.joined(separator: "\n\n")`); the resolver still computes matched skills (for tracker fire) but no longer concatenates `action.content` into the addendum string |
| `Sources/Nous/Services/LLMService.swift` | Register `loadSkill` tool with Sonnet 4.6 / OpenRouter; route `loadSkill` tool calls to SkillStore |

### Build-time backfill (separate commit, not in PR diff)

`scripts/backfill-skill-useWhen.swift`:

1. For each active skill where `payload.useWhen == nil`:
2. Send `rationale` + `description` + `trigger.modes` to Gemini 2.5 Pro with a JSON-schema response specifying `{"useWhen": "..."}`.
3. Receive structured output.
4. Manual review (skill count expected < 20; review one-by-one).
5. Patch `seed-skills.json` and commit.

Runtime never invokes Gemini. This is build-time tooling only.

### No backward compatibility

Single PR removes full-injection cleanly. No feature flag, no fallback path. Path B (Alex sole user) has no upgrade contract to honor; preserving dead code adds maintenance burden without value.

Rollback path: revert the PR. Data persisted in `conversation_loaded_skills` remains harmlessly (no consumer reads it after revert; can be left or dropped).

## Observability

P1 ships with `loaded_at` timestamps captured (sufficient input for future queries). User-facing inspector or logs surface deferred.

Queries supported by the schema for future debug surfaces:

| Metric | Source |
|---|---|
| `loaded_skills_per_conversation_avg` | Aggregate `COUNT(*)` over `conversation_loaded_skills GROUP BY conversation_id` |
| `tool_call_rate_per_turn` | LLMService tool dispatch logs (count `loadSkill` invocations / total turns) |
| `idempotent_hit_rate` | Count `already_loaded` responses / total `loadSkill` calls |
| `unknown_name_rate` | Count `not_found` responses / total `loadSkill` calls |

Threshold interpretation guidance:

- High `idempotent_hit_rate` (> 20%) suggests tool description doesn't dissuade redundant calls — refine wording.
- High `unknown_name_rate` (> 5%) suggests model hallucinating skill names — index format may need clarification.
- `loaded_skills_per_conversation_avg` > 5 suggests over-loading; consider per-turn soft cap.

## Testing

### Unit tests (new)

```
SkillStoreTests:
  - markSkillLoaded_isIdempotent
  - markSkillLoaded_incrementsFiredCount_onlyOnInsert
  - loadedSkills_returnsOrderedByLoadedAt
  - loadedSkills_includesRetiredSkills
  - unloadAllSkills_clearsConversation
  - cascadeDelete_onConversationRemoval
  - cascadeDelete_onSkillRemoval

PromptContextAssemblerTests:
  - rendersActiveSkillsSection_whenLoadedExist
  - skipsActiveSection_whenEmpty
  - rendersSkillIndex_withMatchedSkills
  - rendersSkillIndex_excludingLoaded
  - skipsIndex_whenAllMatchedAreLoaded
  - rendersRetiredSkillInActive_withTag
  - useWhenNil_fallsBackToDescription
  - activeSkills_orderedByLoadedAtAsc
  - skillIndex_orderedByPriorityDescThenName
  - cacheControlMarkers_placedAtThreeBoundaries

LoadSkillToolTests:
  - tool_returnsContent_onSuccess
  - tool_returnsError_onUnknownName_withAvailableList
  - tool_returnsError_onRetiredSkill
  - tool_returnsAlreadyLoaded_onDuplicateCall
  - tool_returnsError_onInternalFailure_withRetryFlag
```

### Integration test (new)

`testConversationStickyFlow`:

1. Start a Direction-mode conversation.
2. Turn 1: assert `SKILL INDEX` populated with mode-matched skills; `ACTIVE SKILLS` section absent.
3. Simulate model `loadSkill("direction-skeleton")`.
4. Assert `conversation_loaded_skills` row inserted; `fired_count` incremented.
5. Turn 2: assert `ACTIVE SKILLS` contains `direction-skeleton` with full content; `SKILL INDEX` excludes it.
6. Switch to 倾观点 mode.
7. Turn 3: assert `ACTIVE SKILLS` still contains `direction-skeleton` (cross-mode persistence); `SKILL INDEX` shows 倾观点-mode matched skills.
8. Re-call `loadSkill("direction-skeleton")` → assert `already_loaded` returned, no duplicate row, no extra `fired_count` increment.

### Cache wire-format test

`testCacheBreakpoints`:

- 3 `cache_control` markers placed at correct positions (after Block 1, Block 2, Block 3) in the assembled message.
- After adding a loaded skill: Block 1 + Block 2 byte-identical to pre-load (cache key preserved).
- After mode switch: Block 1 + Block 2 byte-identical (only Block 3 changes).

## Risks and mitigation

| Risk | Severity | Mitigation |
|---|---|---|
| Sonnet doesn't reliably call `loadSkill` (skills become invisible to behavior) | Medium | Tool description is explicit; first conversations monitored; if needed, add a sentence "If a skill in INDEX clearly matches the user input, call loadSkill before answering" |
| Model spam-loads skills | Low | Matcher cap=5 still bounds upper limit; per-turn soft cap (`max_loadSkill_calls=2`) addable post-merge if observed |
| Sonnet tool-call protocol changes | Low | OpenRouter / Anthropic API stable; revert PR if break |
| User perceives +1 round-trip on first skill load (~1-2s extra latency) | Medium | Acceptable for Path B private use; first-turn UI hint deferred from P1 |
| Skill content > 2K tokens bloats `ACTIVE` section | Low | Existing seed skills are ~500 tokens; chunking deferred until observed |

## Success criteria

P1 is judged "good ship" when:

1. **Direction mode + EverMind-envy prompt**: live-test reply quality matches or beats current output (memory-verified validation harness, 2026-04-28).
2. **倾观点 mode + philosophical prompt**: mode discipline distinct from Direction mode (no cross-mode bleed).
3. **Token cost**: Direction-mode turn skill section < 250 tokens (vs current ~2,500), ≥ 80% reduction.
4. **Cache hit ratio**: same-conversation Block 1 + Block 2 hit ratio > 95% from turn 2 onward.
5. **Mid-conversation mode switch**: `ACTIVE` skills retained correctly; new `SKILL INDEX` reflects new mode.

Tests 1 and 2 must pass before merge (live-test on fresh conversations, per the 2026-04-26 surgical-edit discipline). Tests 3-5 monitored post-merge.

## Comparison to Hermes

| Dimension | Hermes | Nous P1 | Reason for divergence |
|---|---|---|---|
| Index scope | All skills always | Mode-matched only | "Per-mode not per-reply" balance principle (memory note 2026-04-23) |
| Index format | name + description | + `useWhen` hint | Reduce mis-loads, accelerate routing |
| Lifetime | Session-sticky | Conversation-sticky | NousNode is a natural boundary; "session" ambiguous |
| `ACTIVE` / `INDEX` visibility | Implicit (loaded skills blend into prompt) | Explicit dual-section header | Clearer model mental model; avoid re-load |
| Storage | File system (`~/.hermes/skills/`) | SQLite relational | Consistent with `memory_fact_entries`; query-able |
| Mode concept | None | First-class hard filter | Nous design principle, not Hermes-style open dispatch |
| Idempotent duplicate-load | Unspecified in article | Explicit `already_loaded` status | Avoid false-error model state |

Performance comparison:

- Token efficiency: Nous index ~150 tokens (matched-only) vs Hermes index ~500+ tokens (all skills). Nous lighter by design.
- Cache stability: Nous slightly weaker for the skill block (mode switches invalidate Block 3). Hermes index is fully stable across mode-equivalent state.
- Net: comparable in low-mode-switch scenarios; minor regression vs Hermes in high-mode-switch scenarios; both far superior to current full-injection.

What we deliberately do NOT borrow from Hermes:

- Memory flush before compression (Nous has no compression layer to flush before).
- Honcho cross-device user modeling (Path B single-user / single-device).
- `parent_session_id` lineage (scope-based memory more appropriate for single-user workflows).
- Auxiliary model summarize-on-recall (Nous's write-time pre-summary is cheaper and validated).

## Implementation order (within the single PR)

1. **Data layer** — `NodeStore` migration; `SkillStore` new methods; `Skill` payload v2 (`useWhen` field).
2. **Backfill** (separate commit, not part of PR diff) — Gemini batch-generate `useWhen` for existing seed skills; manual review; patch `seed-skills.json`.
3. **Rendering layer** — `PromptContextAssembler.renderActiveSkills` + `renderSkillIndex` (the latter queries `SkillStore.loadedSkills(in:)` and filters matched skills accordingly); place 3 `cache_control` markers.
4. **Tool layer** — `loadSkill` tool registration + dispatch in `LLMService`; route tool calls to `SkillStore.markSkillLoaded`.
5. **Cleanup** — strip line 71 of `QuickActionAddendumResolver` so the addendum no longer concatenates `action.content`.
6. **Tests** — 3 unit test suites (`SkillStoreTests`, `PromptContextAssemblerTests`, `LoadSkillToolTests`), 1 integration scenario, 1 cache wire-format scenario.

Order matters: step 5 must happen after steps 3 + 4 are functional, otherwise the prompt loses skill context entirely between commits.
