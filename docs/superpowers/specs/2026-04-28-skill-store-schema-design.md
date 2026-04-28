# SkillStore — Schema + Service Design (Phase 2.1)

**Date:** 2026-04-28
**Status:** Phase 2.1 entry doc per `2026-04-28-nous-v2-skill-fold-strategy.md` (Path B). Implementation entry, not strategic spec.
**Branch context:** Builds on `alexko0421/quick-action-agents` after Phase 1 (tool use + reasoning loop) ships.
**Author:** Alex Ko, with assistance.

## Context

Path B spec commits Nous to building a Skill Fold layer where `Skill` is first-class addressable data, not hardcoded prompt text. v2 minimal scope:

- Manual authoring only (no LLM Discover, no auto-promote)
- ~10 seed skills migrated from existing mode addenda + Alex's explicit taste
- Dev-grade trace inspector (no first-class UI in v2)
- 3 future-readiness hooks baked in (per Path B "Hooks 1-3")

This doc specifies the schema + service interfaces to enable Phase 2.2 (skill authoring) and Phase 2.3 (30-day dogfood).

## Schema

### `skills` table

```sql
CREATE TABLE IF NOT EXISTS skills (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL DEFAULT 'alex',  -- Hook 1: tenant_id, always 'alex' in v2
    payload TEXT NOT NULL,                  -- Hook 2: portable JSON (see payload schema below)
    state TEXT NOT NULL DEFAULT 'active',   -- 'active' | 'retired' | 'disabled'
    fired_count INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,            -- Unix epoch milliseconds
    last_modified_at INTEGER NOT NULL,
    last_fired_at INTEGER                   -- nullable; null = never fired yet
);

CREATE INDEX IF NOT EXISTS idx_skills_active ON skills(user_id, state);
CREATE INDEX IF NOT EXISTS idx_skills_fired ON skills(last_fired_at);
```

Notes:

- `id` is UUID string, not Swift `UUID` type. Cross-language portability.
- `state = 'disabled'` allows Alex to temporarily turn off a skill without deleting it.
- Only operational fields are columns. Behavioral fields live in `payload` JSON for schema flexibility.

### `payload` JSON schema

```jsonc
{
  // Identity
  "name": "stoic-language",                          // human-readable id
  "description": "Use stoic Cantonese mentor voice instead of corporate AI tone",
  "source": "alex" | "imported-from-anchor",          // v2 only these two

  // Trigger
  "trigger": {
    "kind": "always" | "regex" | "intent" | "mode",
    "pattern": "...",                                  // depends on kind
    "modes": ["direction", "brainstorm", "plan"],      // optional whitelist; nil = all modes
    "priority": 50                                     // 0-100; higher = applied first
  },

  // Action
  "action": {
    "kind": "prompt-fragment",                          // v2 only this kind
    "content": "Speak as a stoic Cantonese mentor..."
  },

  // Notes (Alex's, not enforced)
  "rationale": "Why this skill exists",
  "anti_pattern_examples": ["Example bad output 1", ...]
}
```

Trigger kinds:

- **`always`**: fires on every turn (subject to mode whitelist + cap)
- **`regex`**: fires when `pattern` matches the current user message (case-insensitive)
- **`intent`**: reserved for v2.5; v2 implementation returns false, no firing
- **`mode`**: fires only when `activeQuickActionMode` matches one of `modes`

Action kinds:

- **`prompt-fragment`**: appended to `assembleContext` volatile section (similar position to current `quickActionAddendum`)

Future kinds (v2.5+): `tool-sequence`, `composite`. v2 only `prompt-fragment`.

## Service interfaces

### `SkillStore`

CRUD service backed by `Database` (existing SQLite wrapper). Mirrors `NodeStore` patterns.

```swift
protocol SkillStoring {
    func fetchActiveSkills(userId: String) throws -> [Skill]
    func fetchSkill(id: UUID) throws -> Skill?
    func insertSkill(_ skill: Skill) throws
    func updateSkill(_ skill: Skill) throws
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

enum SkillState: String, Codable {
    case active, retired, disabled
}

struct SkillPayload: Codable, Equatable {
    let name: String
    let description: String?
    let source: SkillSource
    let trigger: SkillTrigger
    let action: SkillAction
    let rationale: String?
    let antiPatternExamples: [String]
}

enum SkillSource: String, Codable {
    case alex, importedFromAnchor = "imported-from-anchor"
}

struct SkillTrigger: Codable, Equatable {
    enum Kind: String, Codable { case always, regex, intent, mode }
    let kind: Kind
    let pattern: String?
    let modes: [QuickActionMode]?
    let priority: Int
}

struct SkillAction: Codable, Equatable {
    enum Kind: String, Codable { case promptFragment = "prompt-fragment" }
    let kind: Kind
    let content: String
}
```

