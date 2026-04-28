# Plan: SkillStore Phase 2.1 Implementation

**Date:** 2026-04-28
**Status:** Ready to implement. Schema design + 3 rounds of Codex challenge complete.
**Branch:** `alexko0421/quick-action-agents` (continue on this branch; do not branch off main).
**Spec source:** `docs/superpowers/specs/2026-04-28-skill-store-schema-design.md` (v3, commit `88491dd`).
**Strategy source:** `docs/superpowers/specs/2026-04-28-nous-v2-skill-fold-strategy.md` (Path B, private instrument).
**Estimated time:** 1-1.5 weeks of focused work.

---

## Pre-flight checklist (run these first)

```sh
cd /Users/kochunlong/conductor/workspaces/Nous/new-york

# 1. Verify branch
git rev-parse --abbrev-ref HEAD          # → alexko0421/quick-action-agents

# 2. Verify clean tree
git status                               # → working tree clean

# 3. Verify on or after the schema-doc-ready commit
git log --oneline | grep "88491dd\|schema doc - polish Path Y"

# 4. Verify tests pass
xcodebuild test -project Nous.xcodeproj -scheme Nous -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .context/DerivedData-precheck 2>&1 | \
  grep -E "Test Suite 'All tests'|TEST SUCCEEDED|TEST FAILED|^Executed" | tail -4
# → 550 tests, 0 failures, TEST SUCCEEDED
```

If any of these fail, **STOP**. Investigate before starting implementation.

## Mental model — read these first

The new session must understand these design constraints before writing any code. They are NOT up for re-litigation — they came out of 3 rounds of Codex challenge:

1. **Path B**: Nous is Alex's private thinking instrument first. Future public is optional, not load-bearing.  See `docs/superpowers/specs/2026-04-28-nous-v2-skill-fold-strategy.md`.

2. **Plan does NOT migrate.** `PlanAgent.contextAddendum` stays as today (a turn-state-machine over `turnIndex`). Only Direction + Brainstorm migrate. This is deliberate — Codex caught the duplicate-firing bug from the previous design where Plan addendum was data-driven.

3. **v2 trigger kinds: `mode` and `always` only.** No `regex`, no `intent`. Both kinds REQUIRE non-empty `modes` whitelist. Default companion chat (no chip) fires NO skills.

4. **Cap = 5 with turn-0 mode-skeleton skip.** Mode skeletons do not fire on `turnIndex == 0` (preserves existing opening-turn behavior where addendum is nil). Always-kind skills DO fire on turn 0.

5. **Mode matching uses `planningQuickActionMode = explicit ?? inferred`** at integration sites. This matches how `planningAgent` is currently selected (TurnPlanner.swift:62). Steward-inferred routes preserve their mode skeleton.

6. **INSERT-ONLY seed import.** Seed file changes content → ship new UUID, old row stays in DB (Alex retires manually). Never overwrite Alex's local edits.

7. **3 future-readiness hooks** (zero cost now, save weeks later if Nous goes public):
   - `user_id` column on `skills` table (always `'alex'` in v2)
   - JSON payload (camelCase, exactly `payloadVersion: 1` in v2)
   - Anchor.md stays frozen — concept-only separation between identity and personal

8. **Phase 1 (tool use + loop) is shipped + tested** at commit `a1029b5`. Do NOT touch that work. SkillStore layers on top.

## Sequential tasks

Each task is a self-contained unit. Commit after each major task, push periodically.

### Task 1: Schema migration

**Files**: `Sources/Nous/Services/NodeStore.swift`

Add to `NodeStore.createTables()`:

```swift
try database.execute("""
    CREATE TABLE IF NOT EXISTS skills (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL DEFAULT 'alex',
        payload TEXT NOT NULL CHECK (json_valid(payload)),
        state TEXT NOT NULL DEFAULT 'active'
            CHECK (state IN ('active', 'retired', 'disabled')),
        fired_count INTEGER NOT NULL DEFAULT 0,
        created_at REAL NOT NULL,
        last_modified_at REAL NOT NULL,
        last_fired_at REAL
    );
""")
try database.execute("""
    CREATE INDEX IF NOT EXISTS idx_skills_active ON skills(user_id, state);
""")
```

