# SkillStore — Schema + Service Design (Phase 2.1, v2 minimal)

**Date:** 2026-04-28
**Status:** Phase 2.1 entry doc per `2026-04-28-nous-v2-skill-fold-strategy.md` (Path B). Implementation entry, not strategic spec.
**Branch context:** Builds on `alexko0421/quick-action-agents` after Phase 1 (tool use + reasoning loop) ships.
**Author:** Alex Ko, with assistance.

## Context

Path B spec commits Nous to a Skill Fold layer where `Skill` is first-class addressable data. v2 minimal scope: prove the **mechanism** is debuggable + maintainable for one user before adding any feature surface.

This doc is the **second draft after Codex iteration**. The first draft tried to migrate all three modes (Direction / Brainstorm / Plan) plus add `regex` triggers, `specificity` ordering, `turnRange` gating, and `intent` reservation. Codex challenge surfaced 21+ findings across 2 rounds, and the recurring lesson was: **every new feature is new bug surface**. v2 strips back to the minimum that proves the mechanism.

### What got cut from the original draft (and why)

- **`regex` trigger kind** — Cantonese / mixed-script / full-width punctuation normalization is a sub-project; not v2 scope.
- **`intent` trigger kind** — reserved keyword without runtime path. Codex found internal contradictions every revision. Removed entirely; future v2.5 can add cleanly.
- **`specificity` field** — author-stored value tempted bad seeds to silently reorder. Replaced by name tiebreaker.
- **`turnRange` gating** — patches a square peg into a round hole for Plan's turn-state-machine. Plan stays special-cased.
- **Plan migration** — `PlanAgent.contextAddendum` is genuinely a state machine over `turnIndex` + `maxClarificationTurns`. Data-driven mapping creates duplicate-firing risk on any future cap change. Keep it in code.
- **`always` skills firing in default chat** — was a behavior regression. v2 requires every taste skill to declare a mode whitelist. Default chat is untouched.

## Schema

### `skills` table

```sql
CREATE TABLE IF NOT EXISTS skills (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL DEFAULT 'alex',  -- Hook 1: tenant_id, always 'alex' in v2
    payload TEXT NOT NULL                                                   -- Hook 2: portable JSON
        CHECK (json_valid(payload)),                                        -- corrupt JSON rejected at insert
    state TEXT NOT NULL DEFAULT 'active'
        CHECK (state IN ('active', 'retired', 'disabled')),
    fired_count INTEGER NOT NULL DEFAULT 0,
    created_at REAL NOT NULL,              -- Unix epoch SECONDS (matches NodeStore convention)
    last_modified_at REAL NOT NULL,
    last_fired_at REAL                     -- nullable; null = never fired yet
);

CREATE INDEX IF NOT EXISTS idx_skills_active ON skills(user_id, state);
```

Notes:

- `id` is UUID string, not Swift `UUID` type. Cross-language portability.
- `state = 'disabled'` allows Alex to temporarily turn off a skill without deleting it.
- Date columns are `REAL` (epoch seconds) per `NodeStore` convention (`NodeStore.swift:531`).
- `CHECK (json_valid(payload))` rejects corrupt JSON at insert; runtime decode failures are still possible (schema evolution) and must log + skip, never crash.
- `CHECK (state IN ...)` rejects typo states.

### `payload` JSON schema

```jsonc
{
  "payloadVersion": 1,                              // EXACTLY 1 in v2; v2.5 introduces migrator
  "name": "stoic-cantonese-voice",                  // human-readable id, must be unique within source='alex'
  "description": "Stoic Cantonese mentor voice",
  "source": "alex",                                 // 'alex' | 'importedFromAnchor'

  "trigger": {
    "kind": "mode",                                 // 'mode' | 'always'  (no 'regex', no 'intent' in v2)
    "modes": ["direction", "brainstorm", "plan"],   // REQUIRED for both kinds in v2
    "priority": 70                                  // 0-100, validated at insert
  },

  "action": {
    "kind": "promptFragment",                       // v2 only kind
    "content": "..."                                // non-empty, validated at insert
  },

  "rationale": "Why this skill exists",             // optional
  "antiPatternExamples": []                         // optional, defaults to []
}
```

