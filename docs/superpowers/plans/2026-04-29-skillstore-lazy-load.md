# SkillStore Lazy-Load Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace SkillStore Phase 2.1's full-content injection (~2,500 tokens/turn) with a Hermes-inspired index + lazy-load pattern: a new `loadSkill` tool, conversation-sticky skill snapshots, and a 4-marker prompt cache layout (Active before Index for mode-switch resilience). Token cost drops ≥ 80% per matched-mode turn.

**Architecture:** `PromptContextAssembler` emits `[SystemPromptBlock]` instead of stable/volatile strings. Block 3a holds previously-loaded skill content (snapshotted at load time, immune to source-skill mutations); Block 3b holds the matched-skill index (rendered only when `activeQuickActionMode != nil`). `loadSkill` is registered always-on so the `tools` cache prefix is byte-stable across mode switches; mode-scope is enforced inside `LoadSkillToolHandler` via a 4-step validation flow before any state mutation.

**Tech Stack:** Swift, SwiftUI, XCTest, raw SQLite via the existing `Database`/`NodeStore` pattern, OpenRouter (Sonnet 4.6) for foreground LLM with Anthropic prompt cache, Gemini 2.5 Pro for build-time backfill only.

**Spec:** `docs/superpowers/specs/2026-04-29-skillstore-lazy-load-design.md` (v3, commit `fd9da10`).

---

## Scope Check

This plan covers one connected subsystem: SkillStore lazy-load. It touches the data layer, prompt assembly, the LLM tool plumbing, and the `QuickActionAddendumResolver` cleanup because all four are required for one end-to-end lazy-load loop. It deliberately excludes anchor changes (P2), retrieval FTS (P4), session compression (P5), Honcho integration, and skill-fold schema evolution.

## File Structure

**Create:**

- `Sources/Nous/Services/LoadSkillToolHandler.swift` — 4-step validation handler routed from the `loadSkill` tool.
- `Sources/Nous/Models/SystemPromptBlock.swift` — block-structured system prompt + `BlockID` + `CacheControlMarker`.
- `Tests/NousTests/SkillStoreLazyLoadTests.swift`
- `Tests/NousTests/PromptContextAssemblerLazyLoadTests.swift`
- `Tests/NousTests/LoadSkillToolHandlerTests.swift`
- `Tests/NousTests/ToolRegistryStabilityTests.swift`
- `Tests/NousTests/SystemPromptBlockTests.swift`
- `Tests/NousTests/SkillStoreLazyLoadIntegrationTests.swift`
- `Tests/NousTests/CacheWireFormatTests.swift`
- `scripts/backfill-skill-useWhen.swift` (build-time backfill, NOT in PR diff)

**Modify:**

- `Sources/Nous/Services/NodeStore.swift` — add `conversation_loaded_skills` table.
- `Sources/Nous/Services/SkillStore.swift` — add `loadedSkills`, `markSkillLoaded`, `_incrementFiredCount` internal, `unloadAllSkills`; bump payload validation range.
- `Sources/Nous/Models/Skill.swift` — payload version `1...2`; `useWhen: String?`; `LoadedSkill` + `MarkSkillLoadedResult` types.
- `Sources/Nous/Models/TurnContracts.swift` — `TurnSystemSlice` becomes block-structured with `combined`, `combinedString`, `stable`, `volatile` accessors.
- `Sources/Nous/Models/Agents/AgentTool.swift` — add `activeQuickActionMode: QuickActionMode?` to `AgentToolContext`.
- `Sources/Nous/Models/Agents/QuickActionAgent.swift` — `useAgentLoop` returns `true` for all modes.
- `Sources/Nous/Services/PromptContextAssembler.swift` — emit `[SystemPromptBlock]`; add `renderActiveSkills` + `renderSkillIndex`; insert before volatile section.
- `Sources/Nous/Services/AgentLoopExecutor.swift` — pass `[SystemPromptBlock]` instead of `combined: String` to the tool LLM.
- `Sources/Nous/Services/LLMService.swift` — both `callWithoutTools` and `callWithTools` signatures take `[SystemPromptBlock]`; serialize per-block `cache_control` markers.
- `Sources/Nous/Services/ChatTurnRunner.swift` — propagate `activeQuickActionMode` into `AgentToolContext`; consume `turnSlice.blocks` where it currently consumes `turnSlice.combined`.
- `Sources/Nous/Services/QuickActionAddendumResolver.swift` — strip line 71 `joined` and the `Task.detached` tracker fire block (lines 64–69).
- `Sources/Nous/ViewModels/ChatViewModel.swift` — drop `.subset(mode.agent().toolNames)` at line 115; pass full registry.
- `seed-skills.json` — populate `useWhen` for each existing skill (via backfill script).

---

## Task 1: Add `conversation_loaded_skills` schema migration

**Files:**

- Modify: `Sources/Nous/Services/NodeStore.swift` (add table + index in the schema-creation block)
- Test: `Tests/NousTests/SkillStoreLazyLoadTests.swift` (new file, schema section)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NousTests/SkillStoreLazyLoadTests.swift
import XCTest
@testable import Nous

final class SkillStoreLazyLoadTests_Schema: XCTestCase {
    func test_migration_createsConversationLoadedSkillsTable() throws {
        let store = try makeFreshNodeStore()
        let columns = try store.rawDatabase.prepare(
            "PRAGMA table_info(conversation_loaded_skills);"
        ).allRows()
        let names = columns.compactMap { $0["name"] as? String }
        XCTAssertEqual(
            Set(names),
            Set(["conversation_id", "skill_id", "name_snapshot", "content_snapshot", "state_at_load", "loaded_at"])
        )
    }

    func test_migration_cascadesOnConversationDelete() throws {
        let store = try makeFreshNodeStore()
        let conv = try store.insertConversation(title: "t")
        let skill = try insertSkill(into: store)
        try store.rawDatabase.exec("""
            INSERT INTO conversation_loaded_skills
            (conversation_id, skill_id, name_snapshot, content_snapshot, state_at_load, loaded_at)
            VALUES ('\(conv.id)', '\(skill.id)', 'n', 'c', 'active', 1.0);
        """)
        try store.deleteNode(id: conv.id)
        let row = try store.rawDatabase.prepare(
            "SELECT COUNT(*) AS c FROM conversation_loaded_skills WHERE conversation_id = '\(conv.id)';"
        ).firstRow()
        XCTAssertEqual(row?["c"] as? Int64, 0)
    }

    func test_migration_doesNotCascadeOnSkillDelete() throws {
        let store = try makeFreshNodeStore()
        let conv = try store.insertConversation(title: "t")
        let skill = try insertSkill(into: store)
        try store.rawDatabase.exec("""
            INSERT INTO conversation_loaded_skills
            (conversation_id, skill_id, name_snapshot, content_snapshot, state_at_load, loaded_at)
            VALUES ('\(conv.id)', '\(skill.id)', 'n', 'c', 'active', 1.0);
        """)
        try store.rawDatabase.exec("DELETE FROM skills WHERE id = '\(skill.id)';")
        let row = try store.rawDatabase.prepare(
            "SELECT COUNT(*) AS c FROM conversation_loaded_skills WHERE skill_id = '\(skill.id)';"
        ).firstRow()
        XCTAssertEqual(row?["c"] as? Int64, 1, "snapshot row must persist after skill hard-delete")
    }
}
```

(The `makeFreshNodeStore()` and `insertSkill(into:)` helpers exist in this repo's `NodeStoreTests` test utilities — reuse them.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SkillStoreLazyLoadTests_Schema`
Expected: FAIL with `no such table: conversation_loaded_skills`.

- [ ] **Step 3: Add the migration**

In `Sources/Nous/Services/NodeStore.swift`, locate the `try db.exec("""CREATE TABLE IF NOT EXISTS skills...""")` block (around line 453) and append:

```swift
try db.exec("""
    CREATE TABLE IF NOT EXISTS conversation_loaded_skills (
        conversation_id   TEXT NOT NULL,
        skill_id          TEXT NOT NULL,
        name_snapshot     TEXT NOT NULL,
        content_snapshot  TEXT NOT NULL,
        state_at_load     TEXT NOT NULL,
        loaded_at         REAL NOT NULL,
        PRIMARY KEY (conversation_id, skill_id),
        FOREIGN KEY (conversation_id) REFERENCES nodes(id) ON DELETE CASCADE
    );
""")

try db.exec("""
    CREATE INDEX IF NOT EXISTS idx_loaded_skills_conv
    ON conversation_loaded_skills(conversation_id);
""")
```

Note: there is intentionally NO foreign key on `skill_id`. Snapshot rows must outlive their source skill row.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SkillStoreLazyLoadTests_Schema`
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/NodeStore.swift Tests/NousTests/SkillStoreLazyLoadTests.swift
git commit -m "feat(skillstore): add conversation_loaded_skills table with snapshot columns"
```

---

## Task 2: Bump `SkillPayload` to v2 with `useWhen` field

**Files:**

