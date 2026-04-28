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
    payload TEXT NOT NULL                                                   -- Hook 2: portable JSON
        CHECK (json_valid(payload)),                                        -- corrupt JSON rejected at insert
    state TEXT NOT NULL DEFAULT 'active'
        CHECK (state IN ('active', 'retired', 'disabled')),                 -- typos rejected at insert
    fired_count INTEGER NOT NULL DEFAULT 0,
    created_at REAL NOT NULL,              -- Unix epoch SECONDS (matches NodeStore convention)
    last_modified_at REAL NOT NULL,
    last_fired_at REAL                     -- nullable; null = never fired yet
);

CREATE INDEX IF NOT EXISTS idx_skills_active ON skills(user_id, state);
CREATE INDEX IF NOT EXISTS idx_skills_fired ON skills(last_fired_at);
```

Notes:

- `id` is UUID string, not Swift `UUID` type. Cross-language portability.
- `state = 'disabled'` allows Alex to temporarily turn off a skill without deleting it.
- **Date columns are `REAL` (epoch seconds)** to match `NodeStore` convention (`NodeStore.swift:531`); do NOT use INTEGER milliseconds.
- **`CHECK (json_valid(payload))` is mandatory** so corrupt JSON cannot enter the table; SkillMatcher's decode path can still fail at runtime (e.g., schema evolution mismatch), and that failure must be logged + skipped, never crashed.
- **`CHECK (state IN ...)` is mandatory** so a typo state ('actve') cannot become a ghost row that `fetchActiveSkills` silently drops.
- Only operational fields are columns. Behavioral fields live in `payload` JSON for schema flexibility.

### `payload` JSON schema

```jsonc
{
  // Versioning (mandatory — supports future migration)
  "payloadVersion": 1,

  // Identity
  "name": "stoic-language",                          // human-readable id
  "description": "Use stoic Cantonese mentor voice instead of corporate AI tone",
  "source": "alex",                                  // 'alex' | 'importedFromAnchor'

  // Trigger
  "trigger": {
    "kind": "mode",                                  // 'always' | 'regex' | 'mode' (NOT 'intent' in v2)
    "pattern": null,                                 // string for regex; null otherwise
    "modes": ["direction", "brainstorm", "plan"],    // for kind=mode; whitelist of QuickActionMode raw values
    "turnRange": { "min": 1, "max": null },          // optional; min/max are inclusive turnIndex bounds; max=null means unbounded
    "priority": 50,                                  // 0-100; higher = applied first
    "specificity": 1                                  // tiebreaker: count of trigger constraints (kind, modes, turnRange) — higher wins
  },

  // Action
  "action": {
    "kind": "promptFragment",                         // v2 only this kind
    "content": "Speak as a stoic Cantonese mentor..."
  },

  // Notes (informational, not enforced)
  "rationale": "Why this skill exists",
  "antiPatternExamples": ["Example bad output 1"]    // empty list allowed
}
```

**Naming convention:** all JSON keys are camelCase to match Swift property names. JSONDecoder uses default `keyDecodingStrategy` (NOT `.convertFromSnakeCase`); CodingKeys are not required because property names match. Trigger kind raw values are `"always" | "regex" | "mode"` (lowercase, no underscores).

**`payloadVersion`** is mandatory in every payload. v2 ships at version `1`. Decoder requires `payloadVersion >= 1`; future payload schema evolution bumps the integer and ships a migrator.

Trigger kinds:

- **`always`**: fires on every turn (subject to `turnRange` if present, mode whitelist if present, and per-category cap).
- **`regex`**: fires when `pattern` matches the user message after Unicode normalization (NFKC) + lowercase. `pattern` is a Swift `NSRegularExpression`-compatible string. **Validated at insert/update**; invalid regex rejects the row. Mixed-script (Cantonese + English) and full-width punctuation handled by NFKC normalization.
- **`mode`**: fires only when `request.snapshot.activeQuickActionMode` (the EXPLICIT chip-tap mode, not the Steward-inferred mode) matches one of `modes`. **Default companion chat (no chip tapped) does NOT fire mode skills.** This is the explicit-only semantics required to make the migration semantically equivalent to the existing `agent.contextAddendum(turnIndex:)` flow.
- **`intent`** is **NOT a valid v2 trigger kind**. SkillStore rejects insert/update of `intent` triggers; SkillMatcher logs an error if it encounters one (should be impossible after insert validation). Reserved keyword for v2.5; not silently ignored.

`turnRange` is optional but supports Plan's existing behavior (turn-1 partial-plan / turn-2-3 production / turn-4+ final). When present, `turnRange.min` ≤ `request.turnIndex` ≤ `turnRange.max` (or `min` ≤ `turnIndex` if `max` is null) is a required match condition.

Action kinds:

- **`promptFragment`**: concatenated into the `quickActionAddendum` string passed to `assembleContext`. Insertion order = priority desc → specificity desc → name asc.

Future kinds (v2.5+): `toolSequence`, `composite`. v2 only `promptFragment`.

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
    /// Schema version. Required. v2 ships at 1. Decoder rejects payloads with
    /// missing or older payloadVersion.
    let payloadVersion: Int

    let name: String
    let description: String?
    let source: SkillSource
    let trigger: SkillTrigger
    let action: SkillAction

    // Notes (informational; safe defaults if missing in older payloads)
    let rationale: String?
    let antiPatternExamples: [String]

    enum CodingKeys: String, CodingKey {
        case payloadVersion, name, description, source, trigger, action,
             rationale, antiPatternExamples
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .payloadVersion)
        guard version >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .payloadVersion, in: c,
                debugDescription: "payloadVersion must be >= 1"
            )
        }
        self.payloadVersion = version
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.source = try c.decode(SkillSource.self, forKey: .source)
        self.trigger = try c.decode(SkillTrigger.self, forKey: .trigger)
        self.action = try c.decode(SkillAction.self, forKey: .action)
        self.rationale = try c.decodeIfPresent(String.self, forKey: .rationale)
        self.antiPatternExamples = try c.decodeIfPresent(
            [String].self, forKey: .antiPatternExamples
        ) ?? []
    }
}

enum SkillSource: String, Codable {
    case alex
    case importedFromAnchor = "importedFromAnchor"   // camelCase wire value
}

struct SkillTrigger: Codable, Equatable {
    /// `intent` is reserved for v2.5; SkillStore.insertSkill rejects it.
    /// SkillMatcher must log + skip if encountered (defensive).
    enum Kind: String, Codable { case always, regex, mode }

    let kind: Kind
    let pattern: String?                         // required for kind=regex; nil otherwise
    let modes: [QuickActionMode]?                // required for kind=mode; nil otherwise
    let turnRange: TurnRange?                    // optional; bounds turnIndex when present
    let priority: Int                            // 0-100
    let specificity: Int                         // count of constraints (kind, modes, turnRange, pattern); used as deterministic tiebreaker

    /// `min` / `max` are inclusive turnIndex bounds. `max == nil` means unbounded above.
    /// Plan turn-1: `{ min: 1, max: 1 }`. Plan turn-2-3: `{ min: 2, max: 3 }`.
    /// Plan turn-4+: `{ min: 4, max: nil }`.
    struct TurnRange: Codable, Equatable {
        let min: Int
        let max: Int?
    }
}

struct SkillAction: Codable, Equatable {
    enum Kind: String, Codable { case promptFragment }   // wire value 'promptFragment' (camelCase)
    let kind: Kind
    let content: String
}
```