- All JSON keys are camelCase to match Swift property names. Default `JSONDecoder` works without `convertFromSnakeCase`.
- `payloadVersion` must be **exactly `1`** in v2. Decoder fails on `0` or `2+`.
- Trigger kinds are `mode` and `always` only.
- **Both kinds REQUIRE `modes` whitelist in v2.** This means default companion chat (no chip tapped) does NOT fire any skill — same as today's behavior. v2.5 may relax this.
- Difference between `mode` and `always` within the same chip-tap mode:
  - `mode`: fires only when this skill is the structural skeleton for the matched mode (typically 1 per mode, replaces what was hardcoded in `*Agent.contextAddendum`).
  - `always`: layered taste skill. Fires on top of mode skeletons during chip-tap turns.

## Service interfaces

### `SkillStore`

```swift
protocol SkillStoring {
    func fetchActiveSkills(userId: String) throws -> [Skill]
    func fetchSkill(id: UUID) throws -> Skill?
    func insertSkill(_ skill: Skill) throws       // validates payload
    func updateSkill(_ skill: Skill) throws       // validates payload
    func setSkillState(id: UUID, state: SkillState) throws
    func incrementFiredCount(id: UUID, firedAt: Date) throws
}

struct Skill: Identifiable, Equatable {
    let id: UUID
    let userId: String
    let payload: SkillPayload
    var state: SkillState
    var firedCount: Int
    let createdAt: Date
    var lastModifiedAt: Date
    var lastFiredAt: Date?
}

enum SkillState: String, Codable { case active, retired, disabled }

struct SkillPayload: Codable, Equatable {
    let payloadVersion: Int
    let name: String
    let description: String?
    let source: SkillSource
    let trigger: SkillTrigger
    let action: SkillAction
    let rationale: String?
    let antiPatternExamples: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .payloadVersion)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .payloadVersion, in: c,
                debugDescription: "v2 SkillStore accepts payloadVersion=1 only"
            )
        }
        self.payloadVersion = version
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.source = try c.decode(SkillSource.self, forKey: .source)
        self.trigger = try c.decode(SkillTrigger.self, forKey: .trigger)
        self.action = try c.decode(SkillAction.self, forKey: .action)
        self.rationale = try c.decodeIfPresent(String.self, forKey: .rationale)
        self.antiPatternExamples = try c.decodeIfPresent([String].self, forKey: .antiPatternExamples) ?? []
    }
}

enum SkillSource: String, Codable {
    case alex
    case importedFromAnchor
}

struct SkillTrigger: Codable, Equatable {
    enum Kind: String, Codable { case always, mode }    // ONLY these two in v2
    let kind: Kind
    let modes: [QuickActionMode]                        // non-empty; required for both kinds
    let priority: Int                                   // 0-100
}

struct SkillAction: Codable, Equatable {
    enum Kind: String, Codable { case promptFragment }
    let kind: Kind
    let content: String                                 // non-empty
}
```

**Insert validation** (in `insertSkill` and `updateSkill`):

- `payload.payloadVersion == 1`
- `payload.trigger.modes` is non-empty
- `payload.trigger.priority` in `0...100`
- `payload.action.content` is non-empty after trimming whitespace

Each violation throws a descriptive `SkillStoreError`. Invalid skills NEVER reach SQLite.

### `SkillMatcher`

Pure logic, no IO.