- Modify: `Sources/Nous/Models/Skill.swift`
- Modify: `Sources/Nous/Services/SkillStore.swift` (validate function)
- Test: `Tests/NousTests/SkillStoreLazyLoadTests.swift` (payload section)

- [ ] **Step 1: Write the failing tests**

Append to `Tests/NousTests/SkillStoreLazyLoadTests.swift`:

```swift
final class SkillStoreLazyLoadTests_Payload: XCTestCase {
    func test_payloadVersion1_decodesWithUseWhenNil() throws {
        let json = """
        {
          "payloadVersion": 1,
          "name": "x", "source": "alex",
          "trigger": {"kind":"mode","modes":["direction"],"priority":50},
          "action": {"kind":"promptFragment","content":"c"}
        }
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(SkillPayload.self, from: json)
        XCTAssertEqual(payload.payloadVersion, 1)
        XCTAssertNil(payload.useWhen)
    }

    func test_payloadVersion2_decodesWithUseWhen() throws {
        let json = """
        {
          "payloadVersion": 2,
          "name": "x", "useWhen": "Use when: ...", "source": "alex",
          "trigger": {"kind":"mode","modes":["direction"],"priority":50},
          "action": {"kind":"promptFragment","content":"c"}
        }
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(SkillPayload.self, from: json)
        XCTAssertEqual(payload.payloadVersion, 2)
        XCTAssertEqual(payload.useWhen, "Use when: ...")
    }

    func test_payloadVersion3_failsToDecode() throws {
        let json = """
        {
          "payloadVersion": 3,
          "name": "x", "source": "alex",
          "trigger": {"kind":"mode","modes":["direction"],"priority":50},
          "action": {"kind":"promptFragment","content":"c"}
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(SkillPayload.self, from: json))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SkillStoreLazyLoadTests_Payload`
Expected: 2 of 3 fail (`useWhen` field doesn't exist; v2 rejected).

- [ ] **Step 3: Update `Skill.swift` to accept v1 and v2**

In `Sources/Nous/Models/Skill.swift`:

```swift
struct SkillPayload: Codable, Equatable {
    let payloadVersion: Int
    let name: String
    let description: String?
    let useWhen: String?  // NEW
    let source: SkillSource
    let trigger: SkillTrigger
    let action: SkillAction
    let rationale: String?
    let antiPatternExamples: [String]

    init(
        payloadVersion: Int,
        name: String,
        description: String? = nil,
        useWhen: String? = nil,
        source: SkillSource,
        trigger: SkillTrigger,
        action: SkillAction,
        rationale: String? = nil,
        antiPatternExamples: [String] = []
    ) {
        self.payloadVersion = payloadVersion
        self.name = name
        self.description = description
        self.useWhen = useWhen
        self.source = source
        self.trigger = trigger
        self.action = action
        self.rationale = rationale
        self.antiPatternExamples = antiPatternExamples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .payloadVersion)
        guard (1...2).contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .payloadVersion,
                in: container,
                debugDescription: "SkillStore accepts payloadVersion ∈ 1...2"
            )
        }
        payloadVersion = version
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        useWhen = try container.decodeIfPresent(String.self, forKey: .useWhen)
        source = try container.decode(SkillSource.self, forKey: .source)
        trigger = try container.decode(SkillTrigger.self, forKey: .trigger)
        action = try container.decode(SkillAction.self, forKey: .action)
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
        antiPatternExamples = try container.decodeIfPresent([String].self, forKey: .antiPatternExamples) ?? []
    }
}
```

- [ ] **Step 4: Update `SkillStore.validate`**

In `Sources/Nous/Services/SkillStore.swift:144-146`, change:

```swift
private func validate(_ payload: SkillPayload) throws {
    guard (1...2).contains(payload.payloadVersion) else {
        throw SkillStoreError.invalidPayloadVersion(payload.payloadVersion)
    }
    // (keep the rest as-is)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter SkillStoreLazyLoadTests_Payload`
Expected: 3 PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Models/Skill.swift Sources/Nous/Services/SkillStore.swift Tests/NousTests/SkillStoreLazyLoadTests.swift
git commit -m "feat(skillstore): bump SkillPayload to v2 with optional useWhen field"
```

---

## Task 3: Add `LoadedSkill`, `MarkSkillLoadedResult`, `loadedSkills(in:)`

**Files:**

- Modify: `Sources/Nous/Models/Skill.swift` (add types)
- Modify: `Sources/Nous/Services/SkillStore.swift` (add protocol method + implementation)
- Test: `Tests/NousTests/SkillStoreLazyLoadTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/NousTests/SkillStoreLazyLoadTests.swift`:

```swift
final class SkillStoreLazyLoadTests_LoadedSkills: XCTestCase {
    func test_loadedSkills_returnsEmptyForFreshConversation() throws {
        let (store, conv, _) = try setupConvAndSkill()
        XCTAssertEqual(try store.loadedSkills(in: conv).count, 0)
    }

    func test_loadedSkills_returnsOrderedByLoadedAtAsc() throws {
        let (store, conv, skill1) = try setupConvAndSkill()
        let skill2 = try insertSkill(into: store.nodeStore, name: "second")
        try insertLoadedSkillRow(store, conv: conv, skill: skill2, loadedAt: 2.0)
        try insertLoadedSkillRow(store, conv: conv, skill: skill1, loadedAt: 1.0)
        let result = try store.loadedSkills(in: conv)
        XCTAssertEqual(result.map(\.skillID), [skill1.id, skill2.id])
    }

    func test_loadedSkills_returnsSnapshotsEvenIfSkillHardDeleted() throws {
        let (store, conv, skill) = try setupConvAndSkill()
        try insertLoadedSkillRow(store, conv: conv, skill: skill, loadedAt: 1.0)
        try store.nodeStore.rawDatabase.exec("DELETE FROM skills WHERE id = '\(skill.id)';")
        let result = try store.loadedSkills(in: conv)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.nameSnapshot, skill.payload.name)
    }
}

// Helpers (add to SkillStoreTestUtilities.swift if not already present):
//
// func setupConvAndSkill() -> (SkillStore, UUID, Skill)
// func insertSkill(into:NodeStore,name:String) -> Skill
// func insertLoadedSkillRow(_ store: SkillStore, conv: UUID, skill: Skill, loadedAt: Double) throws
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SkillStoreLazyLoadTests_LoadedSkills`
Expected: 3 FAIL — `loadedSkills` method does not exist.

- [ ] **Step 3: Add `LoadedSkill` and `MarkSkillLoadedResult` types**

In `Sources/Nous/Models/Skill.swift`, append:

```swift
struct LoadedSkill: Equatable {
    let skillID: UUID
    let nameSnapshot: String
    let contentSnapshot: String
    let stateAtLoad: SkillState
    let loadedAt: Date
}

enum MarkSkillLoadedResult: Equatable {
    case inserted(LoadedSkill)
    case alreadyLoaded(LoadedSkill)
    case missingSkill
    case unavailable(SkillState)
}
```

- [ ] **Step 4: Add `loadedSkills(in:)` to protocol + implementation**

In `Sources/Nous/Services/SkillStore.swift`, extend the `SkillStoring` protocol:

```swift
protocol SkillStoring {
    // (existing methods unchanged)
    func fetchAllSkills(userId: String) throws -> [Skill]
    func fetchActiveSkills(userId: String) throws -> [Skill]
    func fetchSkill(id: UUID) throws -> Skill?
    func insertSkill(_ skill: Skill) throws
    func updateSkill(_ skill: Skill) throws
    func setSkillState(id: UUID, state: SkillState) throws
    func incrementFiredCount(id: UUID, firedAt: Date) throws