Implementation notes:

- `SkillPayload` encodes/decodes via JSONEncoder/Decoder with default key strategy (camelCase wire = camelCase Swift). The Swift type is the source of truth; the SQLite TEXT column is the durable form. New fields can be added to `SkillPayload` without `ALTER TABLE` as long as they are optional or carry safe defaults via custom `init(from:)`.
- The custom `init(from:)` above is mandatory: it ensures `antiPatternExamples` defaults to `[]` for older payloads, validates `payloadVersion >= 1`, and prevents Swift's synthesized decoder from failing on missing-but-defaultable fields.
- `SkillStoring.insertSkill` and `updateSkill` MUST validate: `kind != .intent`; `kind == .regex implies pattern != nil` and `NSRegularExpression(pattern:)` succeeds; `kind == .mode implies modes != nil && !modes.isEmpty`. Reject with descriptive Swift error.

### `SkillMatcher`

Pure logic, no IO. Given turn context, returns the skills that should fire this turn.

```swift
struct SkillMatchContext {
    /// User message after Unicode NFKC normalization + lowercase. Used for regex match.
    let userMessageNormalized: String
    /// EXPLICIT chip-tap mode (request.snapshot.activeQuickActionMode), NOT
    /// Steward-inferred mode. Default companion chat = nil.
    let activeQuickActionMode: QuickActionMode?
    let turnIndex: Int
}

protocol SkillMatching {
    /// Returns the skills that fire this turn, ordered for prompt insertion.
    /// Mode skills always fire (no cap on them — they are the structural skeleton).
    /// Non-mode skills (always / regex) cap at `nonModeCap`.
    /// Sort within each category: priority desc → specificity desc → name asc.
    func matchingSkills(
        from skills: [Skill],
        context: SkillMatchContext,
        nonModeCap: Int
    ) -> [Skill]
}

final class SkillMatcher: SkillMatching {
    func matchingSkills(
        from skills: [Skill],
        context: SkillMatchContext,
        nonModeCap: Int = 3
    ) -> [Skill] {
        let active = skills
            .filter { $0.state == .active }
            .filter { skillTriggersFor($0, context: context) }

        let modeSkills = active.filter { $0.payload.trigger.kind == .mode }
        let nonModeSkills = active.filter { $0.payload.trigger.kind != .mode }

        // Mode skills always fire — they are structural (the contract migration
        // from DirectionAgent/BrainstormAgent/PlanAgent depends on this).
        // Non-mode skills (taste/voice) compete for nonModeCap slots.
        let mode = modeSkills.sorted(by: Self.skillOrdering)
        let nonMode = Array(
            nonModeSkills.sorted(by: Self.skillOrdering).prefix(nonModeCap)
        )

        // Mode skills emit first so the mode skeleton is the spine of the
        // prompt; taste skills layer on top.
        return mode + nonMode
    }

    private func skillTriggersFor(_ skill: Skill, context: SkillMatchContext) -> Bool {
        let trigger = skill.payload.trigger

        // Defensive: insert validation should have rejected `intent`, but log+skip
        // if seen at runtime.
        if trigger.kind == .always || trigger.kind == .regex || trigger.kind == .mode {
            // proceed
        } else {
            // future kinds — log and skip
            return false
        }

        // turnRange (if present) gates ALL kinds
        if let range = trigger.turnRange {
            if context.turnIndex < range.min { return false }
            if let max = range.max, context.turnIndex > max { return false }
        }

        switch trigger.kind {
        case .always:
            // mode whitelist (if present) gates always-firing skills
            if let modes = trigger.modes,
               let active = context.activeQuickActionMode {
                return modes.contains(active)
            }
            // No mode whitelist + always = fires in every context including default chat
            return trigger.modes == nil
        case .regex:
            guard let pattern = trigger.pattern,
                  let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { return false }
            let range = NSRange(context.userMessageNormalized.startIndex..., in: context.userMessageNormalized)
            return regex.firstMatch(in: context.userMessageNormalized, range: range) != nil
        case .mode:
            // Mode kind requires explicit chip-tap. Default companion chat does NOT
            // fire mode skills — this is the explicit-only semantics that preserves
            // current addendum behavior.
            guard let active = context.activeQuickActionMode,
                  let modes = trigger.modes
            else { return false }
            return modes.contains(active)
        }
    }

    /// Deterministic ordering: priority desc → specificity desc → name asc.
    /// Same name disambiguated by id (UUID string) asc as final tiebreaker.
    private static func skillOrdering(_ lhs: Skill, _ rhs: Skill) -> Bool {
        let l = lhs.payload.trigger
        let r = rhs.payload.trigger
        if l.priority != r.priority { return l.priority > r.priority }
        if l.specificity != r.specificity { return l.specificity > r.specificity }
        if lhs.payload.name != rhs.payload.name { return lhs.payload.name < rhs.payload.name }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
```