```swift
struct SkillMatchContext {
    /// The active mode for matcher purposes:
    ///   `request.snapshot.activeQuickActionMode ?? inferredMode`.
    /// This matches how TurnPlanner currently selects `planningAgent`
    /// (TurnPlanner.swift:62-67), preserving Steward-inferred routes.
    /// nil = default companion chat → no skills fire (v2 invariant).
    let mode: QuickActionMode?
    let turnIndex: Int
}

protocol SkillMatching {
    func matchingSkills(
        from skills: [Skill],
        context: SkillMatchContext,
        cap: Int
    ) -> [Skill]
}

final class SkillMatcher: SkillMatching {
    func matchingSkills(
        from skills: [Skill],
        context: SkillMatchContext,
        cap: Int = 5
    ) -> [Skill] {
        guard let mode = context.mode else { return [] }
        return skills
            .filter { $0.state == .active }
            .filter { $0.payload.trigger.modes.contains(mode) }
            // Opening-turn invariant: mode-skeleton skills do NOT fire on turn 0.
            // The existing DirectionAgent/BrainstormAgent.contextAddendum returns nil
            // at turnIndex == 0; preserving that prevents the structured clarification
            // card from leaking into the opening chip turn.
            .filter { skill in
                if context.turnIndex == 0 && skill.payload.trigger.kind == .mode {
                    return false
                }
                return true
            }
            .sorted(by: Self.skillOrdering)
            .prefix(cap)
            .map { $0 }
    }

    /// Deterministic ordering: priority desc → name asc → id asc.
    /// SQLite fetch order is NEVER a tiebreaker.
    private static func skillOrdering(_ lhs: Skill, _ rhs: Skill) -> Bool {
        let lp = lhs.payload.trigger.priority
        let rp = rhs.payload.trigger.priority
        if lp != rp { return lp > rp }
        if lhs.payload.name != rhs.payload.name { return lhs.payload.name < rhs.payload.name }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
```

**Cap = 5** total. Mode skeleton lives at priority 90; taste skills at 55-70. With 7 seed skills:

- **Direction / Brainstorm chip turn (turnIndex >= 1)**: 1 mode skeleton + 4 taste = 5 skills fire. Cuts the lowest-priority taste (`weight-against-default-chat-baseline` at priority 55).
- **Plan chip turn**: 0 mode skeletons (Plan does not migrate) + 5 taste = 5 skills fire (all 5 taste).
- **Direction / Brainstorm opening turn (turnIndex == 0)**: 0 mode skeletons (turn-0 invariant) + 4-5 taste skills. Skeleton silenced so the opening prompt's "do not use structured clarification card yet" rule survives.
- **Plan opening turn (turnIndex == 0)**: PlanAgent's contextAddendum already returns nil at turn 0; skill matcher returns 4-5 taste; concatenation = taste only.
- **Default companion chat**: 0 (matcher returns empty when `mode == nil`).

No per-category cap, no priority boost — convention does the work. If Alex authors a taste skill at priority 95 that displaces the mode skeleton (priority 90), that's Alex's intentional override. v2 trusts the author.

**Turn-0 mode-skeleton skip** is hardcoded in the matcher: `kind == .mode && turnIndex == 0` always returns false. This preserves the existing opening-turn semantics in `DirectionAgent.swift:25` and `BrainstormAgent.swift:18` (which return nil at turn 0 today). The skip is unconditional in v2; v2.5 may add per-skill turn gating if needed.

### `SkillTracker`

```swift
protocol SkillTracking {
    func recordFire(skillIds: [UUID]) async throws
}
```

Fire-and-forget from caller. v2 tracks `firedCount + lastFiredAt` only. Success/fail signal deferred to v2.5.

### Integration: at callers of `assembleContext`, NOT inside

`ChatViewModel.assembleContext` is `nonisolated static`, sync, non-throwing. SkillMatcher runs at the **callers** that already assemble `quickActionAddendum`:

**`TurnPlanner.swift:230`** (per-turn invocation). Currently:
```swift
let quickActionAddendum: String? = planningAgent?.contextAddendum(turnIndex: agentTurnIndex)
```