**Tests**: extend `NodeStoreTests` with:
- Migration is idempotent (run twice, no error)
- `INSERT INTO skills (...) VALUES (..., 'actve', ...)` rejected by CHECK
- `INSERT INTO skills (...) VALUES (..., '{not json}', ...)` rejected by CHECK
- Date columns are REAL (not INTEGER)

**Done when**: build green, 550 tests + new ones pass.

### Task 2: Swift type definitions (TDD)

**New file**: `Sources/Nous/Models/Skill.swift`

Define from spec section "SkillStore" (around line 87-168):
- `Skill` struct
- `SkillState` enum
- `SkillSource` enum (`alex` | `importedFromAnchor`)
- `SkillPayload` struct with **custom `init(from:)`** that:
  - Requires `payloadVersion == 1` (decode fails on 0 or 2+)
  - Defaults `antiPatternExamples` to `[]` if missing
  - Other optionals (`description`, `rationale`) use `decodeIfPresent`
- `SkillTrigger` struct (kind `.always | .mode` only — NOT `.intent` or `.regex`)
- `SkillAction` struct (kind `.promptFragment` only)
- `QuickActionMode` is reused from existing code (already imports correctly)

**New file**: `Sources/Nous/Models/SkillStoreError.swift`

```swift
enum SkillStoreError: LocalizedError {
    case invalidPayloadVersion(Int)
    case emptyModes
    case priorityOutOfRange(Int)
    case emptyActionContent
    // ... add as needed

    var errorDescription: String? { ... }
}
```

**Tests** (new file `Tests/NousTests/SkillPayloadCodableTests.swift`):
- Round-trip JSON encode/decode preserves all fields
- camelCase keys decode without `convertFromSnakeCase`
- Missing `antiPatternExamples` → defaults to `[]`
- Missing `description` / `rationale` → succeeds (optional)
- Missing `payloadVersion` → fails
- `payloadVersion = 0` → fails
- `payloadVersion = 2` → fails (v2 accepts only 1)
- `kind = "regex"` or `kind = "intent"` in JSON → decode fails

**Done when**: tests pass.

### Task 3: SkillStore service

**New file**: `Sources/Nous/Services/SkillStore.swift`

Mirror `NodeStore` patterns. Key methods (from spec line 87-110):
```swift
protocol SkillStoring {
    func fetchActiveSkills(userId: String) throws -> [Skill]
    func fetchSkill(id: UUID) throws -> Skill?
    func insertSkill(_ skill: Skill) throws
    func updateSkill(_ skill: Skill) throws
    func setSkillState(id: UUID, state: SkillState) throws
    func incrementFiredCount(id: UUID, firedAt: Date) throws
}
```

`insertSkill` and `updateSkill` MUST validate:
- `payload.payloadVersion == 1`
- `payload.trigger.modes` is non-empty
- `payload.trigger.priority` in `0...100`
- `payload.action.content` non-empty after trim

**Critical**: SkillStore must **share NodeStore's transaction lock**, not own its own. Look at `NodeStore.swift:72` — there's a private mutex. Either:
- Refactor: extract the lock into `Database` itself, both NodeStore and SkillStore acquire it.
- Or: Pass NodeStore's lock to SkillStore via init.

Either way, **never have two competing locks against the same SQLite database**.

**Tests** (new file `Tests/NousTests/SkillStoreTests.swift`):
- CRUD round-trip
- `incrementFiredCount` updates atomically
- Insert with bad payload throws (each validation case)
- SQLite CHECK constraints reject corrupt JSON / typo state
- Concurrent insert attempts: shared lock prevents duplicate id

**Done when**: tests pass, no race conditions.

### Task 4: SkillMatcher

**New file**: `Sources/Nous/Services/SkillMatcher.swift`

Pure logic, no IO. Implementation per spec (around line 170-220):

```swift
struct SkillMatchContext {
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
            .filter { skill in
                if context.turnIndex == 0 && skill.payload.trigger.kind == .mode {
                    return false   // turn-0 mode-skeleton skip
                }
                return true
            }
            .sorted(by: Self.skillOrdering)
            .prefix(cap)
            .map { $0 }
    }
    
    private static func skillOrdering(_ lhs: Skill, _ rhs: Skill) -> Bool {
        let lp = lhs.payload.trigger.priority
        let rp = rhs.payload.trigger.priority
        if lp != rp { return lp > rp }
        if lhs.payload.name != rhs.payload.name { return lhs.payload.name < rhs.payload.name }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
```