Implementation note: `SkillPayload` encodes/decodes via JSONEncoder/Decoder; the Swift type is the source of truth, the SQLite TEXT column is the durable form. New fields can be added to `SkillPayload` without `ALTER TABLE`.

### `SkillMatcher`

Pure logic, no IO. Given turn context, returns the skills that should fire this turn.

```swift
struct SkillMatchContext {
    let userMessage: String
    let activeQuickActionMode: QuickActionMode?
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
        cap: Int = 3
    ) -> [Skill] {
        skills
            .filter { $0.state == .active }
            .filter { skillTriggersFor($0, context: context) }
            .sorted { lhs, rhs in
                lhs.payload.trigger.priority > rhs.payload.trigger.priority
            }
            .prefix(cap)
            .map { $0 }
    }
    
    private func skillTriggersFor(_ skill: Skill, context: SkillMatchContext) -> Bool {
        // ... per trigger kind logic
    }
}
```

Cap default = 3 (per Path B design principle 4: more than 3 active skills creates unmanageable conflict surface).

### `SkillTracker`

Observes turn outcomes, updates `firedCount` + `lastFiredAt`. v2 tracks fire-only; success/fail signal deferred to v2.5.

```swift
protocol SkillTracking {
    func recordFire(skillIds: [UUID]) async throws
}
```

Called from `TurnExecutor` (or `AgentLoopExecutor`) after the turn assembles its prompt. v2 does NOT track success/fail; that requires user signal infrastructure deferred per Codex critique #5.

### Dev trace inspector (NOT a polished UI)

In v2, "Skill UI" = a debug-mode console output + a SwiftUI debug panel.

Console output (Xcode log) on every turn:

```
[SkillTrace] Turn 17 (mode: direction)
  Active skills (3 of 8 fired):
  - stoic-language (priority 80, fired 47 times) — always
  - direction-skeleton (priority 70, fired 12 times) — mode:direction
  - cantonese-preference (priority 60, fired 47 times) — always
  Skipped due to cap: ['no-advice-list' (priority 55)]
  Skipped due to trigger: ['plan-turn1-contract']
```

SwiftUI debug panel (gated under `#if DEBUG`): a list view in the existing `MemoryDebugInspector` showing all skills with their state, fired count, last-fired time. No editing UI in v2 — Alex edits SQLite directly via `.sql` migration files or a CLI tool (next section).

### Skill authoring CLI (or seed file)

v2 does NOT include a Skill UI. Authoring path:

**Option A (recommended)**: A seed file `Sources/Nous/Resources/seed-skills.json` that gets imported on app launch (idempotent — only inserts if `id` doesn't exist). Alex edits the JSON directly.

```jsonc
[
  {
    "id": "00000000-0000-0000-0000-000000000001",
    "user_id": "alex",
    "payload": { ... },
    "state": "active"
  },
  ...
]
```

**Option B**: A SwiftUI form for adding/editing skills. v2.5 scope, not v2.

Decision: **Option A in v2**. JSON file edit is the authoring loop. Reload on app launch.

## Migrator: hardcoded addendum → seed skills

Phase 2.2 work: convert the current hardcoded `*Agent.swift` `contextAddendum` strings into seed skills.

### Mapping

| Source | Target skill |
|---|---|
| `DirectionAgent.contextAddendum` (turnIndex >= 1) | `direction-skeleton` (trigger: `mode:direction`, priority: 70) |
| `BrainstormAgent.contextAddendum` (turnIndex >= 1) | `brainstorm-skeleton` (trigger: `mode:brainstorm`, priority: 70) |
| `PlanAgent.decideOrAskAddendum` (turnIndex == 1) | `plan-turn1-contract` (trigger: `mode:plan`, priority: 80) |
| `PlanAgent.normalProductionAddendum` (turnIndex >= 2) | `plan-production` (trigger: `mode:plan`, priority: 70) |
| `PlanAgent.finalUrgentAddendum` (turnIndex >= 4) | `plan-final-turn` (trigger: `mode:plan`, priority: 90 — overrides others) |

### After migration

`DirectionAgent / BrainstormAgent / PlanAgent` lose their `contextAddendum` body content. They become thin policy wrappers: still own `openingPrompt()`, `memoryPolicy()`, `turnDirective()`, `toolNames`, `useAgentLoop`. The mode-specific addendum text moves to seed-skills.json.

`assembleContext` is modified to:

1. Fetch active skills via `SkillStore.fetchActiveSkills(userId:)`
2. Match via `SkillMatcher.matchingSkills(...)` with cap = 3
3. Concatenate matched skill action contents in priority order
4. Use as the `quickActionAddendum` argument (replacing the existing `agent.contextAddendum(turnIndex:)` call)

Backwards compat: `QuickActionAgent.contextAddendum(turnIndex:)` returns nil for all modes after migration. Optionally remove the protocol method in v2.5; keep for now to minimize change surface.

## Phase 2.2 — 10 seed skills (target list)

Per Path B spec Phase 2.2 (1 week):

### From mode addenda (5 skills)

1. `direction-skeleton` — Direction Mode Quality Contract (current addendum)
2. `brainstorm-skeleton` — Brainstorm Mode Quality Contract (current addendum)
3. `plan-turn1-contract` — Plan turn-1 partial-plan triad (current `decideOrAskAddendum`)
4. `plan-production` — Plan turn-2+ structured plan (current `normalProductionAddendum`)
5. `plan-final-turn` — Plan max-cap forced synthesis (current `finalUrgentAddendum`)

### From Alex's explicit taste (5 skills)

These extract Alex-specific taste currently encoded in `anchor.md` or implicit. Per Hook 3, anchor.md stays frozen — these skills become an OVERLAY layer on top of anchor.

6. `stoic-cantonese-voice` — "Speak as a stoic Cantonese mentor; avoid corporate-AI register"
7. `no-advice-list` — "Do not produce 'you can consider A / B / C ...' advice lists"
8. `concrete-over-generic` — "Refer to specific files, function names, and real numbers; avoid generic guidance"
9. `acknowledge-real-constraints` — "Always factor in: solo founder, F-1 visa, limited capital, limited energy, no team"
10. `direct-when-disagreeing` — "If Alex's framing is wrong, say so plainly; do not perform agreement"

These are explicit extracts of patterns Alex has been correcting/teaching me throughout sessions — codifying them as skills makes them addressable + observable.

## Test plan

### Unit tests

- **`SkillStoreTests`** (CRUD round-trip):
  - Insert skill → fetch returns it
  - Update skill → updated content + last_modified_at incremented
  - setSkillState(retired) → no longer in fetchActiveSkills
  - incrementFiredCount → fired_count + last_fired_at updated atomically

- **`SkillMatcherTests`** (pure logic, in-memory skills):
  - `always` trigger: fires regardless of message/mode
  - `regex` trigger: fires only when message matches
  - `mode` trigger: fires only when activeQuickActionMode is in `modes` whitelist
  - `intent` trigger: returns false (reserved)
  - Priority ordering: higher priority wins
  - Cap enforcement: cap=3 returns only top 3 by priority
  - Inactive skills (state != active) excluded
  - Empty skills array → returns empty

- **`SkillPayloadCodableTests`**:
  - Round-trip JSON encode/decode preserves all fields
  - Unknown future fields in JSON are ignored gracefully
  - Missing required fields → decode fails with descriptive error

- **`SeedSkillImporterTests`**:
  - First launch: imports all 10 seed skills
  - Subsequent launch with same seed-skills.json: idempotent (no duplicates)
  - Modified seed-skills.json: updates content but preserves fired_count/state

- **`SkillIntegrationTests`** (against `assembleContext`):
  - With Direction mode active and `direction-skeleton` skill: prompt contains the skeleton content
  - With cap=3 and 5 always-firing skills: only top 3 by priority are included

### Manual QA

After migration:

1. Launch Nous, tap Direction chip, ask P1 question. Verify reply has Direction shape (same as pre-migration). Console shows `[SkillTrace]` listing `direction-skeleton` + Alex-taste skills firing.
2. Tap Brainstorm chip, ask P2 question. Verify Brainstorm shape (same). Console shows `brainstorm-skeleton` firing.
3. Tap Plan chip, ask P3 question. Verify Plan turn-1 partial-plan triad. Console shows `plan-turn1-contract` firing.
4. Default chat (no chip): verify only Alex-taste skills fire (no mode-skeleton skills). Console shows reduced active set.

If any of these regress vs current behavior, the migration broke something. Fix before continuing.

## Risks

1. **Migration may regress prompt-level behavior.** Even with same string content, the new path (skill matching → assemble) may inject text differently than current direct-from-agent path. Mitigation: snapshot test that `assembleContext` produces byte-identical output for same input pre/post migration (or document acceptable diff).

2. **Skill matching latency.** Loading 10 skills from SQLite + matching is < 5 ms. But if skill count grows (50+) and matching includes regex evaluation, latency may matter. v2 stays under 20 skills; v2.5 may need indexing.

3. **JSON payload schema evolution.** Adding new fields to `SkillPayload` works, but RENAMING fields requires migration of stored payload. Mitigation: be conservative naming; treat current schema as 1.0.

4. **Cap = 3 may be wrong.** Codex suggested 3 as upper bound to prevent conflict. But for power user with 50 skills, 3 may be too few (e.g., Alex has 5 voice-related skills he wants always-on). Mitigation: cap is a config, can raise to 5 in v2.5 if dogfood reveals friction.

5. **`always` trigger + mode-gated skills can interact.** A `direction-skeleton` skill (mode-gated) + `stoic-cantonese-voice` skill (always) both fire on Direction turns. Order matters (priority). Document expected ordering.

## Open questions

These resolve during Phase 2.1 implementation, not blocking design:

1. **Where does `SkillStore` live in the app graph?** Probably `AppEnvironment` alongside `nodeStore`, `userMemoryService`. Confirm during implementation.

2. **Does `SkillTracker.recordFire(...)` await persistence or fire-and-forget?** v2 should fire-and-forget (background task) to not block turn latency. Errors logged, not surfaced.

3. **Should seed-skills.json be in `Resources/` (bundled) or in app-data dir (user-editable)?** 
   - Bundled: easier to ship, but Alex needs to rebuild app to edit
   - App-data: editable without rebuild, but lost on uninstall
   - Recommendation: bundled in v2; promote to app-data in v2.5 when Skill UI is built.

4. **Does the seed importer overwrite Alex's edits to a skill if seed-skills.json content changes?**
   - If yes: every app launch resets Alex's tweaks → bad
   - If no: how does Alex update a skill that came from seed?
   - Recommendation: importer is INSERT-ONLY. Once a skill exists, seed-skills.json doesn't touch it. Alex's edits via SQL or future Skill UI persist. (v2.5 may add merge logic.)

5. **Migration safety net:** if skill table is empty (first launch), fall back to current hardcoded addenda? Or fail loud?
   - Recommendation: fail loud during dev (DEBUG assertion); silently fall back in release. Should never happen if seed import works.

## Next concrete steps (Phase 2.1 implementation)

1. **Schema migration**: add `createTables` clause for `skills` table in `NodeStore.createTables()` (or new `SkillStore` if separating). Use `ensureColumnExists` pattern for backward-compat.
2. **`SkillPayload` Swift types**: define + encode/decode tests first (TDD).
3. **`SkillStore`**: CRUD against SQLite, mirror NodeStore patterns.
4. **`SkillMatcher`**: pure logic, full unit-test coverage.
5. **`SeedSkillImporter`**: idempotent import on app launch.
6. **`assembleContext` integration**: replace `agent.contextAddendum(turnIndex:)` call with `SkillMatcher` output.
7. **`MemoryDebugInspector` extension**: add Skills tab showing live skill state + fired counts.
8. **Manual QA**: 4 scenarios above.
9. **Spec amendment**: append actual implementation notes back to Path B strategy spec under "Phase 2.1 outcome".

Estimated time: 2 weeks (per Path B roadmap).

## Source files

- `docs/superpowers/specs/2026-04-28-nous-v2-skill-fold-strategy.md` — Path B strategy (parent spec)
- `Sources/Nous/Models/Agents/*Agent.swift` — current contract addenda (migration source)
- `Sources/Nous/Services/NodeStore.swift` — pattern reference for SQLite service
- `Sources/Nous/Services/Database.swift` — SQLite wrapper
- `Sources/Nous/ViewModels/ChatViewModel.swift` — `assembleContext` integration point
- `Sources/Nous/Views/MemoryDebugInspector.swift` — dev trace inspector host

## Decisions log

- **2026-04-28** — Phase 2.1 entry doc drafted. Schema + service interfaces locked. Open questions deferred to implementation phase.