    // NEW
    func loadedSkills(in conversationID: UUID) throws -> [LoadedSkill]
}
```

In the `SkillStore` class, add:

```swift
func loadedSkills(in conversationID: UUID) throws -> [LoadedSkill] {
    let stmt = try database.prepare("""
        SELECT skill_id, name_snapshot, content_snapshot, state_at_load, loaded_at
        FROM conversation_loaded_skills
        WHERE conversation_id = ?
        ORDER BY loaded_at ASC, skill_id ASC;
    """)
    try stmt.bind(conversationID.uuidString, at: 1)
    var result: [LoadedSkill] = []
    while try stmt.step() {
        guard
            let idString = stmt.text(at: 0),
            let id = UUID(uuidString: idString),
            let nameSnap = stmt.text(at: 1),
            let contentSnap = stmt.text(at: 2),
            let stateRaw = stmt.text(at: 3),
            let state = SkillState(rawValue: stateRaw)
        else {
            print("[SkillStore] skipping malformed loaded_skills row")
            continue
        }
        result.append(LoadedSkill(
            skillID: id,
            nameSnapshot: nameSnap,
            contentSnapshot: contentSnap,
            stateAtLoad: state,
            loadedAt: Date(timeIntervalSince1970: stmt.double(at: 4))
        ))
    }
    return result
}
```

(`SkillStore.nodeStore` is private; expose `internal var nodeStore: NodeStore { _nodeStore }` or test through the public API — adjust per the test helpers in the repo.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter SkillStoreLazyLoadTests_LoadedSkills`
Expected: 3 PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Models/Skill.swift Sources/Nous/Services/SkillStore.swift Tests/NousTests/SkillStoreLazyLoadTests.swift
git commit -m "feat(skillstore): add LoadedSkill / MarkSkillLoadedResult types and loadedSkills(in:)"
```

---

## Task 4: Add `markSkillLoaded` with internal `_incrementFiredCount` (no nested-lock deadlock)

**Files:**

- Modify: `Sources/Nous/Services/SkillStore.swift`
- Test: `Tests/NousTests/SkillStoreLazyLoadTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/NousTests/SkillStoreLazyLoadTests.swift`:

```swift
final class SkillStoreLazyLoadTests_MarkLoaded: XCTestCase {
    func test_markSkillLoaded_returnsInsertedAndIncrementsFiredCount() throws {
        let (store, conv, skill) = try setupConvAndSkill()
        let now = Date(timeIntervalSince1970: 100)
        let result = try store.markSkillLoaded(skillID: skill.id, in: conv, at: now)
        guard case let .inserted(loaded) = result else {
            return XCTFail("expected .inserted, got \(result)")
        }
        XCTAssertEqual(loaded.skillID, skill.id)
        XCTAssertEqual(loaded.nameSnapshot, skill.payload.name)
        XCTAssertEqual(loaded.contentSnapshot, skill.payload.action.content)
        XCTAssertEqual(loaded.stateAtLoad, .active)
        let refreshed = try XCTUnwrap(try store.fetchSkill(id: skill.id))
        XCTAssertEqual(refreshed.firedCount, skill.firedCount + 1)
        XCTAssertEqual(refreshed.lastFiredAt?.timeIntervalSince1970, 100)
    }

    func test_markSkillLoaded_isIdempotentOnDuplicateCall() throws {
        let (store, conv, skill) = try setupConvAndSkill()
        _ = try store.markSkillLoaded(skillID: skill.id, in: conv, at: Date())
        let pre = try XCTUnwrap(try store.fetchSkill(id: skill.id)).firedCount
        let result = try store.markSkillLoaded(skillID: skill.id, in: conv, at: Date())
        guard case .alreadyLoaded = result else { return XCTFail() }
        let post = try XCTUnwrap(try store.fetchSkill(id: skill.id)).firedCount
        XCTAssertEqual(pre, post, "fired_count must not increment on duplicate call")
    }

    func test_markSkillLoaded_returnsMissingSkillForUnknownId() throws {
        let (store, conv, _) = try setupConvAndSkill()
        let result = try store.markSkillLoaded(skillID: UUID(), in: conv, at: Date())
        XCTAssertEqual(result, .missingSkill)
    }

    func test_markSkillLoaded_returnsUnavailableForRetiredSkill() throws {
        let (store, conv, skill) = try setupConvAndSkill()
        try store.setSkillState(id: skill.id, state: .retired)
        let result = try store.markSkillLoaded(skillID: skill.id, in: conv, at: Date())
        XCTAssertEqual(result, .unavailable(.retired))
        XCTAssertEqual(try store.loadedSkills(in: conv).count, 0)
    }