**Tests** (`Tests/NousTests/SkillMatcherTests.swift`):
- `mode = nil` → empty
- mode matches → fires
- mode doesn't match → skipped
- Inactive skill excluded
- Cap=5 enforced (7 active → top 5)
- Turn-0 mode-skeleton skip: 1 mode skill + 5 always skills @ turnIndex=0 → 5 always returned, mode skipped
- Turn-1 mode-skeleton fires: 1 mode + 5 always @ turnIndex=1, cap=5 → mode + top 4 always
- Equal priority deterministic order via name then id

**Done when**: tests pass.

### Task 5: SkillTracker

**New file**: `Sources/Nous/Services/SkillTracker.swift`

```swift
protocol SkillTracking {
    func recordFire(skillIds: [UUID]) async throws
}
```

Fire-and-forget. `recordFire` calls `SkillStore.incrementFiredCount(...)` for each id. Errors logged, not surfaced.

**Tests**: covered by SkillStore tests + integration tests.

**Done when**: 1-line wrapper exists, integration calls work.

### Task 6: SeedSkillImporter

**New file**: `Sources/Nous/Services/SeedSkillImporter.swift`

```swift
final class SeedSkillImporter {
    private let store: SkillStoring
    private let bundle: Bundle

    init(store: SkillStoring, bundle: Bundle = .main) { ... }

    /// INSERT-ONLY. For each row in seed-skills.json:
    ///   - if id exists in store → skip
    ///   - else → insert with firedCount=0
    func importSeeds() throws { ... }
}
```

Read `seed-skills.json` from `Bundle.main.url(forResource:withExtension:)`. Parse as `[SeedSkillRow]` where:
```swift
struct SeedSkillRow: Codable {
    let id: UUID
    let userId: String
    let payload: SkillPayload
    let state: SkillState
}
```

**Tests** (`Tests/NousTests/SeedSkillImporterTests.swift`):
- First import: all 7 seed rows inserted
- Second import: zero changes (all ids exist)
- Modified seed file with different content for existing id: SKIPPED (insert-only)
- Modified seed file with new id: that one row inserted
- Concurrent invocations: no duplicate inserts

**Done when**: tests pass.

### Task 7: seed-skills.json content

**New file**: `Sources/Nous/Resources/seed-skills.json`

7 skills per spec section "Phase 2.2 — 7 seed skills":

```jsonc
[
  // 1. direction-skeleton
  {
    "id": "00000000-0000-0000-0000-000000000001",
    "userId": "alex",
    "payload": {
      "payloadVersion": 1,
      "name": "direction-skeleton",
      "description": "Direction Mode Quality Contract",
      "source": "importedFromAnchor",
      "trigger": {
        "kind": "mode",
        "modes": ["direction"],
        "priority": 90
      },
      "action": {
        "kind": "promptFragment",
        "content": "<COPY VERBATIM FROM DirectionAgent.contextAddendum>"
      },
      "rationale": "Migrated from DirectionAgent.contextAddendum on 2026-04-28"
    },
    "state": "active"
  },
  // 2. brainstorm-skeleton (same pattern, modes: ['brainstorm'])
  // 3-7. taste skills with modes: ['direction', 'brainstorm', 'plan']:
  //    stoic-cantonese-voice (priority 70)
  //    concrete-over-generic (priority 70)
  //    direct-when-disagreeing (priority 65)
  //    interleave-language (priority 60)
  //    weight-against-default-chat-baseline (priority 55)
]
```

**Critical**: For skills 1-2, copy the addendum body content **verbatim** from `DirectionAgent.contextAddendum` and `BrainstormAgent.contextAddendum`. Use snapshot tests in Task 11 to verify byte-equivalence.

**Done when**: file exists, JSON validates, all 7 entries decode via `SkillPayload`.

### Task 8: AppEnvironment wiring

**Modify**: `Sources/Nous/AppEnvironment.swift`