**Cap composition:** mode-triggered skills always fire (no cap on them); non-mode skills (`always` / `regex`) cap at `nonModeCap` (default 3). Reason: the migration's purpose is to preserve mode behavior. A simple total cap can starve mode skeletons when ≥3 always-on taste skills outrank them by priority. Splitting the cap by kind preserves the contract.

In practice, only one mode skill fires per turn (modes are mutually exclusive), so the effective per-turn cap is **1 mode skill + 3 non-mode skills = 4 total**. If Plan adds three turn-range-gated skills (turn-1 / turn-2-3 / turn-4+) they are all `mode:plan` skills, but only ONE matches a given turnIndex due to mutually-exclusive `turnRange`s.

**Tiebreaker discipline.** Equal priority + equal specificity is broken by `name` ascending; equal name is broken by `id.uuidString` ascending. SQLite fetch order is NOT a tiebreaker — never trust DB row order across runs.

### `SkillTracker`

Observes turn outcomes, updates `firedCount` + `lastFiredAt`. v2 tracks fire-only; success/fail signal deferred to v2.5.

```swift
protocol SkillTracking {
    func recordFire(skillIds: [UUID]) async throws
}
```

Called from `TurnExecutor` (or `AgentLoopExecutor`) after the turn assembles its prompt. v2 does NOT track success/fail; that requires user signal infrastructure deferred per Codex critique #5.