After migration:
```swift
let inferredAddendum = planningAgent?.contextAddendum(turnIndex: agentTurnIndex)
let skillAddendum: String? = {
    #if DEBUG
    if DebugAblation.skipModeAddendum { return nil }
    #endif
    guard let store = skillStore else { return nil }
    let active = (try? store.fetchActiveSkills(userId: "alex")) ?? []
    let matched = skillMatcher.matchingSkills(
        from: active,
        context: SkillMatchContext(
            mode: planningQuickActionMode,    // explicit ?? inferred — same as planningAgent selection
            turnIndex: agentTurnIndex
        )
    )
    if !matched.isEmpty {
        Task.detached { try? await skillTracker.recordFire(skillIds: matched.map { $0.id }) }
    }
    return matched.isEmpty ? nil : matched.map { $0.payload.action.content }.joined(separator: "\n\n")
}()
let quickActionAddendum = [inferredAddendum, skillAddendum]
    .compactMap { $0 }
    .joined(separator: "\n\n")
    .nilIfEmpty
```

Critical points:

1. **Plan keeps its existing `inferredAddendum` from `planningAgent.contextAddendum(turnIndex:)`.** Direction and Brainstorm return `nil` from `contextAddendum` after migration (their addendum content moves to seed skills). Plan is unchanged — its turn-state-machine stays in `PlanAgent.swift`.
2. **`SkillMatchContext.mode`** uses `planningQuickActionMode` (explicit ?? inferred), matching how `TurnPlanner` selects `planningAgent` already. Steward-inferred routes preserve their mode skeleton.
3. **`DebugAblation.skipModeAddendum` is preserved** — the existing ablation toggle still works for the new path.
4. **Skill fetch failure is graceful** — `try?` collapses errors to `nil`; `?? []` falls through to no skills (same as if no skills are active). Errors logged elsewhere via `SkillStore` instrumentation.

**`ChatViewModel.swift:340`** (opening turn) gets the same pattern with `turnIndex: 0`.

### Dev trace inspector

`#if DEBUG` console output on each chip-tap turn:
```
[SkillTrace] Turn 17 (mode: direction)
  Active skills (3 fired):
  - direction-skeleton (priority 90, fired 12 times)
  - stoic-cantonese-voice (priority 70, fired 47 times)
  - concrete-over-generic (priority 70, fired 47 times)
```

SwiftUI debug panel in `MemoryDebugInspector`: list of all skills with `state`, `firedCount`, `lastFiredAt`. No editing in v2.

### Skill authoring (seed file, INSERT-ONLY)

`Sources/Nous/Resources/seed-skills.json`. Importer runs on app launch:

- For each row: lookup `id` in `skills` table.
- If `id` exists → skip entirely (no overwrite, no merge).
- If `id` does not exist → insert with `firedCount = 0`.

Content changes to a seed skill require a **new `id`** in `seed-skills.json`. Old skill orphaned in DB — Alex retires manually via SQL or future Skill UI.

This is intentional: structural mode skeletons (Direction / Brainstorm) ship from seed and Alex may tweak them locally. INSERT-ONLY preserves Alex's tweaks across app updates. **Plan's structural addendum is NOT a seed skill** (it stays in `PlanAgent.swift`), so the duplicate-firing-on-cap-change problem from the previous draft is avoided.

## Migrator: Direction + Brainstorm only (Plan stays)

Phase 2.2 work: convert ONLY `DirectionAgent.contextAddendum` and `BrainstormAgent.contextAddendum` body content into seed skills. **`PlanAgent.contextAddendum` is unchanged.**

### Mapping

| Source | Target skill | Trigger |
|---|---|---|
| `DirectionAgent.contextAddendum` (turnIndex >= 1) | `direction-skeleton` | `kind=mode, modes=[direction], priority=90` |
| `BrainstormAgent.contextAddendum` (turnIndex >= 1) | `brainstorm-skeleton` | `kind=mode, modes=[brainstorm], priority=90` |

### After migration

- `DirectionAgent.contextAddendum(turnIndex:)` returns `nil` for all turns. The body moves to `seed-skills.json` under id `direction-skeleton`.
- `BrainstormAgent.contextAddendum(turnIndex:)` returns `nil` for all turns. Same pattern.
- `PlanAgent.contextAddendum(turnIndex:)` is **unchanged** — keeps its 5-case switch over `turnIndex` (0 → nil, 1 → decideOrAsk, 2-3 → normalProduction, 4+ → finalUrgent).
- Integration concatenates: `[planAgentAddendum, skillAddendum]` for Plan turns; `[skillAddendum]` for Direction/Brainstorm turns.