Add:
- `let skillStore: SkillStore`
- `let skillMatcher: SkillMatcher`
- `let skillTracker: SkillTracker`
- `let seedSkillImporter: SeedSkillImporter`

Inject through the same path as `nodeStore`. On app launch, run `try seedSkillImporter.importSeeds()` after schema migration. Errors during import logged but not fatal.

**Done when**: app builds, launches without crash, on first launch the 7 skills appear in `skills` table.

### Task 9: Integration at TurnPlanner.swift:230

**Modify**: `Sources/Nous/Services/TurnPlanner.swift`

Replace the line:
```swift
let quickActionAddendum: String? = planningAgent?.contextAddendum(turnIndex: agentTurnIndex)
```

With (per schema doc lines 234-275):
```swift
let inferredAddendum = planningAgent?.contextAddendum(turnIndex: agentTurnIndex)
let skillAddendum: String? = {
    #if DEBUG
    if DebugAblation.skipModeAddendum { return nil }
    #endif
    let active = (try? skillStore.fetchActiveSkills(userId: "alex")) ?? []
    let matched = skillMatcher.matchingSkills(
        from: active,
        context: SkillMatchContext(
            mode: planningQuickActionMode,
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

If `String.nilIfEmpty` doesn't exist, add it as a small extension:
```swift
extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
```

**Critical**: `planningQuickActionMode` is already in scope at this point (look at `planningAgent` selection upstream). Use that, NOT just `request.snapshot.activeQuickActionMode`. This preserves Steward-inferred routes.

`skillStore`, `skillMatcher`, `skillTracker` come from `AppEnvironment` injection.

**Done when**: file compiles, turn-1 Direction/Brainstorm/Plan integration tests pass.

### Task 10: Integration at ChatViewModel.swift:340

**Modify**: `Sources/Nous/ViewModels/ChatViewModel.swift`

Same pattern as Task 9 but `turnIndex: 0`. The `agent` is the explicit chip-tap mode here (not Steward-inferred), so use `agent.mode` (or whatever the existing variable is) directly.

**Critical preservation**: the existing DEBUG-guarded `DebugAblation.skipModeAddendum` block must still work. Move the existing logic into the new path.

**Done when**: opening turn integration tests pass.

### Task 11: Strip Direction + Brainstorm contextAddendum bodies

**Modify**: `Sources/Nous/Models/Agents/DirectionAgent.swift` and `BrainstormAgent.swift`

Change both `contextAddendum(turnIndex:)` to:
```swift
func contextAddendum(turnIndex: Int) -> String? {
    return nil  // Migrated to SkillStore (direction-skeleton / brainstorm-skeleton)
}
```

DO NOT touch `PlanAgent.contextAddendum` — Plan stays as-is.

**Update tests** in `Tests/NousTests/QuickActionAgentsTests.swift`:
- `testContextAddendumOnTurnOneStatesConvergentContract`: now asserts `contextAddendum(turnIndex: 1) == nil`
- `testContextAddendumOnTurnOneStatesDivergentContract`: same for Brainstorm
- All `testContextAddendumIncludesXxx` tests for Direction + Brainstorm: REMOVE — those properties now live in seed-skills.json
- Plan tests: UNCHANGED

**Done when**: 550 tests still pass (modulo the removed Direction/Brainstorm content tests).

### Task 12: SkillIntegrationTests

**New file**: `Tests/NousTests/SkillIntegrationTests.swift`

Snapshot tests per spec lines 380-397. Use the `assembleContext` boundary as the snapshot point.

Critical scenarios:
- Direction turn 0: `quickActionAddendum` = taste-only joined string
- Direction turn 1: skeleton + taste joined
- Brainstorm same pattern
- Plan turn 0: PlanAgent returns nil + 5 taste skills
- Plan turn 1: PlanAgent returns `decideOrAskAddendum` + 5 taste joined
- Plan turn 2-3: PlanAgent returns `normalProductionAddendum` + 5 taste
- Plan turn 4: PlanAgent returns `finalUrgentAddendum` + 5 taste
- Steward-inferred Direction: matcher uses `planningQuickActionMode = inferred`, mode-skeleton fires at turn 1
- Default chat (`mode == nil`): no skills fire
- `DebugAblation.skipModeAddendum = true` falls back to `inferredAddendum` only

**Done when**: tests pass.

### Task 13: Console trace logging

**Modify**: integration sites (TurnPlanner + ChatViewModel)

Add `#if DEBUG` `[SkillTrace]` log per turn showing matched skill names, priorities, fire counts. Format from spec lines 280-290.