### Integration boundary: `assembleContext` callers, NOT inside

`ChatViewModel.assembleContext(...)` is `nonisolated static`, synchronous, non-throwing, with no store dependency (`ChatViewModel.swift:967`). **The SkillStore + SkillMatcher MUST run at the CALLERS of assembleContext, not inside it.** Putting DB access into a pure prompt assembler would either force hidden global state or change the function's signature to throwing/async — both are wrong.

The correct integration point is where `quickActionAddendum` is currently assembled:

1. **`TurnPlanner.swift:230`** — per-turn invocation. Currently:
   ```swift
   let quickActionAddendum: String? = planningAgent?.contextAddendum(turnIndex: agentTurnIndex)
   ```
   After migration:
   ```swift
   let activeSkills = try skillStore.fetchActiveSkills(userId: "alex")
   let matched = skillMatcher.matchingSkills(
       from: activeSkills,
       context: SkillMatchContext(
           userMessageNormalized: prepared.userMessage.applyingTransform(...),
           activeQuickActionMode: explicitQuickActionMode,
           turnIndex: agentTurnIndex
       )
   )
   let quickActionAddendum: String? = matched.isEmpty
       ? nil
       : matched.map { $0.payload.action.content }.joined(separator: "\n\n")
   // Optional: fire-and-forget tracker
   Task.detached { try? await skillTracker.recordFire(skillIds: matched.map { $0.id }) }
   ```

2. **`ChatViewModel.swift:340`** — opening turn invocation. Same pattern, but `turnIndex: 0`.

`assembleContext` keeps its current `quickActionAddendum: String?` parameter and signature unchanged. This means the migration is byte-identical at the assembleContext boundary IF the matcher produces the same string content for the same turn context. That equivalence is the migrator's correctness invariant.

**Use the EXPLICIT mode, not the inferred one.** The current addendum flow uses `request.snapshot.activeQuickActionMode` (the chip the user actually tapped). Steward-inferred quick mode (`TurnPlanner.swift:62` neighborhood) is a different signal. The matcher must use explicit mode only — otherwise default companion chat would start firing mode skeletons, regressing today's behavior (Codex finding #9).

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

### Skill authoring (seed file, INSERT-ONLY)

v2 does NOT include a Skill UI. Authoring path is a seed file in app resources:

`Sources/Nous/Resources/seed-skills.json`

```jsonc
[
  {
    "id": "00000000-0000-0000-0000-000000000001",
    "userId": "alex",
    "payload": {
      "payloadVersion": 1,
      "name": "stoic-cantonese-voice",
      ...
    },
    "state": "active"
  }
]
```

**Import policy: STRICTLY INSERT-ONLY.** The seed importer runs on app launch and:

- For each row in `seed-skills.json`, looks up `id` in the `skills` table.
- If `id` exists → **does nothing** (no overwrite, no field merge, no count reset).
- If `id` does not exist → inserts the row with `state` from the file (default 'active') and `firedCount = 0`.

This is the only acceptable policy because:

- Updating shipped seed content would silently overwrite Alex's local edits (Alex tweaks priority of skill X via SQL → next app launch resets it → Alex confused). Bad UX.
- Skipping inserts entirely would mean shipped fixes to seed-skills.json never reach Alex's existing DB. Worse UX.
- INSERT-ONLY means: shipping a content change to a seed skill requires bumping its `id` (new UUID), which orphans the old skill (Alex can manually retire it via SQL). This is the correct trade-off — content changes are explicit, not silent.

Alex's local skill edits use direct SQL (or the v2.5 Skill UI, when built) and will never be overwritten by the seed importer. Pre-resolved Codex finding #10.

## Migrator: hardcoded addendum → seed skills

Phase 2.2 work: convert the current hardcoded `*Agent.swift` `contextAddendum` strings into seed skills.

### Mapping

All Plan-related skills get the same `priority: 70`. They are NOT in conflict because their `turnRange` constraints are mutually exclusive — exactly ONE matches a given turnIndex.

| Source | Target skill | Trigger |
|---|---|---|
| `DirectionAgent.contextAddendum` (turnIndex >= 1) | `direction-skeleton` | `kind=mode, modes=[direction], turnRange={min:1, max:nil}, priority=70` |
| `BrainstormAgent.contextAddendum` (turnIndex >= 1) | `brainstorm-skeleton` | `kind=mode, modes=[brainstorm], turnRange={min:1, max:nil}, priority=70` |
| `PlanAgent.decideOrAskAddendum` (turnIndex == 1) | `plan-turn1-contract` | `kind=mode, modes=[plan], turnRange={min:1, max:1}, priority=70` |
| `PlanAgent.normalProductionAddendum` (turnIndex 2-3) | `plan-production` | `kind=mode, modes=[plan], turnRange={min:2, max:3}, priority=70` |
| `PlanAgent.finalUrgentAddendum` (turnIndex >= 4) | `plan-final-turn` | `kind=mode, modes=[plan], turnRange={min:4, max:nil}, priority=70` |

This faithfully reproduces `PlanAgent.contextAddendum`'s `switch turnIndex` logic without changing semantics. Plan turn 0 has no skill firing (mode addendum was always nil at turn 0), turn 1 fires only `plan-turn1-contract`, turns 2-3 fire only `plan-production`, turn 4+ fires only `plan-final-turn`. Pre-resolved Codex finding #1 (Plan migration regression).

`maxClarificationTurns = 4` from `PlanAgent.swift:8` is preserved as a constant the migrator references when computing `turnRange.min` for `plan-final-turn`. If Alex changes the cap in the future (still in spec scope), the seed-skills.json bumps the `min` value via a new skill `id` (insert-only policy).

### After migration

`DirectionAgent / BrainstormAgent / PlanAgent` lose their `contextAddendum` body content. They become thin policy wrappers: still own `openingPrompt()`, `memoryPolicy()`, `turnDirective()`, `toolNames`, `useAgentLoop`. The mode-specific addendum text moves to seed-skills.json.

The integration call site changes from a single agent method call to: fetch skills → match → concatenate. See "Integration boundary" section above for the exact change at `TurnPlanner.swift:230` and `ChatViewModel.swift:340`. `assembleContext` itself is unchanged — it still receives a `quickActionAddendum: String?` parameter; the matcher just produces that string differently.

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