### Why Plan is special-cased

`PlanAgent.contextAddendum` is genuinely a state machine: which addendum fires depends on `turnIndex` AND a defensive `maxClarificationTurns` cap. Expressing this as declarative skill rows requires either `turnRange` gating (introduces bugs around cap changes per Codex finding #3) or a special skill kind (introduces v2 complexity). State machines belong in code.

Trade-off: Plan's addendum doesn't get the skill-ecosystem benefits (`firedCount`, taste-layered overlay). v2 accepts this. v2.5 may revisit if the trade-off causes friction.

## Phase 2.2 — 7 seed skills

### From mode addenda (2 skills)

1. `direction-skeleton` — Direction Mode Quality Contract (current addendum body). `kind=mode, modes=[direction], priority=90`.
2. `brainstorm-skeleton` — Brainstorm Mode Quality Contract (current addendum body). `kind=mode, modes=[brainstorm], priority=90`.

### From Alex's explicit taste (5 skills)

All 5 use `modes: [direction, brainstorm, plan]` whitelist (no default-chat impact).

3. `stoic-cantonese-voice` — "Speak as a stoic Cantonese mentor; avoid corporate-AI register." `priority=70`.
4. `concrete-over-generic` — "Refer to specific files, function names, real numbers; avoid generic guidance." `priority=70`.
5. `direct-when-disagreeing` — "If Alex's framing is wrong, say so plainly; do not perform agreement." `priority=65`.
6. `interleave-language` — "Cantonese for warmth + product, English for technical terms; do not translate technical terms unnecessarily." `priority=60`.
7. `weight-against-default-chat-baseline` — "If you ask a question, the answer must materially change your reply; do not ask filler questions." `priority=55`.

### Cut from earlier draft

- `no-advice-list` — already in Direction/Plan addenda. Don't double-code.
- `acknowledge-real-constraints` (F-1, solo founder, etc.) — personal facts, not skill. Goes to `user_facts` in a separate task, NOT in SkillStore.

## Test plan

### Unit tests (focused, post-simplification)

- **`SkillStoreTests`**:
  - CRUD round-trip (insert → fetch → update → setState)
  - `incrementFiredCount` updates atomically
  - Insert with `payloadVersion != 1` throws
  - Insert with empty `modes` throws
  - Insert with `priority` outside 0-100 throws
  - Insert with empty `action.content` throws
  - Insert with corrupt JSON payload → SQLite CHECK rejects
  - Insert with `state='actve'` (typo) → SQLite CHECK rejects

- **`SkillMatcherTests`**:
  - `mode = nil` (default chat) → no skills fire (v2 invariant)
  - `mode` matches whitelist → skill fires
  - `mode` does not match whitelist → skill skipped
  - Inactive (`state != active`) skills excluded
  - Cap=5 enforcement: 7 active matching skills → top 5 by priority
  - **Turn-0 mode-skeleton skip**: with `turnIndex=0` + Direction mode + `direction-skeleton` (kind=mode) + 5 taste skills active → matcher returns ONLY the 5 taste skills (skeleton silenced)
  - **Turn-1+ mode-skeleton fires**: with `turnIndex=1` + Direction mode → matcher returns skeleton + top 4 taste = 5 skills
  - **Turn-0 always-skill fires**: a `kind=always` skill with `modes=[direction]` + `turnIndex=0` → STILL fires (turn-0 skip is mode-only)
  - Equal priority deterministic order: 5 tied skills → name asc tiebreaker is deterministic across runs
  - Equal priority + equal name → id ascending (final tiebreaker)

- **`SkillPayloadCodableTests`**:
  - Round-trip preserves all fields
  - camelCase JSON keys decode without `convertFromSnakeCase`
  - Missing `antiPatternExamples` → defaults to `[]`
  - Missing `description` / `rationale` → succeeds (optional)
  - Missing `payloadVersion` → fails
  - `payloadVersion = 0` → fails
  - `payloadVersion = 2` → fails (v2 accepts only 1)
  - `kind = "regex"` or `kind = "intent"` in JSON → decode fails (only `always | mode`)

- **`SeedSkillImporterTests`**:
  - First launch: imports all 7 seed skills
  - Rerun with same JSON: zero changes (insert-only)
  - Seed file changes content for an existing id: importer SKIPS, Alex's local edits preserved
  - Seed file removes an id: existing row stays (no auto-delete)
  - Concurrent launch: shared transaction lock, no duplicate inserts

- **`SkillIntegrationTests`** (against `TurnPlanner` callers):
  - **Snapshot test (Direction opening turn 0)**: matcher returns top 4-5 taste skills, NO mode skeleton (turn-0 invariant). `quickActionAddendum` is taste-only string; matches pre-migration nil + opening prompt.
  - **Snapshot test (Direction turn 1)**: matcher returns `direction-skeleton` + 4 taste skills (cuts priority-55 `weight-against-default-chat-baseline`). Concatenated `quickActionAddendum` byte-equivalent (modulo skill content) to pre-migration string.
  - **Snapshot test (Brainstorm turn 1)**: same pattern as Direction.
  - **Snapshot test (Plan turn 0)**: PlanAgent.contextAddendum returns nil; matcher returns 5 taste skills (all of them, no mode skeleton consuming a slot).
  - **Snapshot test (Plan turn 1)**: PlanAgent returns `decideOrAskAddendum`; matcher returns 5 taste skills. Concatenation = `[planAgentAddendum, allTasteSkillsJoined]`.
  - **Snapshot test (Plan turn 2, 3, 4, 5)**: Plan addendum unchanged (turnIndex-driven); 5 taste skills fire each turn.
  - Steward-inferred Direction route: matcher uses `planningQuickActionMode` (explicit ?? inferred), mode skeleton STILL fires at turnIndex >= 1.
  - Default companion chat (`mode = nil`): NO skills fire, `quickActionAddendum = nil` (same as today).
  - `DebugAblation.skipModeAddendum = true` → skill matcher skipped, integration falls back to `inferredAddendum` only.

### Manual QA (post-migration)

1. Launch Nous, tap Direction chip. Verify the **opening turn** asks one short question (no skeleton text leaking). Trace shows 4-5 taste skills, NO `direction-skeleton`. Then answer the opening question — verify the **turn-1 reply** has Direction shape (same as pre-migration). Trace shows `direction-skeleton` + 4 taste skills (5th cut is `weight-against-default-chat-baseline`).
2. Same flow for Brainstorm chip: opening turn = taste only, turn 1 = `brainstorm-skeleton` + 4 taste.
3. Tap Plan chip, ask P3. Verify Plan turn-1 partial-plan triad (PlanAgent.contextAddendum unchanged). Trace shows 5 taste skills firing (NO mode skeleton, because Plan does not migrate). Continue answering — verify turn-2 produces structured plan, turn-4+ forces final synthesis (PlanAgent state machine intact).
4. Default companion chat: verify NO skills fire (no addendum injection beyond what already exists). No regression.

If any regress, the migration broke something. Fix before continuing.

## Risks (Path Y minimal scope)

1. **Migration may regress Direction/Brainstorm prompt-level behavior.** Mitigation: snapshot tests. If reply text differs by more than whitespace, fix.
2. **Plan stays code-driven; doesn't get skill-ecosystem benefits.** Mitigation: accept trade-off in v2; revisit in v2.5 if it causes friction.
3. **Schema evolution requires a migrator from v2.5 onward.** Mitigation: `payloadVersion = 1` is locked; v2.5 introduces explicit migration path.
4. **No `regex` or `intent` triggers limits future skills to mode-or-always.** Mitigation: v2.5 adds these as separate work; v2 doesn't need them to prove the mechanism.

## Open questions (resolved during implementation, non-blocking)

1. `SkillStore` lives in `AppEnvironment` next to `nodeStore`.
2. `SkillTracker.recordFire` is fire-and-forget via `Task.detached`.
3. `seed-skills.json` is bundled in `Resources/` for v2; promoted to app-data when v2.5 Skill UI ships.
4. Migration safety: if skill table is empty after first launch attempt, fail loud in DEBUG; in release log + use empty list (no fallback to legacy `agent.contextAddendum` because Direction/Brainstorm now return nil).

## Next concrete steps (Phase 2.1 implementation)

1. Schema migration: add `skills` table to `NodeStore.createTables()` with `CHECK` constraints.
2. `SkillPayload` Swift types + `SkillStoreError` + insert-validation tests (TDD).
3. `SkillStore` CRUD with shared transaction lock (extend `Database` if needed).
4. `SkillMatcher` pure logic with full test coverage.
5. `SeedSkillImporter` — INSERT-ONLY logic.
6. Integration at `TurnPlanner.swift:230` + `ChatViewModel.swift:340` per spec above.
7. `DirectionAgent` + `BrainstormAgent`: change `contextAddendum` to return `nil` for all turns. Move body content to `seed-skills.json` rows.
8. `PlanAgent`: unchanged.
9. `MemoryDebugInspector` add Skills tab.
10. Manual QA above.

Estimated time: 1-1.5 weeks (vs original 2 weeks — Plan unmigrated saves time).

## Source files

- `docs/superpowers/specs/2026-04-28-nous-v2-skill-fold-strategy.md` — Path B parent spec
- `Sources/Nous/Models/Agents/DirectionAgent.swift` — migration source
- `Sources/Nous/Models/Agents/BrainstormAgent.swift` — migration source
- `Sources/Nous/Models/Agents/PlanAgent.swift` — UNCHANGED in v2
- `Sources/Nous/Services/NodeStore.swift` — pattern reference + transaction lock
- `Sources/Nous/Services/Database.swift` — SQLite wrapper
- `Sources/Nous/Services/TurnPlanner.swift` (line 230) — per-turn integration site
- `Sources/Nous/ViewModels/ChatViewModel.swift` (line 340) — opening-turn integration site
- `Sources/Nous/Views/MemoryDebugInspector.swift` — dev trace inspector host

## Decisions log

- **2026-04-28 morning** — Phase 2.1 entry doc drafted (full scope: regex/intent/specificity/turnRange/Plan-migration).
- **2026-04-28 afternoon (round 1 amendment)** — Codex challenge surfaced 3 top-killers + 12 detail findings; doc amended to fix.
- **2026-04-28 afternoon (round 2 amendment)** — Codex follow-up review found amended doc still had 5 remaining + 4 new issues. Recurring lesson: every new feature is new bug surface.
- **2026-04-28 afternoon (Path Y simplification)** — Doc rewritten to minimal scope. Drop `regex`, `intent`, `specificity`, `turnRange`, `payloadVersion>1`, default-chat impact, and Plan migration. v2 has 2 trigger kinds (`mode`, `always`), 1 cap (priority + name tiebreaker), 7 seed skills (2 mode + 5 mode-whitelisted taste), Plan stays code-driven. Codex round-2 verdict was "one-more-iteration"; Path Y trades feature surface for stability.
- **2026-04-28 evening (Path Y polish)** — Codex round-3 review on Path Y simplification verdict was "one-more-iteration" with 2 critical gaps: (1) opening-turn regression — matcher ignored `turnIndex`, would leak mode skeleton into turn 0 contradicting opening prompt; fix: matcher unconditionally skips `kind=mode` when `turnIndex == 0`. (2) Plan taste count inconsistent in doc (tests said 3, manual QA said 5) due to cap=4; fix: raise cap to 5 + document exact firing pattern per turn type. With these two fixes, schema is implementation-ready per Codex.