**Done when**: log lines visible in Xcode console during DEBUG runs.

### Task 14: MemoryDebugInspector Skills tab

**Modify**: `Sources/Nous/Views/MemoryDebugInspector.swift`

Add a "Skills" tab/section showing all skills fetched from `SkillStore`:
- Name, state, fired count, last fired (if non-nil)
- Sortable by fired count or last fired
- No editing in v2 (read-only inspector)

**Done when**: tab visible in DEBUG builds, list refreshes correctly.

### Task 15: Manual QA (4 scenarios)

Run each per spec "Manual QA" section (lines 401-407):

1. Direction chip + opening turn (no skeleton leak), then turn 1 (skeleton + 4 taste fire)
2. Brainstorm chip same pattern
3. Plan chip — PlanAgent state machine still fires turn-by-turn, 5 taste layer on top
4. Default chat: no skills fire

If any regress vs pre-migration: fix before continuing.

**Done when**: all 4 scenarios pass live.

### Task 16: Commit hygiene

Suggested commit groupings:
1. `feat(skills): SQLite schema + Swift types + validation` (Tasks 1-3)
2. `feat(skills): SkillStore + SkillMatcher + SkillTracker services` (Tasks 4-6)
3. `feat(skills): SeedSkillImporter + seed-skills.json + AppEnvironment wiring` (Tasks 7-8)
4. `feat(skills): integrate SkillMatcher at TurnPlanner + ChatViewModel` (Tasks 9-10)
5. `refactor(agents): migrate Direction + Brainstorm addenda to seed skills` (Task 11)
6. `test(skills): integration tests + DebugAblation preservation` (Task 12)
7. `feat(skills): dev trace logging + MemoryDebugInspector Skills tab` (Tasks 13-14)
8. `test(skills): manual QA pass + final test suite green`

Push after each commit; the 41+ commits ahead of origin pattern remains acceptable.

## Definition of done (Phase 2.1 ship)

- ☐ All 550+ existing tests pass (modulo intentional removals)
- ☐ All new tests pass (`SkillStoreTests`, `SkillMatcherTests`, `SkillPayloadCodableTests`, `SeedSkillImporterTests`, `SkillIntegrationTests`)
- ☐ App launches, seed importer runs, 7 skills in `skills` table
- ☐ All 4 manual QA scenarios pass — no regression vs current behavior
- ☐ `[SkillTrace]` console log fires per turn in DEBUG
- ☐ MemoryDebugInspector Skills tab functional
- ☐ Branch is clean, all commits pushed

After Phase 2.1 ship: Phase 2.2 (author 10 seed skills) and Phase 2.3 (30-day dogfood) per Path B roadmap.

## Known gotchas (from 3 rounds of Codex challenge)

These are documented so the next session does not re-discover them:

1. **`assembleContext` is `nonisolated static` and pure.** Do NOT add SkillStore access inside it. Integration is at the CALLERS only (TurnPlanner.swift:230 + ChatViewModel.swift:340).

2. **`planningQuickActionMode` is the right mode for matcher**, not `request.snapshot.activeQuickActionMode`. The former is `explicit ?? inferred`; the latter is just explicit. Steward-inferred routes need the inferred mode to keep firing the skeleton.

3. **Turn-0 mode-skeleton skip is unconditional in v2.** Do not add a per-skill toggle. The skip is in the matcher, not in skill payload.

4. **Plan does NOT migrate.** PlanAgent.contextAddendum stays. Concatenation is `[planAgentAddendum, skillAddendum]`. If you find yourself adding `turnRange` or any state-machine logic to skills, STOP — Plan stays code-driven by design.

5. **Shared transaction lock.** Don't give SkillStore its own mutex. Refactor `Database` or share `NodeStore`'s lock. SQLite FULLMUTEX serializes individual calls but not multi-statement transactions; concurrent transactions across NodeStore + SkillStore against the same DB file = race conditions.