**Discipline:** taste skills must add something the existing mode addenda do NOT already say. Skills that duplicate text already in `direction-skeleton` / `plan-turn1-contract` create double-coding (Codex finding #12) — pulled from this list.

6. `stoic-cantonese-voice` — "Speak as a stoic Cantonese mentor; avoid corporate-AI register" (trigger: `always`, priority 60)
7. `concrete-over-generic` — "Refer to specific files, function names, and real numbers; avoid generic guidance" (trigger: `always`, priority 60)
8. `direct-when-disagreeing` — "If Alex's framing is wrong, say so plainly; do not perform agreement" (trigger: `always`, priority 55)
9. `interleave-language` — "Cantonese for warmth and product; English for technical terms; do not translate technical terms unnecessarily" (trigger: `always`, priority 55)
10. `weight-against-default-chat-baseline` — "If you ask a question, the answer must materially change your reply; do not ask filler questions" (trigger: `always`, priority 50)

**Removed from original list (Codex finding #12):**

- `no-advice-list` — already in DirectionAgent and PlanAgent addenda. Double-coding risk.
- `acknowledge-real-constraints` (F-1 visa, solo founder, limited capital) — this is **personal factual data, not a skill**. Belongs in `user_facts` (per Path B Hook 3), not in SkillStore. Will be added as user-model facts in a separate v2.1 task; do not treat as skill.

These 5 are explicit extracts of patterns Alex has been correcting/teaching me throughout sessions — codifying them as skills makes them addressable + observable.

## Test plan

### Unit tests

- **`SkillStoreTests`** (CRUD round-trip):
  - Insert skill → fetch returns it
  - Update skill → updated content + last_modified_at incremented
  - setSkillState(retired) → no longer in fetchActiveSkills
  - incrementFiredCount → fired_count + last_fired_at updated atomically

- **`SkillMatcherTests`** (pure logic, in-memory skills):
  - `always` trigger: fires regardless of message/mode (subject to mode whitelist if present)
  - `regex` trigger: fires only when message matches (after NFKC normalization)
  - `regex` trigger: Cantonese mixed-script message + Cantonese pattern matches
  - `regex` trigger: full-width punctuation in message normalizes to half-width before match
  - `regex` trigger: invalid pattern returns false + logs (defensive; insert validation should catch)
  - `mode` trigger: fires only when explicit `activeQuickActionMode` is in `modes` whitelist
  - `mode` trigger: nil `activeQuickActionMode` (default chat) does NOT fire mode skills
  - `mode` trigger: mode does NOT match Steward-inferred mode — only chip-tap mode
  - `intent` trigger: SkillMatcher returns false + logs (insert validation should reject; defensive)
  - `turnRange` constraint: `min=1, max=1` fires only at turnIndex 1
  - `turnRange` constraint: `min=2, max=3` fires at 2 and 3, not 1 or 4
  - `turnRange` constraint: `min=4, max=nil` fires at 4 and 5+
  - **Plan turn matrix** (exhaustive): turn 0/1/2/3/4/5 produces same selection as `PlanAgent.contextAddendum(turnIndex:)`
  - **Cap composition**: 5 always-on taste skills at priority 80 + 1 mode-skeleton at priority 70 → mode-skeleton STILL fires (mode skills have no cap)
  - **Cap enforcement** (non-mode): 5 always-on skills, nonModeCap=3 → top 3 by priority+specificity+name returned
  - **Equal-priority deterministic ordering**: 5 skills tied at priority 70, varying specificity/name → ordering is stable across runs
  - **Equal priority + specificity + name**: ordering is by id ascending; matcher does NOT depend on SQLite fetch order
  - Inactive skills (`state != active`) excluded
  - Empty skills array → returns empty

- **`SkillPayloadCodableTests`**:
  - Round-trip JSON encode/decode preserves all fields including `payloadVersion`
  - **camelCase wire keys** (`payloadVersion`, `antiPatternExamples`, `turnRange`, etc.) decode without `convertFromSnakeCase` strategy
  - **Missing `antiPatternExamples`** → defaults to `[]`, no decode error (custom init)
  - **Missing `payloadVersion`** → decode fails with descriptive error (required field)
  - **`payloadVersion = 0`** → decode fails (`>= 1` required)
  - **Unknown future fields in JSON** → silently ignored (synthesized Decodable behavior)
  - **Missing `description` / `rationale`** → decode succeeds (optional fields)
  - **`SkillSource` raw values** decode: `"alex"` → `.alex`, `"importedFromAnchor"` → `.importedFromAnchor`
  - **`SkillTrigger.Kind` raw values** decode: `"always" | "regex" | "mode"` succeed, `"intent"` decodes to enum but SkillStore insert rejects
  - **Snake_case payload (legacy/buggy)** like `anti_pattern_examples` → decode FAILS (we want explicit camelCase, not silent acceptance)

- **`SkillStoreInsertValidationTests`**:
  - Insert with `kind=regex, pattern=nil` → throws (regex requires pattern)
  - Insert with `kind=regex, pattern="["` (invalid regex) → throws
  - Insert with `kind=mode, modes=nil` → throws (mode requires modes whitelist)
  - Insert with `kind=mode, modes=[]` → throws (empty whitelist invalid)
  - Insert with `kind=intent` → throws (reserved, not implemented in v2)
  - Insert with corrupt JSON payload → SQLite CHECK rejects (boundary safety)
  - Insert with state='actve' (typo) → SQLite CHECK rejects
  - Insert with valid `kind=mode, modes=[direction], turnRange={min:1, max:1}` → succeeds

- **`SeedSkillImporterTests`** (INSERT-ONLY policy):
  - First launch: imports all 10 seed skills
  - Subsequent launch with same seed-skills.json: idempotent (no duplicates, no field mutation)
  - **Seed file changes content for an existing skill ID**: importer SKIPS the existing row (insert-only). Alex's local edits preserved. New seed content NOT applied.
  - **Seed file adds new skill ID**: importer inserts that one row, leaves existing alone.
  - **Alex deletes a seeded skill via SQL**: next launch re-imports it (matches "id does not exist" branch). Documented behavior.
  - **Seed file removes a skill ID**: existing row in DB stays (no auto-delete).
  - **Already-migrated DB rerun**: zero changes, zero side effects.
  - **Race condition**: two concurrent launches → second launch's INSERT IGNORE / IF NOT EXISTS prevents duplicate rows.

- **`SkillIntegrationTests`** (against `TurnPlanner` + `ChatViewModel` callers):
  - **Snapshot pre/post migration**: same user input + same memory state → assembleContext produces byte-identical (or documented-acceptable) `quickActionAddendum` string for Direction turn 1, Brainstorm turn 1, Plan turn 1, Plan turn 2, Plan turn 4
  - With Direction mode active and `direction-skeleton` skill: matcher returns the skeleton + non-mode taste skills
  - With Plan mode active at turn 1: matcher returns ONLY `plan-turn1-contract` from mode skills (turn-2-3 + turn-4+ skills do not fire)
  - With Plan mode active at turn 4: matcher returns ONLY `plan-final-turn`
  - Cap starvation regression test: 5 priority-80 always-on taste skills + priority-70 mode-skeleton → mode-skeleton STILL appears in matched output (no cap on mode skills)
  - **Corrupt payload row**: insert a row that bypasses CHECK (e.g., via direct SQLite tooling) — matcher logs error and skips this row, prompt assembly does NOT crash
  - **Concurrent launch**: two `SeedSkillImporter` instances against the same `Database` mutex — only one INSERT succeeds per id
  - **Transaction safety**: `incrementFiredCount` while a parallel `setSkillState` runs — both serialize via shared transaction lock, no torn rows

### Manual QA

After migration:

1. Launch Nous, tap Direction chip, ask P1 question. Verify reply has Direction shape (same as pre-migration). Console shows `[SkillTrace]` listing `direction-skeleton` + Alex-taste skills firing.
2. Tap Brainstorm chip, ask P2 question. Verify Brainstorm shape (same). Console shows `brainstorm-skeleton` firing.
3. Tap Plan chip, ask P3 question. Verify Plan turn-1 partial-plan triad. Console shows `plan-turn1-contract` firing.
4. Default chat (no chip): verify only Alex-taste skills fire (no mode-skeleton skills). Console shows reduced active set.

If any of these regress vs current behavior, the migration broke something. Fix before continuing.

## Risks

1. **Migration may regress prompt-level behavior.** Even with same string content, the new path (skill matching → assemble) may inject text differently than current direct-from-agent path. Mitigation: snapshot test that `assembleContext`'s `quickActionAddendum` argument is byte-identical (or documented-acceptable diff) for same input pre/post migration. Tests in `SkillIntegrationTests` cover Direction / Brainstorm / Plan turn 1 / Plan turn 2 / Plan turn 4.

2. **Skill matching latency.** Loading 10 skills from SQLite + matching is < 5 ms. If skill count grows (50+) and matching includes regex evaluation, latency may matter. v2 stays under 20 skills; v2.5 may need indexing.

3. **JSON payload schema evolution.** Adding new fields to `SkillPayload` works (custom `init(from:)` defaults missing fields). RENAMING fields requires bumping `payloadVersion` + migration. Treat current schema as version 1.

4. **Cap composition may still be wrong.** Per-category cap (mode skills always fire + non-mode cap=3) prevents starvation but makes total cap variable. Power user with 5 always-on voice skills cannot have all 5 fire — only top 3 win. Mitigation: nonModeCap is a config; can raise to 5 if dogfood reveals friction without prompt-overcrowding. The design point is that mode-skeletons survive — that is non-negotiable.

5. **`always` triggers can over-fire in default companion chat.** Without a mode whitelist, an always-fire taste skill enters the prompt for default chat too — possibly diluting default-chat voice. Mitigation: tasteskills SHOULD specify mode whitelists (`always` + `modes: [direction, brainstorm, plan]`) to scope to chip turns only. Document this convention; do NOT enforce in code (some always skills genuinely apply everywhere — `stoic-cantonese-voice`).

6. **Transaction lock contention.** SQLite FULLMUTEX serializes individual calls but not multi-statement transactions. NodeStore has its own transaction lock for this reason (`NodeStore.swift:72`). SkillStore using the same `Database` instance MUST share the same transaction lock — own its lock = race conditions. Phase 2.1 implementation MUST refactor `Database` to expose a shared lock OR have SkillStore depend on NodeStore's lock. Tests in `SkillStoreInsertValidationTests` + concurrent-launch test cover this.

7. **`always` skill firing in default chat regressed today's behavior.** Currently default companion chat has NO addendum injection — `quickActionAddendum` is nil. After migration, `always` skills will inject into default chat for the first time. **This is a behavior change** that must be live-tested. If default chat output regresses, the fix is to add mode whitelists to all 5 taste skills (turning them effectively into mode-only skills).

## Open questions (resolved during implementation, not blocking)

1. **Where does `SkillStore` live in the app graph?** Probably `AppEnvironment` alongside `nodeStore`, `userMemoryService`. Confirm during implementation.

2. **Does `SkillTracker.recordFire(...)` await persistence or fire-and-forget?** v2 fire-and-forget (background task) to not block turn latency. Errors logged, not surfaced.

3. **Should seed-skills.json be in `Resources/` (bundled) or in app-data dir (user-editable)?** v2 bundled in `Resources/`; promote to app-data in v2.5 when Skill UI is built.

4. **Migration safety net:** if skill table is empty (first launch failed import) — fail loud during dev (DEBUG assertion); fall back to legacy `agent.contextAddendum(turnIndex:)` in release. Should never happen if seed import works.

5. **Does the seed importer rerun if `seed-skills.json` mtime changes?** No. Importer always runs on launch but is INSERT-ONLY (per "Skill authoring" section above). The mtime check would be misleading premature optimization; SQLite SELECT-by-id is < 1ms × 10 rows = negligible.

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
- **2026-04-28 (amendment)** — Codex challenge (session `019dd2b4-...`) surfaced 3 top-killer bugs + 12 detail findings. Doc amended:
  - **Top-3 fixes**: (a) Plan migration uses `turnRange` per skill so `decideOrAsk` / `normalProduction` / `finalUrgent` map to mutually-exclusive turn-range skills at same priority — no behavior regression. (b) `assembleContext` boundary clarified: SkillMatcher runs at callers (`TurnPlanner.swift:230`, `ChatViewModel.swift:340`), NOT inside the pure assembler. (c) Cap is composition-aware: mode skills always fire (no cap), non-mode skills cap at 3.
  - **Detail fixes**: REAL seconds (not INTEGER ms) for date columns; CHECK constraints on `state` + `json_valid(payload)`; camelCase JSON keys (no `convertFromSnakeCase`); `payloadVersion` mandatory; `intent` rejected at insert; explicit-mode-only matching (no Steward-inferred); INSERT-ONLY seed import (no field merge); shared transaction lock with NodeStore; tiebreaker discipline (priority → specificity → name → id).
  - **Seed skills 6-10 revised**: dropped `no-advice-list` (duplicate of mode addenda) and `acknowledge-real-constraints` (personal facts, not skill — moved to user_facts). Added `interleave-language` and `weight-against-default-chat-baseline`.
  - **10 missing tests added** to test plan: Plan turn matrix exhaustive, snapshot pre/post migration byte identity, equal-priority deterministic ordering, cap composition starvation regression, corrupt payload graceful skip, missing-field decode with defaults, snake_case decode failure (we want explicit camelCase), intent trigger reject path, seed importer INSERT-ONLY rerun matrix, concurrent launch transaction safety.
  - **New risks documented**: cap-composition limit on always skills, default-chat behavior change from always-skills firing.