    func test_markSkillLoaded_doesNotDeadlockOnTransaction() throws {
        // If `_incrementFiredCount` re-acquires NodeStore.NSLock from inside
        // markSkillLoaded's outer transaction, the test will hang and fail
        // by Bash-level timeout. Pass = returns within seconds.
        let (store, conv, skill) = try setupConvAndSkill()
        let result = try store.markSkillLoaded(skillID: skill.id, in: conv, at: Date())
        guard case .inserted = result else { return XCTFail() }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SkillStoreLazyLoadTests_MarkLoaded`
Expected: 5 FAIL — `markSkillLoaded` doesn't exist.

- [ ] **Step 3: Extend protocol and add implementation with split fire-count helpers**

In `Sources/Nous/Services/SkillStore.swift`:

```swift
protocol SkillStoring {
    // (existing + loadedSkills already added in Task 3)
    func markSkillLoaded(
        skillID: UUID,
        in conversationID: UUID,
        at: Date
    ) throws -> MarkSkillLoadedResult
    func unloadAllSkills(in conversationID: UUID) throws
}
```

Replace existing `incrementFiredCount` with the public/internal split:

```swift
// Public — used by external callers (none in P1; reserved).
func incrementFiredCount(id: UUID, firedAt: Date) throws {
    try nodeStore.inTransaction {
        try _incrementFiredCount(id: id, firedAt: firedAt)
    }
}

// Internal — caller MUST already hold the transaction lock.
private func _incrementFiredCount(id: UUID, firedAt: Date) throws {
    let stmt = try database.prepare("""
        UPDATE skills
        SET fired_count = fired_count + 1,
            last_fired_at = ?
        WHERE id = ?;
    """)
    try stmt.bind(firedAt.timeIntervalSince1970, at: 1)
    try stmt.bind(id.uuidString, at: 2)
    try stmt.step()
}
```

Add `markSkillLoaded`:

```swift
func markSkillLoaded(
    skillID: UUID,
    in conversationID: UUID,
    at firedAt: Date
) throws -> MarkSkillLoadedResult {
    var result: MarkSkillLoadedResult = .missingSkill
    try nodeStore.inTransaction {
        guard let skill = try _fetchSkillNoLock(id: skillID) else {
            result = .missingSkill
            return
        }
        if skill.state == .retired || skill.state == .disabled {
            result = .unavailable(skill.state)
            return
        }
        // Try to insert; if existing row is present, INSERT OR IGNORE leaves it alone.
        let insert = try database.prepare("""
            INSERT OR IGNORE INTO conversation_loaded_skills
            (conversation_id, skill_id, name_snapshot, content_snapshot, state_at_load, loaded_at)
            VALUES (?, ?, ?, ?, ?, ?);
        """)
        try insert.bind(conversationID.uuidString, at: 1)
        try insert.bind(skillID.uuidString, at: 2)
        try insert.bind(skill.payload.name, at: 3)
        try insert.bind(skill.payload.action.content, at: 4)
        try insert.bind(skill.state.rawValue, at: 5)
        try insert.bind(firedAt.timeIntervalSince1970, at: 6)
        try insert.step()
        let inserted = database.changes() > 0

        // Fetch whatever row is there (existing or just-inserted).
        let select = try database.prepare("""
            SELECT name_snapshot, content_snapshot, state_at_load, loaded_at
            FROM conversation_loaded_skills
            WHERE conversation_id = ? AND skill_id = ?;
        """)
        try select.bind(conversationID.uuidString, at: 1)
        try select.bind(skillID.uuidString, at: 2)
        guard try select.step(),
              let nameSnap = select.text(at: 0),
              let contentSnap = select.text(at: 1),
              let stateRaw = select.text(at: 2),
              let state = SkillState(rawValue: stateRaw)
        else {
            result = .missingSkill  // shouldn't happen; defensive.
            return
        }
        let loaded = LoadedSkill(
            skillID: skillID,
            nameSnapshot: nameSnap,
            contentSnapshot: contentSnap,
            stateAtLoad: state,
            loadedAt: Date(timeIntervalSince1970: select.double(at: 3))
        )

        if inserted {
            try _incrementFiredCount(id: skillID, firedAt: firedAt)
            result = .inserted(loaded)
        } else {
            result = .alreadyLoaded(loaded)
        }
    }
    return result
}

// Helper used inside the outer transaction.
private func _fetchSkillNoLock(id: UUID) throws -> Skill? {
    let stmt = try database.prepare("""
        SELECT id, user_id, payload, state, fired_count, created_at, last_modified_at, last_fired_at
        FROM skills
        WHERE id = ?;
    """)
    try stmt.bind(id.uuidString, at: 1)
    guard try stmt.step() else { return nil }
    return skill(from: stmt)
}

func unloadAllSkills(in conversationID: UUID) throws {
    try nodeStore.inTransaction {
        let stmt = try database.prepare("""
            DELETE FROM conversation_loaded_skills WHERE conversation_id = ?;
        """)
        try stmt.bind(conversationID.uuidString, at: 1)
        try stmt.step()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SkillStoreLazyLoadTests_MarkLoaded`
Expected: 5 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/SkillStore.swift Tests/NousTests/SkillStoreLazyLoadTests.swift
git commit -m "feat(skillstore): add markSkillLoaded with internal _incrementFiredCount (no nested-lock)"
```

---

## Task 5: Add `SystemPromptBlock` + retrofit `TurnSystemSlice` with backward-compat accessors

**Files:**

- Create: `Sources/Nous/Models/SystemPromptBlock.swift`
- Modify: `Sources/Nous/Models/TurnContracts.swift`
- Test: `Tests/NousTests/SystemPromptBlockTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/NousTests/SystemPromptBlockTests.swift
import XCTest
@testable import Nous

final class SystemPromptBlockTests: XCTestCase {
    func test_combinedString_concatenatesNonEmptyBlocks() {
        let blocks = [
            SystemPromptBlock(id: .anchorAndPolicies, content: "anchor", cacheControl: .ephemeral),
            SystemPromptBlock(id: .slowMemory, content: "", cacheControl: .ephemeral),
            SystemPromptBlock(id: .activeSkills, content: "active", cacheControl: .ephemeral),
            SystemPromptBlock(id: .skillIndex, content: "", cacheControl: .ephemeral),
            SystemPromptBlock(id: .volatile, content: "vol", cacheControl: nil)
        ]
        let slice = TurnSystemSlice(blocks: blocks)
        XCTAssertEqual(slice.combinedString, "anchor\n\nactive\n\nvol")
    }

    func test_stable_excludesVolatileTail() {
        let slice = TurnSystemSlice(blocks: [
            SystemPromptBlock(id: .anchorAndPolicies, content: "a", cacheControl: .ephemeral),
            SystemPromptBlock(id: .skillIndex, content: "i", cacheControl: .ephemeral),
            SystemPromptBlock(id: .volatile, content: "v", cacheControl: nil)
        ])
        XCTAssertEqual(slice.stable, "a\n\ni")
        XCTAssertEqual(slice.volatile, "v")
    }

    func test_combined_isAliasForCombinedString() {
        let slice = TurnSystemSlice(blocks: [
            SystemPromptBlock(id: .anchorAndPolicies, content: "x", cacheControl: .ephemeral)
        ])
        XCTAssertEqual(slice.combined, slice.combinedString)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SystemPromptBlockTests`
Expected: build failure — types don't exist.

- [ ] **Step 3: Create `SystemPromptBlock.swift`**

```swift
// Sources/Nous/Models/SystemPromptBlock.swift
import Foundation

enum BlockID: String, Equatable {
    case anchorAndPolicies
    case slowMemory
    case activeSkills
    case skillIndex
    case volatile
}

enum CacheControlMarker: Equatable {
    case ephemeral
}

struct SystemPromptBlock: Equatable {
    let id: BlockID
    let content: String
    let cacheControl: CacheControlMarker?
}
```

- [ ] **Step 4: Replace `TurnSystemSlice` body in `TurnContracts.swift`**

In `Sources/Nous/Models/TurnContracts.swift`, replace the existing struct (lines 9–16) with:

```swift
struct TurnSystemSlice: Equatable {
    let blocks: [SystemPromptBlock]

    /// Convenience for callers built before the block-structured rewrite.
    var combinedString: String {
        blocks.map(\.content).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Alias preserved for existing call sites (`AgentLoopExecutor`,
    /// `TurnExecutor`, etc.) that read `turnSlice.combined`.
    var combined: String { combinedString }

    /// Concatenation of cache-marked blocks only. Replaces the prior
    /// `stable: String` field consumed by `ChatTurnRunner` (Gemini cache
    /// refresh hook), `TurnExecutor`, and `QuickActionOpeningRunner`.
    var stable: String {
        blocks
            .filter { $0.cacheControl != nil }
            .map(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// The unmarked tail. Replaces the prior `volatile: String` field.
    var volatile: String {
        blocks
            .filter { $0.cacheControl == nil }
            .map(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
```

Any test factory or production call site that previously built `TurnSystemSlice(stable:..., volatile:...)` directly must now build `[SystemPromptBlock]`. The lookups via `.stable` / `.volatile` / `.combined` continue to work without further changes.

- [ ] **Step 5: Update existing call sites that constructed `TurnSystemSlice(stable:..., volatile:...)`**

Search for direct constructions:

```bash
git grep -nE 'TurnSystemSlice\(\s*stable:' Sources Tests
```

Each match becomes:

```swift
TurnSystemSlice(blocks: [
    SystemPromptBlock(id: .anchorAndPolicies, content: oldStable, cacheControl: .ephemeral),
    SystemPromptBlock(id: .volatile, content: oldVolatile, cacheControl: nil)
])
```

(This is a temporary 2-block slice. Task 6 will refine production slices to the full 5-block form. Tests can keep this minimal version.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter SystemPromptBlockTests`
Expected: PASS. Also run the full suite to catch any compile-only regressions: `swift test`.

- [ ] **Step 7: Commit**

```bash
git add Sources/Nous/Models/SystemPromptBlock.swift Sources/Nous/Models/TurnContracts.swift Tests/NousTests/SystemPromptBlockTests.swift
git add $(git grep -lE 'TurnSystemSlice\(\s*stable:' Sources Tests)
git commit -m "feat(prompt): introduce SystemPromptBlock; TurnSystemSlice keeps stable/volatile/combined accessors"
```

---

## Task 6: `PromptContextAssembler` emits 5-block slice with `ACTIVE` and `INDEX` rendering

**Files:**

- Modify: `Sources/Nous/Services/PromptContextAssembler.swift`
- Test: `Tests/NousTests/PromptContextAssemblerLazyLoadTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/NousTests/PromptContextAssemblerLazyLoadTests.swift
import XCTest
@testable import Nous

final class PromptContextAssemblerLazyLoadTests: XCTestCase {
    func test_skipsActiveSection_whenNoLoadedSkills() throws {
        let slice = try assembleSlice(loaded: [], matched: [], activeMode: .direction)
        XCTAssertFalse(slice.combinedString.contains("ACTIVE SKILLS"))
    }

    func test_rendersActiveSection_whenLoadedSkillsExist() throws {
        let loaded = [makeLoadedSkill(name: "x", content: "Direction skeleton content.")]
        let slice = try assembleSlice(loaded: loaded, matched: [], activeMode: .direction)
        XCTAssertTrue(slice.combinedString.contains("ACTIVE SKILLS"))
        XCTAssertTrue(slice.combinedString.contains("Direction skeleton content."))
        XCTAssertTrue(slice.combinedString.contains("<<skill source=user"))
    }

    func test_skipsIndex_whenActiveQuickActionModeNil() throws {
        let slice = try assembleSlice(loaded: [], matched: [makeSkill(name: "x")], activeMode: nil)
        XCTAssertFalse(slice.combinedString.contains("SKILL INDEX"))
    }

    func test_rendersIndex_whenMatchedAndModePresent() throws {
        let slice = try assembleSlice(
            loaded: [],
            matched: [makeSkill(name: "ds", useWhen: "Use when: x")],
            activeMode: .direction
        )
        XCTAssertTrue(slice.combinedString.contains("SKILL INDEX"))
        XCTAssertTrue(slice.combinedString.contains("Use when: x"))
        XCTAssertTrue(slice.combinedString.contains("call loadSkill"))
    }

    func test_indexExcludesAlreadyLoaded() throws {
        let loaded = [makeLoadedSkill(name: "ds", id: skillIDA)]
        let matched = [makeSkill(name: "ds", id: skillIDA), makeSkill(name: "df", id: skillIDB)]
        let slice = try assembleSlice(loaded: loaded, matched: matched, activeMode: .direction)
        let indexSection = sliceSection(slice.combinedString, header: "SKILL INDEX")
        XCTAssertFalse(indexSection.contains("ds:"), "loaded skill should not appear in INDEX")
        XCTAssertTrue(indexSection.contains("df:"))
    }

    func test_indexFallsBackToDescriptionWhenUseWhenNil() throws {
        let skill = makeSkill(name: "x", description: "Just a thing.", useWhen: nil)
        let slice = try assembleSlice(loaded: [], matched: [skill], activeMode: .direction)
        XCTAssertTrue(slice.combinedString.contains("Just a thing."))
    }

    func test_blockOrder_activeBeforeIndex() throws {
        let loaded = [makeLoadedSkill(name: "loaded")]
        let matched = [makeSkill(name: "matched")]
        let slice = try assembleSlice(loaded: loaded, matched: matched, activeMode: .direction)
        let activePos = slice.combinedString.range(of: "ACTIVE SKILLS")!.lowerBound
        let indexPos = slice.combinedString.range(of: "SKILL INDEX")!.lowerBound
        XCTAssertLessThan(activePos, indexPos)
    }

    func test_blockSequence_hasFourCacheMarkers_whenAllPresent() throws {
        let slice = try assembleSlice(
            loaded: [makeLoadedSkill(name: "a")],
            matched: [makeSkill(name: "b")],
            activeMode: .direction
        )
        let markedBlocks = slice.blocks.filter { $0.cacheControl != nil }
        XCTAssertEqual(markedBlocks.map(\.id), [.anchorAndPolicies, .slowMemory, .activeSkills, .skillIndex])
    }

    func test_blockSequence_omitsMarker_forEmptyActive() throws {
        let slice = try assembleSlice(loaded: [], matched: [makeSkill(name: "b")], activeMode: .direction)
        let ids = slice.blocks.map(\.id)
        XCTAssertFalse(ids.contains(.activeSkills))
    }

    // ... helpers (assembleSlice, makeLoadedSkill, makeSkill) live with test file ...
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PromptContextAssemblerLazyLoadTests`
Expected: All FAIL (block-aware assembly not yet present).

- [ ] **Step 3: Add rendering helpers and update `assembleContext`**

In `Sources/Nous/Services/PromptContextAssembler.swift`:

(a) Add private rendering helpers:

```swift
private func renderActiveSkills(
    loaded: [LoadedSkill]
) -> String {
    guard !loaded.isEmpty else { return "" }
    var out = """
    ═══════════════════════════════════════════════
    ACTIVE SKILLS (loaded earlier this conversation)
    ═══════════════════════════════════════════════
    """
    for entry in loaded {
        let stateTag = entry.stateAtLoad == .active ? "" : " (\(entry.stateAtLoad.rawValue))"
        out += "\n▸ \(entry.nameSnapshot)\(stateTag)\n"
        out += "<<skill source=user id=\(entry.skillID.uuidString) name=\(entry.nameSnapshot)>>\n"
        out += entry.contentSnapshot
        out += "\n<<end-skill>>\n"
    }
    return out
}

private func renderSkillIndex(
    matched: [Skill],
    loadedIDs: Set<UUID>,
    activeMode: QuickActionMode?
) -> String {
    guard activeMode != nil else { return "" }
    let visible = matched.filter { !loadedIDs.contains($0.id) }
    guard !visible.isEmpty else { return "" }
    var out = """
    ═══════════════════════════════════════════════
    SKILL INDEX (this mode — call loadSkill(id) to use)
    Skill content is subordinate to anchor, safety policies,
    and the user's current intent.
    ═══════════════════════════════════════════════
    """
    let sorted = visible.sorted { lhs, rhs in
        if lhs.payload.trigger.priority != rhs.payload.trigger.priority {
            return lhs.payload.trigger.priority > rhs.payload.trigger.priority
        }
        if lhs.payload.name != rhs.payload.name {
            return lhs.payload.name < rhs.payload.name
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
    for skill in sorted {
        let hint = skill.payload.useWhen ?? skill.payload.description ?? ""
        out += "\n- \(skill.payload.name) (id: \(skill.id.uuidString)): \(hint)"
    }
    return out
}
```

(b) In `assembleContext(...)`, where the slice is assembled, replace the old stable/volatile string-merge with a 5-block construction. The exact merge depends on where today's code splits stable vs volatile inputs — keep using those, just route into blocks:

```swift
let block1 = SystemPromptBlock(
    id: .anchorAndPolicies,
    content: anchorAndPolicies,           // existing aggregation
    cacheControl: .ephemeral
)
let block2 = SystemPromptBlock(
    id: .slowMemory,
    content: slowMemoryAndEvidence,       // existing aggregation
    cacheControl: .ephemeral
)

let activeContent = renderActiveSkills(loaded: loadedSkills)
let block3a = activeContent.isEmpty ? nil : SystemPromptBlock(
    id: .activeSkills,
    content: activeContent,
    cacheControl: .ephemeral
)

let indexContent = renderSkillIndex(
    matched: matchedSkills,
    loadedIDs: Set(loadedSkills.map(\.skillID)),
    activeMode: snapshot.activeQuickActionMode
)
let block3b = indexContent.isEmpty ? nil : SystemPromptBlock(
    id: .skillIndex,
    content: indexContent,
    cacheControl: .ephemeral
)

let volatileBlock = SystemPromptBlock(
    id: .volatile,
    content: volatilePayload,             // existing aggregation, no skill content
    cacheControl: nil
)

let blocks = [block1, block2, block3a, block3b, volatileBlock].compactMap { $0 }
return TurnSystemSlice(blocks: blocks)
```

`loadedSkills` is fetched via `skillStore.loadedSkills(in: conversationID)`; `matchedSkills` is the existing matcher output (unchanged). Both must be plumbed into `assembleContext` from the call site (pass `skillStore` into the assembler if not already wired).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PromptContextAssemblerLazyLoadTests`
Expected: 9 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/PromptContextAssembler.swift Tests/NousTests/PromptContextAssemblerLazyLoadTests.swift
git commit -m "feat(prompt): render ACTIVE/INDEX as cached blocks; INDEX gated on activeQuickActionMode"
```

---

## Task 7: Add `activeQuickActionMode` to `AgentToolContext` (codex v3 P1#1)

**Files:**

- Modify: `Sources/Nous/Models/Agents/AgentTool.swift`
- Modify: `Sources/Nous/Services/ChatTurnRunner.swift` (constructor call site)

- [ ] **Step 1: Add field**

In `AgentTool.swift` (around line 30):

```swift
struct AgentToolContext {
    // (existing fields)
    let conversationID: UUID
    let projectID: UUID?
    let messageID: UUID
    let readIDs: Set<UUID>

    // NEW
    let activeQuickActionMode: QuickActionMode?
}
```

- [ ] **Step 2: Update construction call sites**

In `Sources/Nous/Services/ChatTurnRunner.swift` (around line 236, where `AgentToolContext(...)` is built), pass through the active mode:

```swift
let toolContext = AgentToolContext(
    conversationID: conv.id,
    projectID: snapshot.defaultProjectId,
    messageID: turnRequest.turnId,
    readIDs: priorReadIDs,
    activeQuickActionMode: snapshot.activeQuickActionMode  // NEW
)
```

(`snapshot` is `TurnSessionSnapshot` from `TurnContracts.swift:18-24`, which already carries `activeQuickActionMode: QuickActionMode?`.)

- [ ] **Step 3: Compile + run existing tests**

Run: `swift test`
Expected: PASS — no existing test should break, since the new field is additive.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Models/Agents/AgentTool.swift Sources/Nous/Services/ChatTurnRunner.swift
git commit -m "feat(agent): plumb activeQuickActionMode into AgentToolContext"
```

---

## Task 8: `useAgentLoop = true` for every `QuickActionAgent`

**Files:**

- Modify: `Sources/Nous/Models/Agents/QuickActionAgent.swift`
- Test: `Tests/NousTests/ToolRegistryStabilityTests.swift` (new — section 1)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NousTests/ToolRegistryStabilityTests.swift
import XCTest
@testable import Nous

final class ToolRegistryStabilityTests_UseAgentLoop: XCTestCase {
    func test_everyQuickActionAgent_returnsUseAgentLoopTrue() {
        for mode in QuickActionMode.allCases {
            XCTAssertTrue(
                mode.agent().useAgentLoop,
                "\(mode) must opt into agent loop so loadSkill is reachable"
            )
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ToolRegistryStabilityTests_UseAgentLoop`
Expected: FAIL for any mode whose existing `toolNames.isEmpty == true`.

- [ ] **Step 3: Update `useAgentLoop`**

In `Sources/Nous/Models/Agents/QuickActionAgent.swift` (around line 30–44 where `useAgentLoop` is computed):

```swift
extension QuickActionAgent {
    /// Always true in P1: `loadSkill` is registered always-on, so the
    /// agent loop must run on every quick-action turn for the model to
    /// reach it. If the model issues no tool call, the loop terminates
    /// after one inference — same cost as the non-agent path.
    var useAgentLoop: Bool { true }
}
```

(If the existing definition lives directly on the protocol/type rather than an extension, edit in place.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ToolRegistryStabilityTests_UseAgentLoop`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Models/Agents/QuickActionAgent.swift Tests/NousTests/ToolRegistryStabilityTests.swift
git commit -m "feat(agent): useAgentLoop=true for every QuickActionAgent (loadSkill reachability)"
```

---

## Task 9: Update `LLMService` + `AgentLoopExecutor` to pass `[SystemPromptBlock]` and emit `cache_control`

**Files:**

- Modify: `Sources/Nous/Services/LLMService.swift` (both `callWithoutTools` and `callWithTools` signatures + serialization)
- Modify: `Sources/Nous/Services/AgentLoopExecutor.swift` (line ~60: pass blocks, not `combined`)
- Test: `Tests/NousTests/CacheWireFormatTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/NousTests/CacheWireFormatTests.swift
import XCTest
@testable import Nous

final class CacheWireFormatTests: XCTestCase {
    func test_nonToolPath_emitsFourCacheMarkers_inOrder() throws {
        let blocks = makeFiveBlockSlice()
        let body = OpenRouterRequestBuilder.body(
            system: blocks,
            messages: [.user("hi")],
            tools: nil
        )
        let systemArr = body["system"] as! [[String: Any]]
        XCTAssertEqual(systemArr.count, 5)
        let cached = systemArr.prefix(4).map { $0["cache_control"] as? [String: String] }
        XCTAssertEqual(cached.compactMap { $0 }.count, 4)
        XCTAssertNil(systemArr.last!["cache_control"])
    }

    func test_toolPath_emitsFourCacheMarkers_inOrder() throws {
        let blocks = makeFiveBlockSlice()
        let body = OpenRouterRequestBuilder.body(
            system: blocks,
            messages: [.user("hi")],
            tools: [makeStubTool()]
        )
        let systemArr = body["system"] as! [[String: Any]]
        XCTAssertEqual(systemArr.prefix(4).filter { $0["cache_control"] != nil }.count, 4)
        XCTAssertNotNil(body["tools"])
    }

    func test_toolListBytewiseStableAcrossModes() throws {
        let dirBody = OpenRouterRequestBuilder.body(
            system: makeFiveBlockSlice(),
            messages: [.user("hi")],
            tools: AgentToolRegistry.standard(/* deps */).toolDescriptors
        )
        let brnBody = OpenRouterRequestBuilder.body(
            system: makeFiveBlockSlice(),
            messages: [.user("hi")],
            tools: AgentToolRegistry.standard(/* deps */).toolDescriptors
        )
        let dirData = try JSONSerialization.data(withJSONObject: dirBody["tools"]!, options: [.sortedKeys])
        let brnData = try JSONSerialization.data(withJSONObject: brnBody["tools"]!, options: [.sortedKeys])
        XCTAssertEqual(dirData, brnData, "tool list must be byte-stable across modes")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CacheWireFormatTests`
Expected: FAIL — current builder doesn't emit `system: [...]` array form, doesn't tag `cache_control`.

- [ ] **Step 3: Update OpenRouter request body builder**

Locate the OpenRouter body builder in `Sources/Nous/Services/LLMService.swift` (around lines 469–487 / 543–550 — current code likely sets `system` as a single string).

Replace with a builder that takes `[SystemPromptBlock]` and emits the structured array:

```swift
enum OpenRouterRequestBuilder {
    static func body(
        system blocks: [SystemPromptBlock],
        messages: [LLMMessage],
        tools: [ToolDescriptor]?
    ) -> [String: Any] {
        let systemArr: [[String: Any]] = blocks.map { block in
            var entry: [String: Any] = ["type": "text", "text": block.content]
            if block.cacheControl == .ephemeral {
                entry["cache_control"] = ["type": "ephemeral"]
            }
            return entry
        }
        var body: [String: Any] = [
            "model": "anthropic/claude-sonnet-4-6",
            "system": systemArr,
            "messages": messages.map(\.openRouterDict)
        ]
        if let tools = tools {
            body["tools"] = tools.map(\.openRouterDict)
        }
        return body
    }
}
```

Update both `callWithoutTools` and `callWithTools` to call this builder. Their signatures change from `system: String` to `system: [SystemPromptBlock]`:

```swift
protocol LLMService {
    func callWithoutTools(
        system: [SystemPromptBlock],
        messages: [LLMMessage]
    ) async throws -> LLMResponse
}

protocol ToolCallingLLMService: LLMService {
    func callWithTools(
        system: [SystemPromptBlock],
        messages: [LLMMessage],
        tools: [ToolDescriptor]
    ) async throws -> LLMToolResponse
}
```

- [ ] **Step 4: Update `AgentLoopExecutor` to pass blocks**

In `Sources/Nous/Services/AgentLoopExecutor.swift` (around line 60):

```swift
// Before
let response = try await llmService.callWithTools(
    system: plan.turnSlice.combined,
    messages: messages,
    tools: registry.toolDescriptors
)

// After
let response = try await llmService.callWithTools(
    system: plan.turnSlice.blocks,
    messages: messages,
    tools: registry.toolDescriptors
)
```

Same for any `callWithoutTools` call site (e.g., in `TurnExecutor`).

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter CacheWireFormatTests`
Expected: PASS.

Also: `swift test` to confirm no compile-only regression elsewhere.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Services/LLMService.swift Sources/Nous/Services/AgentLoopExecutor.swift Tests/NousTests/CacheWireFormatTests.swift
git commit -m "feat(llm): pass SystemPromptBlock[] through both call paths; emit cache_control"
```

---

## Task 10: Drop `.subset(...)` in `ChatViewModel`; add internal mode-validation to mode-specific tools

**Files:**

- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift` (line 115)
- Modify: each mode-specific tool under `Sources/Nous/Models/Agents/Tools/*.swift` that should reject cross-mode invocation
- Test: `Tests/NousTests/ToolRegistryStabilityTests.swift` (append section)

- [ ] **Step 1: Write the failing test**

```swift
final class ToolRegistryStabilityTests_ByteStable: XCTestCase {
    func test_registry_byteIdenticalAcrossModes() async throws {
        let dir = AgentToolRegistry.standard(/* deps */).toolDescriptors
        let brn = AgentToolRegistry.standard(/* deps */).toolDescriptors  // same factory
        let dirData = try JSONEncoder.deterministic.encode(dir)
        let brnData = try JSONEncoder.deterministic.encode(brn)
        XCTAssertEqual(dirData, brnData)
    }
}
```

- [ ] **Step 2: Update `ChatViewModel`**

In `Sources/Nous/ViewModels/ChatViewModel.swift:108-115`:

```swift
// Before
let registry = AgentToolRegistry
    .standard(
        nodeStore: self.nodeStore,
        vectorStore: self.vectorStore,
        embeddingService: self.embeddingService,
        contradictionProvider: self.userMemoryService.contradictionReader
    )
    .subset(mode.agent().toolNames)

// After
let registry = AgentToolRegistry.standard(
    nodeStore: self.nodeStore,
    vectorStore: self.vectorStore,
    embeddingService: self.embeddingService,
    contradictionProvider: self.userMemoryService.contradictionReader
)
// No .subset — every mode sees the full registry. Each tool's
// `execute` is responsible for validating `context.activeQuickActionMode`.
```

- [ ] **Step 3: Add mode-validation helper to each mode-specific tool**

For every tool that previously appeared in only some `mode.agent().toolNames`, add a guard at the top of `execute`:

```swift
// Inside SomePlanModeTool.execute(...)
guard context.activeQuickActionMode == .plan else {
    return .error(.wrongMode(allowed: [.plan], current: context.activeQuickActionMode))
}
```

Define the error in `AgentTool.swift`:

```swift
enum ToolError: Error {
    case wrongMode(allowed: [QuickActionMode], current: QuickActionMode?)
    // (existing cases)
}
```

(Universal tools — search, recall, contradiction-find, and the new `loadSkill` — do NOT add this guard.)

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift Sources/Nous/Models/Agents/AgentTool.swift Sources/Nous/Models/Agents/Tools/ Tests/NousTests/ToolRegistryStabilityTests.swift
git commit -m "feat(agent): drop registry subset; tools self-validate active mode"
```

---

## Task 11: `LoadSkillToolHandler` — register `loadSkill` and implement 4-step validation

**Files:**

- Create: `Sources/Nous/Services/LoadSkillToolHandler.swift`
- Modify: `Sources/Nous/Models/Agents/AgentToolRegistry.swift` (add `loadSkill` to `.standard`)
- Modify: `Sources/Nous/Models/Agents/AgentTool.swift` (declare `loadSkill` tool descriptor)
- Test: `Tests/NousTests/LoadSkillToolHandlerTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/NousTests/LoadSkillToolHandlerTests.swift
import XCTest
@testable import Nous

final class LoadSkillToolHandlerTests: XCTestCase {
    func test_returnsLoaded_whenInCurrentIndex() async throws {
        let env = try Env.fresh(activeMode: .direction, matched: ["a"])
        let result = try await env.handler.execute(input: ["id": env.skillID("a").uuidString], context: env.context)
        let dict = try result.asDict()
        XCTAssertEqual(dict["status"] as? String, "loaded")
        XCTAssertEqual(dict["name"] as? String, "a")
        XCTAssertTrue((dict["content"] as! String).contains("<<skill source=user"))
    }

    func test_returnsAlreadyLoaded_onDuplicateCall() async throws {
        let env = try Env.fresh(activeMode: .direction, matched: ["a"])
        _ = try await env.handler.execute(input: ["id": env.skillID("a").uuidString], context: env.context)
        let result = try await env.handler.execute(input: ["id": env.skillID("a").uuidString], context: env.context)
        XCTAssertEqual(try result.asDict()["status"] as? String, "already_loaded")
    }

    func test_alreadyLoaded_shortCircuitsBeforeIndexCheck() async throws {
        // Skill loaded under direction. Now switch to brainstorm. Already-loaded
        // call must succeed even though the skill is no longer in INDEX.
        let env = try Env.fresh(activeMode: .direction, matched: ["a"])
        _ = try await env.handler.execute(input: ["id": env.skillID("a").uuidString], context: env.context)
        let env2 = env.switchedTo(.brainstorm, matched: ["b"])
        let result = try await env2.handler.execute(input: ["id": env.skillID("a").uuidString], context: env2.context)
        XCTAssertEqual(try result.asDict()["status"] as? String, "already_loaded")
    }

    func test_returnsNotInCurrentIndex_whenIdValidButOutsideMode() async throws {
        let env = try Env.fresh(activeMode: .direction, matched: ["a"], extraSkillsNotInIndex: ["b"])
        let result = try await env.handler.execute(input: ["id": env.skillID("b").uuidString], context: env.context)
        let dict = try result.asDict()
        XCTAssertEqual(dict["status"] as? String, "error")
        XCTAssertEqual(dict["code"] as? String, "not_in_current_index")
    }

    func test_returnsNotApplicable_whenActiveQuickActionModeNil() async throws {
        let env = try Env.fresh(activeMode: nil, matched: [])
        let result = try await env.handler.execute(input: ["id": UUID().uuidString], context: env.context)
        XCTAssertEqual(try result.asDict()["code"] as? String, "not_applicable")
    }

    func test_returnsNotFound_withAvailablePairs_onUnknownId() async throws {
        let env = try Env.fresh(activeMode: .direction, matched: ["a"])
        let result = try await env.handler.execute(input: ["id": UUID().uuidString], context: env.context)
        let dict = try result.asDict()
        XCTAssertEqual(dict["code"] as? String, "not_found")
        XCTAssertNotNil(dict["available"])
    }

    func test_returnsUnavailable_onRetiredSkill() async throws {
        let env = try Env.fresh(activeMode: .direction, matched: ["a"])
        try env.store.setSkillState(id: env.skillID("a"), state: .retired)
        let result = try await env.handler.execute(input: ["id": env.skillID("a").uuidString], context: env.context)
        let dict = try result.asDict()
        XCTAssertEqual(dict["code"] as? String, "unavailable")
        XCTAssertEqual(dict["reason"] as? String, "retired")
    }

    func test_wrapsContentInSkillEnvelope() async throws {
        let env = try Env.fresh(activeMode: .direction, matched: ["a"], content: "RAW")
        let result = try await env.handler.execute(input: ["id": env.skillID("a").uuidString], context: env.context)
        let content = try result.asDict()["content"] as? String ?? ""
        XCTAssertTrue(content.hasPrefix("<<skill source=user"))
        XCTAssertTrue(content.contains("RAW"))
        XCTAssertTrue(content.hasSuffix("<<end-skill>>"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LoadSkillToolHandlerTests`
Expected: All FAIL — `LoadSkillToolHandler` doesn't exist.

- [ ] **Step 3: Implement `LoadSkillToolHandler`**

```swift
// Sources/Nous/Services/LoadSkillToolHandler.swift
import Foundation

final class LoadSkillToolHandler: AgentToolHandler {
    let name = "loadSkill"
    private let skillStore: any SkillStoring
    private let skillMatcher: any SkillMatching
    private let userId: String

    init(
        skillStore: any SkillStoring,
        skillMatcher: any SkillMatching = SkillMatcher(),
        userId: String = "alex"
    ) {
        self.skillStore = skillStore
        self.skillMatcher = skillMatcher
        self.userId = userId
    }

    func execute(input: [String: Any], context: AgentToolContext) async throws -> AgentToolResult {
        // Step 1: not_applicable when no quick-action mode active.
        guard let mode = context.activeQuickActionMode else {
            return .json([
                "status": "error",
                "code": "not_applicable",
                "reason": "no SKILL INDEX rendered for this turn"
            ])
        }

        guard let idString = input["id"] as? String, let id = UUID(uuidString: idString) else {
            return .json([
                "status": "error",
                "code": "not_found",
                "reason": "missing or malformed id parameter"
            ])
        }

        // Step 2: already-loaded short-circuit (preserves cross-mode sticky).
        let loaded = try skillStore.loadedSkills(in: context.conversationID)
        if let existing = loaded.first(where: { $0.skillID == id }) {
            return .json([
                "status": "already_loaded",
                "id": existing.skillID.uuidString,
                "name": existing.nameSnapshot
            ])
        }

        // Step 3: validate id ∈ current mode's INDEX.
        let active = try skillStore.fetchActiveSkills(userId: userId)
        let matched = skillMatcher.matchingSkills(
            from: active,
            context: SkillMatchContext(mode: mode, turnIndex: 0),
            cap: 5
        )
        let eligibleIDs = Set(matched.map(\.id))
        guard eligibleIDs.contains(id) else {
            let available = matched.map { ["id": $0.id.uuidString, "name": $0.payload.name] }
            return .json([
                "status": "error",
                "code": "not_in_current_index",
                "available": available
            ])
        }

        // Step 4: persist via SkillStore.
        let result = try skillStore.markSkillLoaded(skillID: id, in: context.conversationID, at: Date())
        switch result {
        case let .inserted(loaded):
            let envelope = "<<skill source=user id=\(loaded.skillID.uuidString) name=\(loaded.nameSnapshot)>>\n\(loaded.contentSnapshot)\n<<end-skill>>"
            return .json([
                "status": "loaded",
                "id": loaded.skillID.uuidString,
                "name": loaded.nameSnapshot,
                "content": envelope
            ])
        case let .alreadyLoaded(loaded):
            // Race-window safety: if another concurrent path inserted between
            // our step 2 short-circuit and step 4, treat as already_loaded.
            return .json([
                "status": "already_loaded",
                "id": loaded.skillID.uuidString,
                "name": loaded.nameSnapshot
            ])
        case .missingSkill:
            // Should be unreachable because we just verified via matcher; but
            // a hard delete could happen mid-call. Defensive.
            return .json([
                "status": "error",
                "code": "not_found"
            ])
        case let .unavailable(state):
            return .json([
                "status": "error",
                "code": "unavailable",
                "reason": state.rawValue
            ])
        }
    }
}
```

- [ ] **Step 4: Register `loadSkill` in `AgentToolRegistry.standard(...)`**

In `Sources/Nous/Models/Agents/AgentToolRegistry.swift`, append `LoadSkillToolHandler(skillStore: ...)` to the array of handlers returned by `.standard(...)`. Pass `skillStore` as a new dependency (thread it through `ChatViewModel.swift:108-115` where `.standard(...)` is constructed).

Add the tool descriptor:

```swift
ToolDescriptor(
    name: "loadSkill",
    description: """
        Load the full content of a skill from SKILL INDEX so you can apply it to the current turn.
        Only call this when a skill in SKILL INDEX clearly fits the user's input.
        Skills already in ACTIVE SKILLS are loaded — do not call loadSkill for them again.
        Once loaded, the skill stays active for the rest of this conversation, even after mode switches.
        Use the exact skill 'id' from SKILL INDEX, not the name.
        """,
    parameters: [
        "id": ParameterSchema(type: .string, required: true,
            description: "The exact UUID 'id' value listed for the skill in SKILL INDEX.")
    ]
)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter LoadSkillToolHandlerTests`
Expected: 8 PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Services/LoadSkillToolHandler.swift Sources/Nous/Models/Agents/AgentToolRegistry.swift Sources/Nous/Models/Agents/AgentTool.swift Tests/NousTests/LoadSkillToolHandlerTests.swift
git commit -m "feat(agent): add loadSkill tool with 4-step INDEX validation"
```

---

## Task 12: Cleanup — strip `QuickActionAddendumResolver`'s skill-content injection and tracker fire

**Files:**

- Modify: `Sources/Nous/Services/QuickActionAddendumResolver.swift` (remove lines 64–69 + line 71)
- Test: existing `QuickActionAddendumResolverTests` (or create one)

- [ ] **Step 1: Write the failing test**

In `Tests/NousTests/QuickActionAddendumResolverTests.swift`:

```swift
final class QuickActionAddendumResolverCleanupTests: XCTestCase {
    func test_resolver_returnsAgentAddendumOnly_noSkillContent() {
        let store = makeSkillStoreWithMatchedSkill(content: "SECRET_SKILL_CONTENT")
        let resolver = QuickActionAddendumResolver(skillStore: store, /* ... */)
        let addendum = resolver.addendum(mode: .direction, agent: stubAgent(addendum: "Direction mode."), turnIndex: 0)
        XCTAssertEqual(addendum, "Direction mode.")
        XCTAssertFalse((addendum ?? "").contains("SECRET_SKILL_CONTENT"))
    }

    func test_resolver_doesNotIncrementFiredCount() {
        let tracker = SpySkillTracker()
        let resolver = QuickActionAddendumResolver(skillTracker: tracker, /* ... */)
        _ = resolver.addendum(mode: .direction, agent: stubAgent(addendum: nil), turnIndex: 0)
        // Allow detached tasks (if any) to complete.
        let exp = expectation(description: "wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(tracker.fireCalls, 0, "P1 removes the resolver-side fire; loadSkill is the new gate")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter QuickActionAddendumResolverCleanupTests`
Expected: FAIL — current code injects skill content and fires tracker.

- [ ] **Step 3: Strip lines 64–69 and 71**

In `Sources/Nous/Services/QuickActionAddendumResolver.swift`, replace the `resolvedSkillAddendum` body with:

```swift
private func resolvedSkillAddendum(
    mode: QuickActionMode?,
    turnIndex: Int
) -> String? {
    #if DEBUG
    if DebugAblation.skipModeAddendum {
        SkillTraceLogger.logSkipped(mode: mode, turnIndex: turnIndex, reason: "DebugAblation.skipModeAddendum")
        return nil
    }
    #endif

    // Skill content injection moved to PromptContextAssembler ACTIVE/INDEX
    // blocks (P1 lazy-load). This resolver no longer concatenates
    // payload.action.content. fired_count is now driven by markSkillLoaded.
    return nil
}
```

The outer `addendum(mode:agent:turnIndex:)` keeps its existing logic for the `agentAddendum` part — it just no longer joins `skillAddendum`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter QuickActionAddendumResolverCleanupTests`
Expected: PASS.

Also: full `swift test` to verify no other test depended on the removed skill-content injection.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/QuickActionAddendumResolver.swift Tests/NousTests/QuickActionAddendumResolverTests.swift
git commit -m "refactor(quick-actions): remove skill-content injection + tracker fire (replaced by lazy-load)"
```

---

## Task 13: Integration test — end-to-end conversation-sticky flow

**Files:**

- Test: `Tests/NousTests/SkillStoreLazyLoadIntegrationTests.swift` (new)

- [ ] **Step 1: Write the integration test**

```swift
// Tests/NousTests/SkillStoreLazyLoadIntegrationTests.swift
import XCTest
@testable import Nous

final class SkillStoreLazyLoadIntegrationTests: XCTestCase {
    func test_conversationStickyFlow() async throws {
        let env = try Env.directionMode()  // builds NodeStore + SkillStore + assembler + handler
        let conv = env.conversationID

        // Turn 1: INDEX populated, ACTIVE absent.
        let slice1 = try env.assemble(loadedIDs: [], mode: .direction)
        XCTAssertTrue(slice1.combinedString.contains("SKILL INDEX"))
        XCTAssertFalse(slice1.combinedString.contains("ACTIVE SKILLS"))

        // Simulate model invoking loadSkill.
        let dirSkillID = env.skillID(in: .direction, name: "direction-skeleton")
        let res1 = try await env.handler.execute(
            input: ["id": dirSkillID.uuidString],
            context: env.context(mode: .direction)
        )
        XCTAssertEqual(try res1.asDict()["status"] as? String, "loaded")

        let row = try env.skillStore.loadedSkills(in: conv).first { $0.skillID == dirSkillID }
        XCTAssertNotNil(row)
        let firedAfter1 = try XCTUnwrap(env.skillStore.fetchSkill(id: dirSkillID)).firedCount
        XCTAssertGreaterThan(firedAfter1, 0)

        // Turn 2: ACTIVE includes loaded skill, INDEX excludes it.
        let slice2 = try env.assemble(loadedIDs: [dirSkillID], mode: .direction)
        XCTAssertTrue(slice2.combinedString.contains("ACTIVE SKILLS"))
        XCTAssertTrue(slice2.combinedString.contains(env.skillContent(name: "direction-skeleton")))
        let block3b = slice2.blocks.first(where: { $0.id == .skillIndex })?.content ?? ""
        XCTAssertFalse(block3b.contains("direction-skeleton"))

        // Switch to brainstorm.
        let slice3 = try env.assemble(loadedIDs: [dirSkillID], mode: .brainstorm)
        XCTAssertTrue(slice3.combinedString.contains("ACTIVE SKILLS"))
        XCTAssertTrue(slice3.combinedString.contains(env.skillContent(name: "direction-skeleton")),
                      "ACTIVE persists across mode switch")

        // Re-call loadSkill — already_loaded short-circuit beats mode check.
        let res2 = try await env.handler.execute(
            input: ["id": dirSkillID.uuidString],
            context: env.context(mode: .brainstorm)
        )
        XCTAssertEqual(try res2.asDict()["status"] as? String, "already_loaded")
        let firedAfter2 = try XCTUnwrap(env.skillStore.fetchSkill(id: dirSkillID)).firedCount
        XCTAssertEqual(firedAfter2, firedAfter1, "duplicate load must not increment fired_count")

        // Mode-scope rejection: brainstorm-mode handler refuses direction-only skill that wasn't loaded.
        let directionOnlyOther = env.skillID(in: .direction, name: "another-direction-only")
        let res3 = try await env.handler.execute(
            input: ["id": directionOnlyOther.uuidString],
            context: env.context(mode: .brainstorm)
        )
        XCTAssertEqual(try res3.asDict()["code"] as? String, "not_in_current_index")

        // Hard-delete direction-skeleton from skills.
        try env.skillStore.nodeStore.rawDatabase.exec(
            "DELETE FROM skills WHERE id = '\(dirSkillID.uuidString)';"
        )
        let slice4 = try env.assemble(loadedIDs: [dirSkillID], mode: .brainstorm)
        XCTAssertTrue(slice4.combinedString.contains(env.skillContent(name: "direction-skeleton")),
                      "ACTIVE renders from snapshot even after hard-delete")

        // Drop quick action mode.
        let slice5 = try env.assemble(loadedIDs: [dirSkillID], mode: nil)
        XCTAssertFalse(slice5.combinedString.contains("SKILL INDEX"))
        XCTAssertTrue(slice5.combinedString.contains("ACTIVE SKILLS"))

        // loadSkill in nil-mode → not_applicable.
        let res4 = try await env.handler.execute(
            input: ["id": dirSkillID.uuidString],
            context: env.context(mode: nil)
        )
        XCTAssertEqual(try res4.asDict()["code"] as? String, "not_applicable")
    }
}
```

- [ ] **Step 2: Run integration test**

Run: `swift test --filter SkillStoreLazyLoadIntegrationTests`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/NousTests/SkillStoreLazyLoadIntegrationTests.swift
git commit -m "test(skillstore): integration test for conversation-sticky lazy-load flow"
```

---

## Task 14 (post-merge): Build-time backfill of `useWhen` for seed skills

> This task lives in a SEPARATE branch / PR from the implementation. Run after the main PR merges. The script reads `seed-skills.json`, calls Gemini once per skill, manual review, commits the patched seeds.

**Files:**

- Create: `scripts/backfill-skill-useWhen.swift`
- Modify: `seed-skills.json`

- [ ] **Step 1: Write the backfill script**

```swift
// scripts/backfill-skill-useWhen.swift
import Foundation

// Read seed-skills.json
let url = URL(fileURLWithPath: "seed-skills.json")
let data = try Data(contentsOf: url)
var json = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

for i in 0..<json.count {
    var skill = json[i]
    var payload = skill["payload"] as! [String: Any]
    if payload["useWhen"] != nil { continue }
    let rationale = payload["rationale"] as? String ?? ""
    let description = payload["description"] as? String ?? ""
    let modes = (payload["trigger"] as? [String: Any])?["modes"] as? [String] ?? []

    let geminiPrompt = """
    Given this skill:
    - description: \(description)
    - rationale: \(rationale)
    - applicable modes: \(modes.joined(separator: ", "))

    Write ONE concise sentence describing when the model should load this skill.
    Format: "Use when: <situation>". JSON output: {"useWhen": "..."}
    """

    let useWhen = try await callGeminiJSON(prompt: geminiPrompt)["useWhen"] as! String
    print("[\(i)] \(payload["name"] ?? ""): \(useWhen)")
    payload["useWhen"] = useWhen
    payload["payloadVersion"] = 2
    skill["payload"] = payload
    json[i] = skill

    // Manual review pause:
    print("Press enter to accept, or ctrl-c to abort.")
    _ = readLine()
}

let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
try out.write(to: url)
print("Updated seed-skills.json")
```

- [ ] **Step 2: Run the backfill**

```bash
GEMINI_API_KEY=... swift run backfill-skill-useWhen
```

Review each generated `useWhen`. Reject and rewrite by hand if Gemini's phrasing isn't right.

- [ ] **Step 3: Commit (separate from PR)**

```bash
git add scripts/backfill-skill-useWhen.swift seed-skills.json
git commit -m "chore(skills): backfill useWhen field for existing seed skills (Gemini batch + manual review)"
```

---

## Self-Review Checklist

After writing the plan, verify:

- [ ] Spec coverage: every spec section maps to ≥1 task above. Schema → Task 1, payload → Task 2, store APIs → Task 3+4, prompt blocks → Task 5+6, agent context → Task 7, useAgentLoop → Task 8, LLM cache → Task 9, registry → Task 10, handler → Task 11, cleanup → Task 12, integration → Task 13, backfill → Task 14.
- [ ] No placeholders ("TBD", "implement later", "similar to Task N").
- [ ] Type consistency: `MarkSkillLoadedResult` enum cases match in store, handler, tests. `SystemPromptBlock` field names consistent. `LoadedSkill` field names consistent across store, handler, renderer.
- [ ] Order constraint: Task 12 cleanup runs after Tasks 6 + 11 are functional (otherwise the prompt loses skill context entirely).
- [ ] Codex v3 NEW findings folded in: Task 7 adds `activeQuickActionMode` to `AgentToolContext` (P1#1); Task 9 updates `AgentLoopExecutor` and the `ToolCallingLLMService` protocol signature (P1#2); Task 5 keeps `combined` as alias for `combinedString` (P2#3).