6. **INSERT-ONLY seed import.** Never overwrite. If a seed row's content changes, ship a new UUID. Old row stays in DB; Alex retires manually. This is the only acceptable policy because Alex's local tweaks must survive app updates.

7. **`DebugAblation.skipModeAddendum` must still work.** The new integration path must respect this DEBUG toggle, otherwise the ablation infrastructure breaks.

8. **Don't rebuild what already works.** Phase 1 (tool use + reasoning loop) shipped at commit `a1029b5`. SkillStore layers on top of Phase 1, does not replace any of it.

## Prerequisites for the next session

Before opening implementation, the next Claude session should:

1. **Read this plan in full.**
2. **Read the schema design doc**: `docs/superpowers/specs/2026-04-28-skill-store-schema-design.md`. The Swift types + integration code are specified there in detail.
3. **Read the Path B strategy**: `docs/superpowers/specs/2026-04-28-nous-v2-skill-fold-strategy.md`. Understand WHY Plan stays code-driven and WHY taste skills are mode-whitelisted.
4. **Read the auto-memory entries**:
   - `project_nous_path_b.md`
   - `project_nous_skill_fold_schema_known_issues.md` (now mostly resolved per this plan; treat as historical context)
   - `feedback_sonnet_prescription_density.md`

5. **Skim the relevant existing files** before touching them:
   - `Sources/Nous/Services/NodeStore.swift` (createTables pattern + transaction lock at line 72)
   - `Sources/Nous/Services/Database.swift` (SQLite wrapper)
   - `Sources/Nous/Services/TurnPlanner.swift` lines 200-260 (per-turn integration site)
   - `Sources/Nous/ViewModels/ChatViewModel.swift` lines 330-360 (opening turn site)
   - `Sources/Nous/Models/Agents/DirectionAgent.swift` (current addendum body to migrate)
   - `Sources/Nous/Models/Agents/BrainstormAgent.swift` (same)
   - `Sources/Nous/Models/Agents/PlanAgent.swift` — DO NOT MODIFY in v2
   - `Sources/Nous/AppEnvironment.swift` (service injection pattern)

## After implementation: what to NOT do

- Do NOT invoke another `/codex challenge` round on the same schema before implementation. The schema is already validated through 3 rounds. Re-running burns tokens with diminishing return.
- Do NOT add `regex` / `intent` / `specificity` / `turnRange` / `payloadVersion >= 2`. These are explicit v2 cuts.
- Do NOT migrate `PlanAgent.contextAddendum`. It is correctly state-machine-shaped; data-fying it creates duplicate-firing bugs.
- Do NOT add multi-user features. v2 is single-user; the 3 hooks already preserve future-public optionality.
- Do NOT design a Skill UI. v2 is dev-trace-inspector only. Skill UI is v2.5 scope.
- Do NOT touch `anchor.md`. Frozen per memory `project_anchor_is_frozen`.

## After Phase 2.1 ships

Next steps (NOT this plan's scope):

- **Phase 2.2** (1 week): author 10 seed skills total. Phase 2.1 ships 7; Phase 2.2 adds 3 more (Alex authors during dogfood as patterns emerge).
- **Phase 2.3** (4 weeks of overlap with daily use): dogfood 30 days. Log subjective improvement evidence + fired counts.
- **Week 11 decision point**: continue to v2.5 (Skill UI, A/B variants, auto-promote/retire, regex / intent triggers) OR revert if Skill Fold thesis falsifies.

## Decisions log (this plan)

- **2026-04-28 evening** — Plan drafted. Schema doc + Path B strategy locked. Ready to hand off to next implementation session.

## Source files

- `docs/superpowers/specs/2026-04-28-skill-store-schema-design.md` — schema + service spec
- `docs/superpowers/specs/2026-04-28-nous-v2-skill-fold-strategy.md` — strategic context
- `docs/superpowers/specs/2026-04-27-quick-action-agents-phase1-ab-design.md` — Phase 1 (shipped, do not touch)
- `~/.claude/projects/-Users-kochunlong-Library-Mobile-Documents-com-apple-CloudDocs-Nous-archive/memory/MEMORY.md` — auto-memory index for cross-session context
