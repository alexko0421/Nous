# Proactive Surfacing + Interjection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the first thinking-companion feature — the orchestrator runs an LLM judge per turn, and when the judge flags tension between the user's current message and a retrieved memory entry, the main reply interjects to surface that entry. Everything else goes through the unchanged silent-memory path.

**Architecture:** Orchestration lives in `ChatViewModel.send()` (per the spec — `LLMService` stays a pure transport). New per-turn flow: assemble a `[CitableEntry]` pool via node-hit bridging over existing `memory_entries`, call a new `ProvocationJudge` with the pool + user message + chat mode, validate the verdict against the pool (fail-closed on scope-boundary), select a `BehaviorProfile` (`.supportive` / `.provocative`), compose the system prompt, log the verdict to a new SQLite `judge_events` table, then call `LLMService.generate(...)` as today.

**Tech Stack:** Swift 5.9+, XCTest, macOS target. Existing `NodeStore` SQLite wrapper (in-house, see `Database` helpers). Streaming API calls through `LLMService` protocol (already implemented for Claude / Gemini / OpenAI / Local MLX). No new external dependencies.

---

## File Structure

**New files:**

| Path | Responsibility |
|---|---|
| `Sources/Nous/Models/JudgeVerdict.swift` | `JudgeVerdict` struct, `UserState` enum, `JudgeFallbackReason` enum — the shape returned by `ProvocationJudge` |
| `Sources/Nous/Models/CitableEntry.swift` | `CitableEntry` struct — `{id, text, scope}`; the only entries the judge may cite |
| `Sources/Nous/Models/BehaviorProfile.swift` | `BehaviorProfile` enum with `.supportive` / `.provocative` cases; each has `contextBlock: String` |
| `Sources/Nous/Models/JudgeEvent.swift` | `JudgeEvent` struct — persisted row in `judge_events` table |
| `Sources/Nous/Services/ProvocationJudge.swift` | Runs one small-model LLM call, parses structured JSON, returns `JudgeVerdict` (or throws on failures that orchestrator handles) |
| `Tests/NousTests/JudgeVerdictTests.swift` | JSON round-trip and parsing edge cases for `JudgeVerdict` |
| `Tests/NousTests/CitableEntryPoolTests.swift` | Tests `UserMemoryService.citableEntryPool(...)` node-hit bridging |
| `Tests/NousTests/ProvocationJudgeTests.swift` | Unit tests for judge: prompt composition, JSON parsing, timeout, cancellation |
| `Tests/NousTests/JudgeEventsStoreTests.swift` | Round-trip append/query/filter for `judge_events` table |
| `Tests/NousTests/ProvocationOrchestrationTests.swift` | Integration tests through `ChatViewModel.send()` with injected fake judge + fake LLM |
| `Tests/NousTests/Fixtures/ProvocationScenarios/` | Directory holding fixture JSONs for judgment-quality regression runs (PR 6) |
| `scripts/run_provocation_fixtures.sh` | Human-runnable shell script that re-runs the judge against the fixture bank and diffs against expected shape |

**Modified files:**

| Path | What changes |
|---|---|
| `Sources/Nous/Services/NodeStore.swift` | Add `judge_events` table to `createTables()`; add append/fetch/update helpers + `fetchMemoryEntries(withSourceNodeId:)` reverse-lookup |
| `Sources/Nous/Services/GovernanceTelemetryStore.swift` | Extend to accept a `NodeStore` reference; add `appendJudgeEvent`, `recordFeedback`, `recentJudgeEvents` methods |
| `Sources/Nous/Services/UserMemoryService.swift` | Add `citableEntryPool(projectId:conversationId:query:hits:)` method |
| `Sources/Nous/ViewModels/ChatViewModel.swift` | Extend `send()` to assemble pool, call judge, validate verdict, select profile, compose focus block, log event; add provider accessor injection; implement in-flight cancellation |
| `Sources/Nous/App/ContentView.swift` | Wire provider accessor closure and the extended telemetry store into `ChatViewModel` init |
| `Sources/Nous/Views/MemoryDebugInspector.swift` | Add new tab showing recent judge verdicts with filter controls |
| `Sources/Nous/Views/ChatArea.swift` | Add 👍 / 👎 feedback buttons on provoked assistant messages |

**No-change files (explicitly preserved):**

- `Sources/Nous/Services/LLMService.swift` — stays a pure provider transport. All four concrete `LLMService` implementations are untouched.
- `Sources/Nous/Models/ChatMode.swift` — the enum is unchanged structurally; we merely pass it to the judge as an input.
- `Sources/Nous/Models/MemoryEntry.swift` — the `sourceNodeIds` field is already plural, no schema change.

---

## PR Structure

This plan ships as six stacked PRs. PR 4 is the first PR that produces any user-visible change — everything before that is foundation.

1. **PR 1 — Foundations.** Types + `judge_events` SQLite table + `GovernanceTelemetryStore` event log. No behavior change.
2. **PR 2 — CitableEntryPool.** `UserMemoryService.citableEntryPool(...)` via node-hit bridging. No behavior change.
3. **PR 3 — ProvocationJudge.** The judge itself, testable in isolation. No wiring yet.
4. **PR 4 — Orchestration wiring.** `ChatViewModel.send()` starts calling the judge. **First user-visible change** — interjections begin.
5. **PR 5 — Feedback UI + Inspector.** 👍/👎 on provoked messages + review panel in `MemoryDebugInspector`.
6. **PR 6 — Fixture bank.** Judgment-quality regression harness for prompt iteration.

PRs 1–3 can be reviewed and merged independently. PR 4 requires all three. PR 5 requires PR 4. PR 6 requires PR 3.

---

## PR 1 — Foundations

### Task 1.1: Add `JudgeVerdict` model

**Files:**
- Create: `Sources/Nous/Models/JudgeVerdict.swift`
- Test: `Tests/NousTests/JudgeVerdictTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NousTests/JudgeVerdictTests.swift
import XCTest
@testable import Nous

final class JudgeVerdictTests: XCTestCase {

    func testDecodesWellFormedJSON() throws {
        let json = """
        {
          "tension_exists": true,
          "user_state": "deciding",
          "should_provoke": true,
          "entry_id": "ABCD-1234",
          "reason": "User is choosing pricing; prior entry explicitly rejected price competition."
        }
        """.data(using: .utf8)!

        let verdict = try JSONDecoder().decode(JudgeVerdict.self, from: json)

        XCTAssertTrue(verdict.tensionExists)
        XCTAssertEqual(verdict.userState, .deciding)
        XCTAssertTrue(verdict.shouldProvoke)
        XCTAssertEqual(verdict.entryId, "ABCD-1234")
        XCTAssertTrue(verdict.reason.contains("pricing"))
    }

    func testDecodesNullEntryId() throws {
        let json = """
        {
          "tension_exists": false,
          "user_state": "venting",
          "should_provoke": false,
          "entry_id": null,
          "reason": "Venting — no interjection."
        }
        """.data(using: .utf8)!

        let verdict = try JSONDecoder().decode(JudgeVerdict.self, from: json)
        XCTAssertNil(verdict.entryId)
        XCTAssertEqual(verdict.userState, .venting)
        XCTAssertFalse(verdict.shouldProvoke)
    }

    func testRejectsUnknownUserState() {
        let json = """
        { "tension_exists": false, "user_state": "bogus",
          "should_provoke": false, "entry_id": null, "reason": "x" }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(JudgeVerdict.self, from: json))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/JudgeVerdictTests -quiet
```

Expected: Compilation failure — `JudgeVerdict` does not exist.

- [ ] **Step 3: Implement the model**

```swift
// Sources/Nous/Models/JudgeVerdict.swift
import Foundation

enum UserState: String, Codable {
    case deciding
    case exploring
    case venting
}

enum JudgeFallbackReason: String, Codable {
    case ok
    case timeout
    case apiError = "api_error"
    case badJSON = "bad_json"
    case unknownEntryId = "unknown_entry_id"
    case providerLocal = "provider_local"
    case judgeUnavailable = "judge_unavailable"  // judge LLM factory returned nil (missing API key, etc.)
}

struct JudgeVerdict: Codable, Equatable {
    let tensionExists: Bool
    let userState: UserState
    let shouldProvoke: Bool
    let entryId: String?
    let reason: String

    enum CodingKeys: String, CodingKey {
        case tensionExists = "tension_exists"
        case userState = "user_state"
        case shouldProvoke = "should_provoke"
        case entryId = "entry_id"
        case reason
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/JudgeVerdictTests -quiet
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Models/JudgeVerdict.swift \
        Tests/NousTests/JudgeVerdictTests.swift
git commit -m "feat(provocation): add JudgeVerdict, UserState, JudgeFallbackReason models"
```

---

### Task 1.2: Add `CitableEntry` model

**Files:**
- Create: `Sources/Nous/Models/CitableEntry.swift`

- [ ] **Step 1: Write the model directly** (a pure value type with no logic — a separate unit test would only assert Codable conformance the compiler already guarantees. No test file needed for this task; coverage comes via `CitableEntryPoolTests` in PR 2.)

```swift
// Sources/Nous/Models/CitableEntry.swift
import Foundation

/// The only entry shape the judge may cite. Built by `UserMemoryService.citableEntryPool(...)`
/// from raw `memory_entries` via node-hit bridging. The judge sees `id` + `text`; `scope`
/// is carried for telemetry and scope-boundary debugging, but the judge prompt does not
/// surface it.
struct CitableEntry: Equatable {
    let id: String
    let text: String
    let scope: MemoryScope
}
```

- [ ] **Step 2: Verify the project still compiles**

```bash
xcodebuild build -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' -quiet
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Models/CitableEntry.swift
git commit -m "feat(provocation): add CitableEntry type"
```

---

### Task 1.3: Add `BehaviorProfile` enum (placeholder text)

**Files:**
- Create: `Sources/Nous/Models/BehaviorProfile.swift`
- Test: `Tests/NousTests/JudgeVerdictTests.swift` (extended with profile-selection helper tests)

PR 6 replaces the `contextBlock` strings with the final provocative/supportive voice. For this task we land a working shape with minimal placeholder text so the orchestration in PR 4 can compile and run end-to-end.

- [ ] **Step 1: Write the failing test** (append to `JudgeVerdictTests.swift`)

```swift
// Append to Tests/NousTests/JudgeVerdictTests.swift

func testBehaviorProfileContextBlocksAreNonEmpty() {
    XCTAssertFalse(BehaviorProfile.supportive.contextBlock.isEmpty)
    XCTAssertFalse(BehaviorProfile.provocative.contextBlock.isEmpty)
    XCTAssertNotEqual(
        BehaviorProfile.supportive.contextBlock,
        BehaviorProfile.provocative.contextBlock
    )
}

func testProfileFromVerdictRespectsShouldProvoke() {
    let provokingVerdict = JudgeVerdict(
        tensionExists: true, userState: .deciding,
        shouldProvoke: true, entryId: "x", reason: "r"
    )
    XCTAssertEqual(BehaviorProfile(verdict: provokingVerdict), .provocative)

    let quietVerdict = JudgeVerdict(
        tensionExists: false, userState: .venting,
        shouldProvoke: false, entryId: nil, reason: "r"
    )
    XCTAssertEqual(BehaviorProfile(verdict: quietVerdict), .supportive)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/JudgeVerdictTests -quiet
```

Expected: Compilation failure — `BehaviorProfile` does not exist.

- [ ] **Step 3: Implement the enum**

```swift
// Sources/Nous/Models/BehaviorProfile.swift
import Foundation

/// A swappable per-turn behavior block selected by the `ProvocationJudge`.
/// Sits between the summary context and the (optional) focus block in the
/// composed system prompt. See spec:
/// docs/superpowers/specs/2026-04-17-proactive-surfacing-design.md
enum BehaviorProfile: String, Equatable {
    case supportive
    case provocative

    /// Final wording is iterated in PR 6 once PR 4 is live and telemetry
    /// is flowing. These initial strings are intentionally short and safe.
    var contextBlock: String {
        switch self {
        case .supportive:
            return """
            BEHAVIOR: SUPPORTIVE
            Use retrieved memory silently to inform your reply.
            Do not interrupt the user to call out contradictions or relevant prior ideas in this turn.
            Stay in the tone set by the active ChatMode.
            """
        case .provocative:
            return """
            BEHAVIOR: PROVOCATIVE
            There is a specific prior memory worth calling out this turn (see the RELEVANT PRIOR MEMORY block that follows this one).
            Acknowledge Alex's current point briefly.
            Surface the referenced prior memory: quote a key line faithfully if one exists, otherwise paraphrase tightly — never reword it into a summary.
            Name the tension in plain language. Ask one short clarifying question or invite Alex to reconcile the two.
            Do not lecture or moralize. Stay in the tone set by the active ChatMode (softer under companion, sharper under strategist).
            """
        }
    }

    /// Maps a verdict to the profile the orchestrator should apply for this turn.
    init(verdict: JudgeVerdict) {
        self = verdict.shouldProvoke ? .provocative : .supportive
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/JudgeVerdictTests -quiet
```

Expected: all tests (previous 3 + new 2 = 5) pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Models/BehaviorProfile.swift \
        Tests/NousTests/JudgeVerdictTests.swift
git commit -m "feat(provocation): add BehaviorProfile enum with supportive/provocative cases"
```

---

### Task 1.4: Add `judge_events` table to `NodeStore`

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift` (`createTables()` around line 159)
- Create: `Sources/Nous/Models/JudgeEvent.swift`
- Test: `Tests/NousTests/JudgeEventsStoreTests.swift`

- [ ] **Step 1: Write the `JudgeEvent` model**

```swift
// Sources/Nous/Models/JudgeEvent.swift
import Foundation

enum JudgeFeedback: String, Codable {
    case up
    case down
}

/// One row in the `judge_events` SQLite table. Append-once, feedback can be patched in later
/// via `GovernanceTelemetryStore.recordFeedback(eventId:feedback:)`.
struct JudgeEvent: Identifiable, Equatable {
    let id: UUID
    let ts: Date
    let nodeId: UUID
    /// nil if the judge failed before a reply was produced, or if the turn is still mid-flight.
    var messageId: UUID?
    let chatMode: ChatMode
    let provider: LLMProvider
    /// Full verdict as emitted by the judge, JSON-encoded. Kept as a blob so future fields
    /// added to `JudgeVerdict` are forward-compatible without schema migrations.
    let verdictJSON: String
    let fallbackReason: JudgeFallbackReason
    var userFeedback: JudgeFeedback?
    var feedbackTs: Date?
}
```

- [ ] **Step 2: Write the failing test**

```swift
// Tests/NousTests/JudgeEventsStoreTests.swift
import XCTest
@testable import Nous

final class JudgeEventsStoreTests: XCTestCase {

    var store: NodeStore!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func makeEvent(
        id: UUID = UUID(),
        ts: Date = Date(),
        nodeId: UUID = UUID(),
        fallback: JudgeFallbackReason = .ok
    ) -> JudgeEvent {
        let verdict = JudgeVerdict(
            tensionExists: fallback == .ok,
            userState: .exploring,
            shouldProvoke: fallback == .ok,
            entryId: fallback == .ok ? UUID().uuidString : nil,
            reason: "test"
        )
        let verdictJSON = String(data: try! JSONEncoder().encode(verdict), encoding: .utf8)!
        return JudgeEvent(
            id: id, ts: ts, nodeId: nodeId, messageId: nil,
            chatMode: .companion, provider: .claude,
            verdictJSON: verdictJSON, fallbackReason: fallback,
            userFeedback: nil, feedbackTs: nil
        )
    }

    func testAppendAndFetchRoundTrip() throws {
        let event = makeEvent()
        try store.appendJudgeEvent(event)

        let fetched = try store.fetchJudgeEvent(id: event.id)
        XCTAssertEqual(fetched?.id, event.id)
        XCTAssertEqual(fetched?.chatMode, .companion)
        XCTAssertEqual(fetched?.provider, .claude)
        XCTAssertEqual(fetched?.fallbackReason, .ok)
    }

    func testRecentJudgeEventsReturnsNewestFirst() throws {
        // Use explicit monotonic timestamps — two Date() calls in quick succession can be equal
        // on some hardware, and "ORDER BY ts DESC" doesn't guarantee insertion order within a tie.
        let baseTs = Date()
        let ids = (0..<3).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            try store.appendJudgeEvent(makeEvent(
                id: id,
                ts: baseTs.addingTimeInterval(TimeInterval(i))
            ))
        }
        let recent = try store.recentJudgeEvents(limit: 10, filter: .none)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.map(\.id), ids.reversed())
    }

    func testRecentJudgeEventsFiltersByFallback() throws {
        try store.appendJudgeEvent(makeEvent(fallback: .ok))
        try store.appendJudgeEvent(makeEvent(fallback: .timeout))
        try store.appendJudgeEvent(makeEvent(fallback: .badJSON))

        let okOnly = try store.recentJudgeEvents(limit: 10, filter: .fallback(.ok))
        XCTAssertEqual(okOnly.count, 1)
        XCTAssertEqual(okOnly.first?.fallbackReason, .ok)
    }

    func testUpdateFeedbackPersists() throws {
        let event = makeEvent()
        try store.appendJudgeEvent(event)
        try store.updateJudgeEventFeedback(id: event.id, feedback: .down, at: Date())

        let fetched = try store.fetchJudgeEvent(id: event.id)
        XCTAssertEqual(fetched?.userFeedback, .down)
        XCTAssertNotNil(fetched?.feedbackTs)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/JudgeEventsStoreTests -quiet
```

Expected: Compilation failure — `appendJudgeEvent` et al. don't exist on `NodeStore`.

- [ ] **Step 4: Extend `NodeStore.createTables()` with the new table**

Insert this block inside `createTables()` in `NodeStore.swift`, after the existing `memory_entries` table creation (around line 150, before the `// Indexes` comment):

```swift
// judge_events — append-only per-turn verdict log. Feedback columns patched
// after the fact. verdict_json kept as a blob so adding fields to
// JudgeVerdict doesn't require a schema migration.
try db.exec("""
    CREATE TABLE IF NOT EXISTS judge_events (
        id              TEXT PRIMARY KEY,
        ts              REAL NOT NULL,
        nodeId          TEXT NOT NULL,
        messageId       TEXT,
        chatMode        TEXT NOT NULL,
        provider        TEXT NOT NULL,
        verdictJSON     TEXT NOT NULL,
        fallbackReason  TEXT NOT NULL,
        userFeedback    TEXT,
        feedbackTs      REAL
    );
""")
```

And add these indexes in the existing `// Indexes` block:

```swift
try db.exec("CREATE INDEX IF NOT EXISTS idx_judge_events_ts ON judge_events(ts);")
try db.exec("CREATE INDEX IF NOT EXISTS idx_judge_events_fallback ON judge_events(fallbackReason);")
```

- [ ] **Step 5: Add append/fetch/filter helpers in `NodeStore.swift`**

Add a new `// MARK: - Judge Events` section at the end of the file (before the final closing brace):

```swift
// MARK: - Judge Events

enum JudgeEventFilter: Equatable {
    case none
    case fallback(JudgeFallbackReason)
    case shouldProvoke(Bool)
    case userState(UserState)
}

extension NodeStore {

    func appendJudgeEvent(_ event: JudgeEvent) throws {
        let stmt = try db.prepare("""
            INSERT INTO judge_events
              (id, ts, nodeId, messageId, chatMode, provider,
               verdictJSON, fallbackReason, userFeedback, feedbackTs)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        try stmt.bind(event.id.uuidString, at: 1)
        try stmt.bind(event.ts.timeIntervalSince1970, at: 2)
        try stmt.bind(event.nodeId.uuidString, at: 3)
        try stmt.bind(event.messageId?.uuidString, at: 4)
        try stmt.bind(event.chatMode.rawValue, at: 5)
        try stmt.bind(event.provider.rawValue, at: 6)
        try stmt.bind(event.verdictJSON, at: 7)
        try stmt.bind(event.fallbackReason.rawValue, at: 8)
        try stmt.bind(event.userFeedback?.rawValue, at: 9)
        try stmt.bind(event.feedbackTs?.timeIntervalSince1970, at: 10)
        try stmt.step()
    }

    func fetchJudgeEvent(id: UUID) throws -> JudgeEvent? {
        let stmt = try db.prepare("""
            SELECT id, ts, nodeId, messageId, chatMode, provider,
                   verdictJSON, fallbackReason, userFeedback, feedbackTs
            FROM judge_events
            WHERE id = ?
            LIMIT 1;
        """)
        try stmt.bind(id.uuidString, at: 1)
        guard try stmt.step() else { return nil }
        return judgeEventFrom(stmt)
    }

    func recentJudgeEvents(limit: Int, filter: JudgeEventFilter) throws -> [JudgeEvent] {
        let whereClause: String
        switch filter {
        case .none:
            whereClause = ""
        case .fallback:
            whereClause = "WHERE fallbackReason = ?"
        case .shouldProvoke:
            whereClause = "WHERE json_extract(verdictJSON, '$.should_provoke') = ?"
        case .userState:
            whereClause = "WHERE json_extract(verdictJSON, '$.user_state') = ?"
        }
        let stmt = try db.prepare("""
            SELECT id, ts, nodeId, messageId, chatMode, provider,
                   verdictJSON, fallbackReason, userFeedback, feedbackTs
            FROM judge_events
            \(whereClause)
            ORDER BY ts DESC
            LIMIT ?;
        """)
        switch filter {
        case .none:
            try stmt.bind(Int64(limit), at: 1)
        case .fallback(let reason):
            try stmt.bind(reason.rawValue, at: 1)
            try stmt.bind(Int64(limit), at: 2)
        case .shouldProvoke(let flag):
            try stmt.bind(flag ? 1 : 0, at: 1)
            try stmt.bind(Int64(limit), at: 2)
        case .userState(let state):
            try stmt.bind(state.rawValue, at: 1)
            try stmt.bind(Int64(limit), at: 2)
        }
        var out: [JudgeEvent] = []
        while try stmt.step() {
            if let ev = judgeEventFrom(stmt) { out.append(ev) }
        }
        return out
    }

    func updateJudgeEventFeedback(id: UUID, feedback: JudgeFeedback, at ts: Date) throws {
        let stmt = try db.prepare("""
            UPDATE judge_events
            SET userFeedback = ?, feedbackTs = ?
            WHERE id = ?;
        """)
        try stmt.bind(feedback.rawValue, at: 1)
        try stmt.bind(ts.timeIntervalSince1970, at: 2)
        try stmt.bind(id.uuidString, at: 3)
        try stmt.step()
    }

    private func judgeEventFrom(_ stmt: Statement) -> JudgeEvent? {
        guard let idStr = stmt.text(at: 0), let id = UUID(uuidString: idStr),
              let nodeIdStr = stmt.text(at: 2), let nodeId = UUID(uuidString: nodeIdStr),
              let chatModeStr = stmt.text(at: 4), let chatMode = ChatMode(rawValue: chatModeStr),
              let providerStr = stmt.text(at: 5), let provider = LLMProvider(rawValue: providerStr),
              let verdictJSON = stmt.text(at: 6),
              let fallbackStr = stmt.text(at: 7), let fallback = JudgeFallbackReason(rawValue: fallbackStr)
        else { return nil }
        let messageId = stmt.text(at: 3).flatMap(UUID.init(uuidString:))
        let feedback = stmt.text(at: 8).flatMap(JudgeFeedback.init(rawValue:))
        let feedbackTs = stmt.isNull(at: 9) ? nil : Date(timeIntervalSince1970: stmt.double(at: 9))
        return JudgeEvent(
            id: id,
            ts: Date(timeIntervalSince1970: stmt.double(at: 1)),
            nodeId: nodeId,
            messageId: messageId,
            chatMode: chatMode,
            provider: provider,
            verdictJSON: verdictJSON,
            fallbackReason: fallback,
            userFeedback: feedback,
            feedbackTs: feedbackTs
        )
    }
}
```

> **Note:** If `Statement.isNull(at:)` does not exist in the in-house `Database` wrapper, use `stmt.double(at: 9)` with a guard (epoch 0 → nil) or add a minimal `isNull` helper alongside. Check `Sources/Nous/Services/Database.swift` before writing this helper; match its existing accessor style.

- [ ] **Step 6: Run tests to verify they pass**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/JudgeEventsStoreTests -quiet
```

Expected: 4 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/Nous/Models/JudgeEvent.swift \
        Sources/Nous/Services/NodeStore.swift \
        Tests/NousTests/JudgeEventsStoreTests.swift
git commit -m "feat(telemetry): add judge_events SQLite table + NodeStore helpers"
```

---

### Task 1.5: Extend `GovernanceTelemetryStore` with judge-event API

**Files:**
- Modify: `Sources/Nous/Services/GovernanceTelemetryStore.swift`
- Test: append to `Tests/NousTests/JudgeEventsStoreTests.swift`

- [ ] **Step 1: Write the failing test** (append to `JudgeEventsStoreTests.swift`)

```swift
// Append to Tests/NousTests/JudgeEventsStoreTests.swift

func testGovernanceStoreDelegatesToNodeStore() throws {
    let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    let telemetry = GovernanceTelemetryStore(defaults: defaults, nodeStore: store)

    let event = makeEvent()
    telemetry.appendJudgeEvent(event)

    let fetched = try store.fetchJudgeEvent(id: event.id)
    XCTAssertEqual(fetched?.id, event.id)

    telemetry.recordFeedback(eventId: event.id, feedback: .up)
    XCTAssertEqual(try store.fetchJudgeEvent(id: event.id)?.userFeedback, .up)
}

func testGovernanceStoreExposesRecentEvents() throws {
    let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    let telemetry = GovernanceTelemetryStore(defaults: defaults, nodeStore: store)

    telemetry.appendJudgeEvent(makeEvent(fallback: .ok))
    telemetry.appendJudgeEvent(makeEvent(fallback: .timeout))

    let events = telemetry.recentJudgeEvents(limit: 10, filter: .none)
    XCTAssertEqual(events.count, 2)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/JudgeEventsStoreTests -quiet
```

Expected: Compilation failure — `GovernanceTelemetryStore` has no `nodeStore` parameter and no judge-event methods.

- [ ] **Step 3: Extend `GovernanceTelemetryStore.swift`**

Change the file to this shape (preserving existing counter methods unchanged):

```swift
import Foundation

final class GovernanceTelemetryStore {
    private let defaults: UserDefaults
    private let nodeStore: NodeStore?

    private enum Keys {
        static let lastPromptTrace = "nous.governance.lastPromptTrace"
        static func counter(_ counter: EvalCounter) -> String {
            "nous.governance.counter.\(counter.rawValue)"
        }
        static let memoryStorageSuppressedCount = "nous.governance.memoryStorageSuppressedCount"
    }

    init(defaults: UserDefaults = .standard, nodeStore: NodeStore? = nil) {
        self.defaults = defaults
        self.nodeStore = nodeStore
    }

    // MARK: - Existing UserDefaults-backed API (unchanged)

    var lastPromptTrace: PromptGovernanceTrace? {
        guard let data = defaults.data(forKey: Keys.lastPromptTrace) else { return nil }
        return try? JSONDecoder().decode(PromptGovernanceTrace.self, from: data)
    }

    func recordPromptTrace(_ trace: PromptGovernanceTrace) {
        if let data = try? JSONEncoder().encode(trace) {
            defaults.set(data, forKey: Keys.lastPromptTrace)
        }
        if trace.promptLayers.contains(where: { $0 != "anchor" && $0 != "core_safety_policy" }) {
            increment(.memoryUsefulness)
        }
        if trace.highRiskQueryDetected && !trace.safetyPolicyInvoked {
            increment(.safetyMissRate)
        }
    }

    func increment(_ counter: EvalCounter, by amount: Int = 1) {
        let key = Keys.counter(counter)
        defaults.set(defaults.integer(forKey: key) + amount, forKey: key)
    }

    func value(for counter: EvalCounter) -> Int {
        defaults.integer(forKey: Keys.counter(counter))
    }

    func recordMemoryStorageSuppressed() {
        defaults.set(defaults.integer(forKey: Keys.memoryStorageSuppressedCount) + 1, forKey: Keys.memoryStorageSuppressedCount)
    }

    func memoryStorageSuppressedCount() -> Int {
        defaults.integer(forKey: Keys.memoryStorageSuppressedCount)
    }

    // MARK: - Judge event API (SQLite-backed)

    /// Append a judge verdict event. Silently no-op if nodeStore wasn't injected
    /// (e.g. pre-wiring unit tests); orchestrator and production always pass one.
    func appendJudgeEvent(_ event: JudgeEvent) {
        guard let nodeStore else { return }
        do { try nodeStore.appendJudgeEvent(event) }
        catch { print("[governance] failed to append judge event: \(error)") }
    }

    /// Patch a previously-appended event with the user's 👍/👎 feedback.
    func recordFeedback(eventId: UUID, feedback: JudgeFeedback) {
        guard let nodeStore else { return }
        do { try nodeStore.updateJudgeEventFeedback(id: eventId, feedback: feedback, at: Date()) }
        catch { print("[governance] failed to update feedback: \(error)") }
    }

    /// For the inspector review panel and ad-hoc debugging.
    func recentJudgeEvents(limit: Int, filter: JudgeEventFilter) -> [JudgeEvent] {
        guard let nodeStore else { return [] }
        return (try? nodeStore.recentJudgeEvents(limit: limit, filter: filter)) ?? []
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/JudgeEventsStoreTests -quiet
```

Expected: 6 tests pass (4 store-level + 2 telemetry-facade).

- [ ] **Step 5: Update `ContentView` to pass `nodeStore` into `GovernanceTelemetryStore`**

Find the two places in `Sources/Nous/App/ContentView.swift` where `GovernanceTelemetryStore(defaults: ...)` is constructed and add the `nodeStore:` argument. (Grep: `GovernanceTelemetryStore\(`.) If `GovernanceTelemetryStore()` is called with no args anywhere, add `nodeStore: nodeStore` next to the `defaults:` argument — otherwise the compiler has inferred the default `nil` and judge events silently vanish.

After the change, build:

```bash
xcodebuild build -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' -quiet
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Services/GovernanceTelemetryStore.swift \
        Sources/Nous/App/ContentView.swift \
        Tests/NousTests/JudgeEventsStoreTests.swift
git commit -m "feat(telemetry): extend GovernanceTelemetryStore with judge event API"
```

---

### Task 1.6: PR 1 final check + open PR

- [ ] **Step 1: Run the full test suite**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' -quiet
```

Expected: all tests pass (existing + new JudgeVerdict + JudgeEvents).

- [ ] **Step 2: Push and open PR**

```bash
git push -u origin HEAD
gh pr create --title "feat(provocation): PR 1 — foundation types + judge_events table" \
  --body "$(cat <<'EOF'
First of 6 stacked PRs for proactive surfacing (spec: docs/superpowers/specs/2026-04-17-proactive-surfacing-design.md).

## Summary
- New models: JudgeVerdict, UserState, JudgeFallbackReason, CitableEntry, BehaviorProfile, JudgeEvent
- New SQLite table judge_events + NodeStore append/fetch/filter/update helpers
- GovernanceTelemetryStore extended with appendJudgeEvent / recordFeedback / recentJudgeEvents
- No user-visible behavior change

## Test plan
- [ ] JudgeVerdictTests — JSON round-trip, unknown user_state rejected, profile selection
- [ ] JudgeEventsStoreTests — append/fetch/filter/feedback round-trip through both NodeStore and GovernanceTelemetryStore
- [ ] Full suite still green
EOF
)"
```

---

## PR 2 — CitableEntryPool

### Task 2.1: Add reverse lookup on `NodeStore` — `fetchMemoryEntries(withSourceNodeId:)`

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift`
- Test: append to `Tests/NousTests/NodeStoreTests.swift`

`memory_entries.sourceNodeIds` is stored as a JSON array text (`encodeSourceNodeIds` in the existing insert helper). We query it with SQLite's `json_each` extension.

- [ ] **Step 1: Write the failing test** (append to `NodeStoreTests.swift`)

```swift
// Append to Tests/NousTests/NodeStoreTests.swift

func testFetchMemoryEntriesWithSourceNodeId() throws {
    let nodeA = UUID()
    let nodeB = UUID()

    let entry1 = MemoryEntry(
        scope: .global, kind: .preference, stability: .stable,
        content: "E1", sourceNodeIds: [nodeA]
    )
    let entry2 = MemoryEntry(
        scope: .project, scopeRefId: UUID(), kind: .thread, stability: .temporary,
        content: "E2", sourceNodeIds: [nodeA, nodeB]
    )
    let entry3 = MemoryEntry(
        scope: .conversation, scopeRefId: UUID(), kind: .temporaryContext, stability: .temporary,
        content: "E3", sourceNodeIds: [nodeB]
    )
    try store.insertMemoryEntry(entry1)
    try store.insertMemoryEntry(entry2)
    try store.insertMemoryEntry(entry3)

    let hitsA = try store.fetchMemoryEntries(withSourceNodeId: nodeA)
    XCTAssertEqual(Set(hitsA.map(\.id)), Set([entry1.id, entry2.id]))

    let hitsB = try store.fetchMemoryEntries(withSourceNodeId: nodeB)
    XCTAssertEqual(Set(hitsB.map(\.id)), Set([entry2.id, entry3.id]))

    let hitsUnknown = try store.fetchMemoryEntries(withSourceNodeId: UUID())
    XCTAssertTrue(hitsUnknown.isEmpty)
}

func testFetchMemoryEntriesWithSourceNodeIdIgnoresNonActive() throws {
    let nodeA = UUID()
    var entry = MemoryEntry(
        scope: .global, kind: .preference, stability: .stable,
        content: "E", sourceNodeIds: [nodeA]
    )
    try store.insertMemoryEntry(entry)
    entry.status = .superseded
    try store.updateMemoryEntry(entry)

    let hits = try store.fetchMemoryEntries(withSourceNodeId: nodeA, activeOnly: true)
    XCTAssertTrue(hits.isEmpty)

    let allHits = try store.fetchMemoryEntries(withSourceNodeId: nodeA, activeOnly: false)
    XCTAssertEqual(allHits.count, 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/NodeStoreTests/testFetchMemoryEntriesWithSourceNodeId \
  -only-testing:NousTests/NodeStoreTests/testFetchMemoryEntriesWithSourceNodeIdIgnoresNonActive \
  -quiet
```

Expected: Compilation failure — `fetchMemoryEntries(withSourceNodeId:)` doesn't exist.

- [ ] **Step 3: Implement the reverse lookup**

Add next to the existing `fetchMemoryEntries()` method in `NodeStore.swift`:

```swift
/// Reverse lookup: all memory_entries whose `sourceNodeIds` JSON array contains the given node id.
/// Backs the Citable Pool's node-hit bridging path. Defaults to active-only rows (v2.2 invariant).
func fetchMemoryEntries(withSourceNodeId nodeId: UUID, activeOnly: Bool = true) throws -> [MemoryEntry] {
    let activeClause = activeOnly ? "AND status = 'active'" : ""
    let stmt = try db.prepare("""
        SELECT id, scope, scopeRefId, kind, stability, status, content, confidence,
               sourceNodeIds, createdAt, updatedAt, lastConfirmedAt, expiresAt, supersededBy
        FROM memory_entries
        WHERE EXISTS (
            SELECT 1 FROM json_each(memory_entries.sourceNodeIds)
            WHERE json_each.value = ?
        ) \(activeClause)
        ORDER BY updatedAt DESC;
    """)
    try stmt.bind(nodeId.uuidString, at: 1)
    var out: [MemoryEntry] = []
    while try stmt.step() {
        if let entry = memoryEntryFrom(stmt) { out.append(entry) }
    }
    return out
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/NodeStoreTests -quiet
```

Expected: all NodeStoreTests pass including the two new ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/NodeStore.swift Tests/NousTests/NodeStoreTests.swift
git commit -m "feat(memory): add NodeStore.fetchMemoryEntries(withSourceNodeId:) reverse lookup"
```

---

### Task 2.2: Implement `UserMemoryService.citableEntryPool(...)`

**Files:**
- Modify: `Sources/Nous/Services/UserMemoryService.swift`
- Test: `Tests/NousTests/CitableEntryPoolTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NousTests/CitableEntryPoolTests.swift
import XCTest
@testable import Nous

final class CitableEntryPoolTests: XCTestCase {

    var store: NodeStore!
    var service: UserMemoryService!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
        service = UserMemoryService(
            nodeStore: store,
            llmServiceProvider: { nil }
        )
    }

    override func tearDown() {
        service = nil
        store = nil
        super.tearDown()
    }

    func testPoolBridgesNodeHitsToEntries() throws {
        let nodeA = UUID()
        let entry = MemoryEntry(
            scope: .global, kind: .preference, stability: .stable,
            content: "Alex prefers not to compete on price.",
            sourceNodeIds: [nodeA]
        )
        try store.insertMemoryEntry(entry)

        let pool = try service.citableEntryPool(
            projectId: nil,
            conversationId: UUID(),
            nodeHits: [nodeA],
            capacity: 10
        )

        XCTAssertEqual(pool.count, 1)
        XCTAssertEqual(pool.first?.id, entry.id.uuidString)
        XCTAssertEqual(pool.first?.scope, .global)
        XCTAssertTrue(pool.first!.text.contains("price"))
    }

    func testPoolDedupesAcrossHits() throws {
        let nodeA = UUID()
        let nodeB = UUID()
        let entry = MemoryEntry(
            scope: .global, kind: .preference, stability: .stable,
            content: "E", sourceNodeIds: [nodeA, nodeB]
        )
        try store.insertMemoryEntry(entry)

        let pool = try service.citableEntryPool(
            projectId: nil, conversationId: UUID(),
            nodeHits: [nodeA, nodeB], capacity: 10
        )
        XCTAssertEqual(pool.count, 1)
    }

    func testPoolAddsRecencySeedWhenNoNodeHits() throws {
        let globalEntry = MemoryEntry(
            scope: .global, kind: .preference, stability: .stable,
            content: "Recent global", sourceNodeIds: []
        )
        try store.insertMemoryEntry(globalEntry)

        let pool = try service.citableEntryPool(
            projectId: nil, conversationId: UUID(),
            nodeHits: [], capacity: 10
        )
        XCTAssertEqual(pool.map(\.id), [globalEntry.id.uuidString])
    }

    func testPoolRespectsCapacityCap() throws {
        for i in 0..<30 {
            try store.insertMemoryEntry(MemoryEntry(
                scope: .global, kind: .thread, stability: .temporary,
                content: "E\(i)", sourceNodeIds: []
            ))
        }
        let pool = try service.citableEntryPool(
            projectId: nil, conversationId: UUID(),
            nodeHits: [], capacity: 10
        )
        XCTAssertLessThanOrEqual(pool.count, 10)
    }

    func testPoolRespectsScopeForProject() throws {
        let projectId = UUID()
        let otherProjectId = UUID()
        let inProject = MemoryEntry(
            scope: .project, scopeRefId: projectId,
            kind: .thread, stability: .temporary,
            content: "in-project", sourceNodeIds: []
        )
        let otherProject = MemoryEntry(
            scope: .project, scopeRefId: otherProjectId,
            kind: .thread, stability: .temporary,
            content: "other-project", sourceNodeIds: []
        )
        try store.insertMemoryEntry(inProject)
        try store.insertMemoryEntry(otherProject)

        let pool = try service.citableEntryPool(
            projectId: projectId, conversationId: UUID(),
            nodeHits: [], capacity: 10
        )
        XCTAssertTrue(pool.contains { $0.id == inProject.id.uuidString })
        XCTAssertFalse(pool.contains { $0.id == otherProject.id.uuidString })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/CitableEntryPoolTests -quiet
```

Expected: Compilation failure — `citableEntryPool(...)` doesn't exist.

- [ ] **Step 3: Implement `citableEntryPool(...)`**

Add to `UserMemoryService.swift`:

```swift
extension UserMemoryService {

    /// Returns the entries the judge may cite this turn. Built by node-hit bridging:
    /// for each node the main retrieval flagged relevant, collect the memory_entries
    /// whose sourceNodeIds reference that node, deduplicate, then backfill with per-scope
    /// recency seeds so the pool isn't blind to recent entries that happen not to
    /// embed-match this turn. Scope-boundary invariant is enforced here.
    ///
    /// v1 does NOT run its own retrieval — `nodeHits` comes from the caller (ChatViewModel),
    /// which already ran `VectorStore.search(...)` for `citations`.
    func citableEntryPool(
        projectId: UUID?,
        conversationId: UUID,
        nodeHits: [UUID],
        capacity: Int = 15,
        recencySeedPerScope: Int = 3
    ) throws -> [CitableEntry] {
        var seen = Set<UUID>()
        var out: [CitableEntry] = []

        func admit(_ entry: MemoryEntry) {
            guard !seen.contains(entry.id) else { return }
            guard isInScope(entry, projectId: projectId, conversationId: conversationId) else { return }
            seen.insert(entry.id)
            out.append(CitableEntry(
                id: entry.id.uuidString,
                text: entry.content,
                scope: entry.scope
            ))
        }

        // Pass 1 — node-hit bridging (highest priority, first into the cap).
        for hit in nodeHits {
            guard out.count < capacity else { break }
            let bridged = (try? nodeStore.fetchMemoryEntries(withSourceNodeId: hit)) ?? []
            for entry in bridged {
                admit(entry)
                if out.count >= capacity { break }
            }
        }

        // Pass 2 — recency seed per active scope.
        let globalRecent = (try? fetchRecentEntries(scope: .global, scopeRefId: nil, limit: recencySeedPerScope)) ?? []
        globalRecent.forEach(admit)

        if let projectId, out.count < capacity {
            let projectRecent = (try? fetchRecentEntries(scope: .project, scopeRefId: projectId, limit: recencySeedPerScope)) ?? []
            projectRecent.forEach(admit)
        }

        if out.count < capacity {
            let conversationRecent = (try? fetchRecentEntries(scope: .conversation, scopeRefId: conversationId, limit: recencySeedPerScope)) ?? []
            conversationRecent.forEach(admit)
        }

        return Array(out.prefix(capacity))
    }

    private func isInScope(_ entry: MemoryEntry, projectId: UUID?, conversationId: UUID) -> Bool {
        switch entry.scope {
        case .global:
            return true
        case .project:
            return entry.scopeRefId == projectId
        case .conversation:
            return entry.scopeRefId == conversationId
        }
    }

    private func fetchRecentEntries(scope: MemoryScope, scopeRefId: UUID?, limit: Int) throws -> [MemoryEntry] {
        ((try? nodeStore.fetchMemoryEntries()) ?? [])
            .filter { $0.status == .active && $0.scope == scope && $0.scopeRefId == scopeRefId }
            .prefix(limit)
            .map { $0 }
    }
}
```

> **Note:** If `nodeStore` is not already exposed on `UserMemoryService` with sufficient visibility, adjust the stored property / init accordingly. The grep target for checking is `nodeStore: NodeStore` near line 25 in `UserMemoryService.swift`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/CitableEntryPoolTests -quiet
```

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/UserMemoryService.swift \
        Tests/NousTests/CitableEntryPoolTests.swift
git commit -m "feat(provocation): add UserMemoryService.citableEntryPool via node-hit bridging"
```

---

### Task 2.3: PR 2 final check + open PR

- [ ] **Step 1: Full suite green**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' -quiet
```

- [ ] **Step 2: Push and open PR**

```bash
git push
gh pr create --title "feat(provocation): PR 2 — CitableEntryPool via node-hit bridging" \
  --body "$(cat <<'EOF'
Stacked on PR 1. Spec: docs/superpowers/specs/2026-04-17-proactive-surfacing-design.md

## Summary
- NodeStore gains fetchMemoryEntries(withSourceNodeId:) reverse lookup
- UserMemoryService.citableEntryPool(...) builds the judge's citable pool
- No user-visible behavior change

## Test plan
- [ ] Node-hit bridging dedupes + respects scope
- [ ] Recency seed fills when no hits
- [ ] Capacity cap honored
EOF
)"
```

---

## PR 3 — ProvocationJudge

### Task 3.1: Implement `ProvocationJudge` with full test coverage

**Files:**
- Create: `Sources/Nous/Services/ProvocationJudge.swift`
- Test: `Tests/NousTests/ProvocationJudgeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NousTests/ProvocationJudgeTests.swift
import XCTest
@testable import Nous

final class ProvocationJudgeTests: XCTestCase {

    // MARK: Fake LLM Service

    final class FakeLLMService: LLMService {
        var output: String
        var shouldThrow: Error?
        var delay: TimeInterval = 0
        var receivedSystem: String?
        var receivedUserMessage: String?

        init(output: String) { self.output = output }

        func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
            receivedSystem = system
            receivedUserMessage = messages.last?.content
            if let err = shouldThrow { throw err }
            let output = self.output
            let delay = self.delay
            return AsyncThrowingStream { cont in
                Task {
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    cont.yield(output)
                    cont.finish()
                }
            }
        }
    }

    private func pool() -> [CitableEntry] {
        [CitableEntry(id: "E1", text: "Do not compete on price.", scope: .global)]
    }

    func testParsesWellFormedJSONVerdict() async throws {
        let fake = FakeLLMService(output: """
        {"tension_exists":true,"user_state":"deciding","should_provoke":true,
         "entry_id":"E1","reason":"pricing conflict"}
        """)
        let judge = ProvocationJudge(llmService: fake, timeout: 1.0)

        let verdict = try await judge.judge(
            userMessage: "I'm going with the cheapest option",
            citablePool: pool(),
            chatMode: .companion,
            provider: .claude
        )

        XCTAssertTrue(verdict.shouldProvoke)
        XCTAssertEqual(verdict.entryId, "E1")
        XCTAssertEqual(verdict.userState, .deciding)
    }

    func testRejectsMalformedJSON() async {
        let fake = FakeLLMService(output: "not json at all")
        let judge = ProvocationJudge(llmService: fake, timeout: 1.0)

        do {
            _ = try await judge.judge(
                userMessage: "hi", citablePool: pool(),
                chatMode: .companion, provider: .claude
            )
            XCTFail("Expected badJSON throw")
        } catch let error as JudgeError {
            XCTAssertEqual(error, .badJSON)
        } catch {
            XCTFail("Expected JudgeError.badJSON, got \(error)")
        }
    }

    func testSurfacesAPIError() async {
        let fake = FakeLLMService(output: "")
        fake.shouldThrow = URLError(.badServerResponse)
        let judge = ProvocationJudge(llmService: fake, timeout: 1.0)

        do {
            _ = try await judge.judge(
                userMessage: "hi", citablePool: pool(),
                chatMode: .companion, provider: .claude
            )
            XCTFail("Expected apiError throw")
        } catch let error as JudgeError {
            XCTAssertEqual(error, .apiError)
        } catch {
            XCTFail("Expected JudgeError.apiError, got \(error)")
        }
    }

    func testTimesOutWhenLLMExceedsBudget() async {
        let fake = FakeLLMService(output: """
        {"tension_exists":false,"user_state":"exploring","should_provoke":false,
         "entry_id":null,"reason":"ok"}
        """)
        fake.delay = 0.5
        let judge = ProvocationJudge(llmService: fake, timeout: 0.1)

        do {
            _ = try await judge.judge(
                userMessage: "hi", citablePool: pool(),
                chatMode: .companion, provider: .claude
            )
            XCTFail("Expected timeout throw")
        } catch let error as JudgeError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("Expected JudgeError.timeout, got \(error)")
        }
    }

    func testPromptEmbedsPoolAndChatMode() async throws {
        let fake = FakeLLMService(output: """
        {"tension_exists":false,"user_state":"exploring","should_provoke":false,
         "entry_id":null,"reason":"no tension"}
        """)
        let judge = ProvocationJudge(llmService: fake, timeout: 1.0)

        _ = try await judge.judge(
            userMessage: "so about pricing",
            citablePool: pool(),
            chatMode: .strategist,
            provider: .claude
        )

        let prompt = fake.receivedSystem ?? ""
        XCTAssertTrue(prompt.contains("E1"), "judge prompt must include citable entry ids")
        XCTAssertTrue(prompt.contains("strategist"), "judge prompt must include chat mode")
        XCTAssertTrue(prompt.contains("compete on price"), "judge prompt must include entry text")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/ProvocationJudgeTests -quiet
```

Expected: Compilation failure — `ProvocationJudge` doesn't exist.

- [ ] **Step 3: Implement `ProvocationJudge`**

```swift
// Sources/Nous/Services/ProvocationJudge.swift
import Foundation

enum JudgeError: Error, Equatable {
    case timeout
    case apiError
    case badJSON
    case emptyOutput
}

final class ProvocationJudge {
    private let llmService: any LLMService
    private let timeout: TimeInterval

    init(llmService: any LLMService, timeout: TimeInterval = 1.5) {
        self.llmService = llmService
        self.timeout = timeout
    }

    func judge(
        userMessage: String,
        citablePool: [CitableEntry],
        chatMode: ChatMode,
        provider: LLMProvider
    ) async throws -> JudgeVerdict {
        let systemPrompt = Self.buildPrompt(pool: citablePool, chatMode: chatMode)
        let llmMessages = [LLMMessage(role: "user", content: userMessage)]

        let rawOutput: String
        do {
            rawOutput = try await withTimeout(seconds: timeout) {
                try await self.collect(try await self.llmService.generate(messages: llmMessages, system: systemPrompt))
            }
        } catch is TimeoutError {
            throw JudgeError.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw JudgeError.apiError
        }

        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JudgeError.emptyOutput }

        let jsonString = Self.extractJSONObject(from: trimmed) ?? trimmed
        guard let data = jsonString.data(using: .utf8) else { throw JudgeError.badJSON }
        do {
            return try JSONDecoder().decode(JudgeVerdict.self, from: data)
        } catch {
            throw JudgeError.badJSON
        }
    }

    // MARK: Prompt

    static func buildPrompt(pool: [CitableEntry], chatMode: ChatMode) -> String {
        let poolText: String
        if pool.isEmpty {
            poolText = "(empty — no citable entries this turn)"
        } else {
            poolText = pool.enumerated().map { idx, e in
                "[\(idx + 1)] id=\(e.id) scope=\(e.scope.rawValue)\n\(e.text)"
            }.joined(separator: "\n---\n")
        }

        return """
        You are a silent judge deciding whether Nous should interject during its next reply to the user.
        Do NOT address the user. Your entire output is one JSON object exactly matching the schema below — nothing before or after.

        SCHEMA
        {
          "tension_exists": true | false,
          "user_state": "deciding" | "exploring" | "venting",
          "should_provoke": true | false,
          "entry_id": "<id from citable entries>" | null,
          "reason": "<short natural-language reason>"
        }

        RULES (must hold in your output)
        - should_provoke = true REQUIRES: tension_exists = true, user_state != "venting", and entry_id is a real id from CITABLE ENTRIES below.
        - user_state = "venting" FORCES should_provoke = false regardless of any tension. Venting is not a moment to challenge.
        - entry_id MUST be copied verbatim from the `id=` field of one CITABLE ENTRY. Do not invent.
        - CHAT_MODE-dependent threshold:
          * strategist → if tension_exists is true AND user_state ∈ {deciding, exploring}, set should_provoke = true. Soft tensions count.
          * companion  → only set should_provoke = true when the tension is strong AND clearly relevant to a decision the user is making. Soft tensions → false.

        CHAT_MODE
        \(chatMode.rawValue)

        CITABLE ENTRIES
        \(poolText)

        USER MESSAGE (next after this system block)
        """
    }

    // MARK: Output helpers

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var acc = ""
        for try await chunk in stream { acc += chunk }
        return acc
    }

    /// Pulls the first top-level `{...}` block out of free-form model output.
    /// Tolerates leading prose or stray backticks from models that don't perfectly follow
    /// "output JSON only" instructions.
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...idx]) }
            }
            idx = text.index(after: idx)
        }
        return nil
    }
}

// MARK: - Timeout helper

private struct TimeoutError: Error {}

private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/ProvocationJudgeTests -quiet
```

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/ProvocationJudge.swift \
        Tests/NousTests/ProvocationJudgeTests.swift
git commit -m "feat(provocation): add ProvocationJudge with prompt, parse, timeout"
```

---

### Task 3.2: PR 3 open

- [ ] **Step 1: Full suite green, push, open PR**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' -quiet
git push
gh pr create --title "feat(provocation): PR 3 — ProvocationJudge" \
  --body "$(cat <<'EOF'
Stacked on PR 2. Spec: docs/superpowers/specs/2026-04-17-proactive-surfacing-design.md

## Summary
- ProvocationJudge: one LLM call, strict JSON output, timeout + cancellation + malformed-JSON handling
- Prompt encodes schema, rules, chat-mode threshold, and citable pool
- Tested in isolation with a fake LLMService — no wiring into ChatViewModel yet

## Test plan
- [ ] Well-formed JSON parses correctly
- [ ] Malformed JSON throws JudgeError.badJSON
- [ ] API error throws JudgeError.apiError
- [ ] Timeout throws JudgeError.timeout
- [ ] Prompt contains pool ids, pool text, chat mode
EOF
)"
```

---

## PR 4 — Orchestration Wiring

This is the behavior-change PR. When merged, the app starts interjecting.

### Task 4.1: Inject provider accessor and judge factories into `ChatViewModel`

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Modify: `Sources/Nous/ViewModels/SettingsViewModel.swift`
- Modify: `Sources/Nous/App/ContentView.swift`
- Test: `Tests/NousTests/ProvocationOrchestrationTests.swift` (shell for upcoming tasks)

> **Design note — small-model judge:** the judge is a separate, fast/cheap call; it MUST NOT reuse the main conversation's `LLMService` (which is tuned for long, high-quality responses). We introduce a sibling factory `judgeLLMServiceFactory` that returns an `LLMService` configured with the provider's fastest small model (Haiku / Flash-Lite / gpt-4o-mini). For `.local` the factory returns nil and the orchestration skips the judge entirely (see Spec — local provider is out of v1 scope for strict JSON). If a cloud provider has no API key configured, the factory also returns nil and we log `fallbackReason=.judgeUnavailable`.

- [ ] **Step 1: Add `makeJudgeLLMService()` to `SettingsViewModel`.**

In `Sources/Nous/ViewModels/SettingsViewModel.swift`, right after the existing `makeLLMService()` method (around line 135):

```swift
/// Returns an LLMService configured with a fast, cheap model for the provocation judge.
/// Returns nil for .local (3B model unreliable for strict JSON output — v1 scope) or when
/// the relevant API key is missing. Callers fall back to .judgeUnavailable.
func makeJudgeLLMService() -> (any LLMService)? {
    switch selectedProvider {
    case .local:
        return nil
    case .gemini:
        guard !geminiApiKey.isEmpty else { return nil }
        return GeminiLLMService(apiKey: geminiApiKey, model: "gemini-2.5-flash-lite")
    case .claude:
        guard !claudeApiKey.isEmpty else { return nil }
        return ClaudeLLMService(apiKey: claudeApiKey, model: "claude-haiku-4-5-20251001")
    case .openai:
        guard !openaiApiKey.isEmpty else { return nil }
        return OpenAILLMService(apiKey: openaiApiKey, model: "gpt-4o-mini")
    }
}
```

- [ ] **Step 2: Add the new stored properties + init params** on `ChatViewModel`.

In `ChatViewModel.swift`, near the existing `llmServiceProvider` property (around line 28):

```swift
// Existing:
private let llmServiceProvider: () -> (any LLMService)?
// New:
private let currentProviderProvider: () -> LLMProvider
// Separate factory that returns a small, fast LLMService for the judge. Must NOT
// be the same as llmServiceProvider — the judge is strict-JSON / latency-sensitive.
private let judgeLLMServiceFactory: () -> (any LLMService)?
private let provocationJudgeFactory: (any LLMService) -> any Judging
// Tracks the in-flight judge Task so it can be cancelled (e.g., on conversation switch).
// Typed as the inner throwing task so cancel() propagates into the judge call.
private var inFlightJudgeTask: Task<JudgeVerdict, Error>?
```

> **v1 cancellation scope:** `send()` begins with `guard ..., !isGenerating else { return }`, so a rapid second `send()` while the first turn is still generating is a no-op — it does NOT drive cancellation. We keep `inFlightJudgeTask` because there IS a v1 cancellation vector: **view/VM teardown and conversation switching** (the VM is re-created when the user picks a different conversation, invalidating any in-flight verdict). We deliberately do NOT loosen the `isGenerating` gate in v1 — doing so would let a second `send()` double-stream the assistant reply, which is a bigger footgun than the narrow "re-thinking mid-send" flow it enables.

Update the `init(...)` to accept all new closures (default the judge factory to the real `ProvocationJudge`):

```swift
init(
    nodeStore: NodeStore,
    vectorStore: VectorStore,
    embeddingService: EmbeddingService,
    graphEngine: GraphEngine,
    userMemoryService: UserMemoryService,
    governanceTelemetry: GovernanceTelemetryStore,
    llmServiceProvider: @escaping () -> (any LLMService)?,
    currentProviderProvider: @escaping () -> LLMProvider,
    judgeLLMServiceFactory: @escaping () -> (any LLMService)?,
    provocationJudgeFactory: @escaping (any LLMService) -> any Judging = { ProvocationJudge(llmService: $0) },
    defaultProjectId: UUID? = nil
) {
    self.nodeStore = nodeStore
    self.vectorStore = vectorStore
    self.embeddingService = embeddingService
    self.graphEngine = graphEngine
    self.userMemoryService = userMemoryService
    self.governanceTelemetry = governanceTelemetry
    self.llmServiceProvider = llmServiceProvider
    self.currentProviderProvider = currentProviderProvider
    self.judgeLLMServiceFactory = judgeLLMServiceFactory
    self.provocationJudgeFactory = provocationJudgeFactory
    self.defaultProjectId = defaultProjectId
}
```

- [ ] **Step 3: Update both `ChatViewModel(...)` call sites in `ContentView.swift`** to pass the new closures. Leave `provocationJudgeFactory` defaulted in production.

Example diff context — find lines similar to:

```swift
llmServiceProvider: { svm.makeLLMService() },
```

Add right after (matching indent):

```swift
currentProviderProvider: { svm.selectedProvider },
judgeLLMServiceFactory: { svm.makeJudgeLLMService() },
```

- [ ] **Step 4: Build to confirm the wiring compiles**

```bash
xcodebuild build -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' -quiet
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift \
        Sources/Nous/ViewModels/SettingsViewModel.swift \
        Sources/Nous/App/ContentView.swift
git commit -m "feat(provocation): inject provider accessor + judge factories into ChatViewModel"
```

---

### Task 4.2: Orchestrate pool assembly + judge + profile selection inside `send()`

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Test: `Tests/NousTests/ProvocationOrchestrationTests.swift`

- [ ] **Step 1: Write the failing integration test**

```swift
// Tests/NousTests/ProvocationOrchestrationTests.swift
import XCTest
@testable import Nous

final class ProvocationOrchestrationTests: XCTestCase {

    // A fake LLM service that returns a canned stream.
    final class CannedLLMService: LLMService {
        var replyOutput: String = "ok"
        var receivedSystem: String?
        func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
            receivedSystem = system
            let out = replyOutput
            return AsyncThrowingStream { cont in
                cont.yield(out); cont.finish()
            }
        }
    }

    // A fake judge whose next verdict is preset by the test.
    final class StubJudge: ProvocationJudge {
        var nextVerdict: JudgeVerdict?
        var nextError: JudgeError?

        init() { super.init(llmService: CannedLLMService(), timeout: 1.0) }

        override func judge(
            userMessage: String,
            citablePool: [CitableEntry],
            chatMode: ChatMode,
            provider: LLMProvider
        ) async throws -> JudgeVerdict {
            if let err = nextError { throw err }
            guard let v = nextVerdict else {
                return JudgeVerdict(tensionExists: false, userState: .exploring,
                                    shouldProvoke: false, entryId: nil, reason: "stub default")
            }
            return v
        }
    }

    var store: NodeStore!
    var telemetry: GovernanceTelemetryStore!
    var llm: CannedLLMService!
    var judge: StubJudge!
    var viewModel: ChatViewModel!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
        telemetry = GovernanceTelemetryStore(
            defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
            nodeStore: store
        )
        llm = CannedLLMService()
        judge = StubJudge()
        viewModel = ChatViewModel(
            nodeStore: store,
            vectorStore: VectorStore(nodeStore: store),
            embeddingService: EmbeddingService(),
            graphEngine: GraphEngine(nodeStore: store),
            userMemoryService: UserMemoryService(nodeStore: store, llmServiceProvider: { self.llm }),
            governanceTelemetry: telemetry,
            llmServiceProvider: { self.llm },
            currentProviderProvider: { .claude },
            judgeLLMServiceFactory: { CannedLLMService() },
            provocationJudgeFactory: { _ in self.judge }
        )
    }

    override func tearDown() {
        viewModel = nil; judge = nil; llm = nil; telemetry = nil; store = nil
        super.tearDown()
    }

    @MainActor
    func testShouldProvokeTrueInjectsFocusBlock() async throws {
        let entryId = UUID()
        let entry = MemoryEntry(
            id: entryId, scope: .global, kind: .preference, stability: .stable,
            content: "Alex refuses to compete on price.",
            sourceNodeIds: []
        )
        try store.insertMemoryEntry(entry)

        judge.nextVerdict = JudgeVerdict(
            tensionExists: true, userState: .deciding,
            shouldProvoke: true, entryId: entryId.uuidString,
            reason: "pricing conflict"
        )

        viewModel.inputText = "I'm going with the cheapest option on purpose"
        await viewModel.send()

        let system = llm.receivedSystem ?? ""
        XCTAssertTrue(system.contains("BEHAVIOR: PROVOCATIVE"),
                      "provocative profile block must be in main prompt")
        XCTAssertTrue(system.contains("RELEVANT PRIOR MEMORY"),
                      "focus block must be in main prompt")
        XCTAssertTrue(system.contains("compete on price"),
                      "raw entry text must be in main prompt")

        let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.fallbackReason, .ok)
    }

    @MainActor
    func testShouldProvokeFalseUsesSupportiveProfile() async throws {
        judge.nextVerdict = JudgeVerdict(
            tensionExists: false, userState: .exploring,
            shouldProvoke: false, entryId: nil, reason: "no tension"
        )

        viewModel.inputText = "just thinking out loud"
        await viewModel.send()

        let system = llm.receivedSystem ?? ""
        XCTAssertTrue(system.contains("BEHAVIOR: SUPPORTIVE"))
        XCTAssertFalse(system.contains("RELEVANT PRIOR MEMORY"),
                       "no focus block when should_provoke is false")
    }

    @MainActor
    func testUnknownEntryIdForcesSupportiveAndLogsError() async throws {
        judge.nextVerdict = JudgeVerdict(
            tensionExists: true, userState: .deciding,
            shouldProvoke: true, entryId: "not-in-pool",
            reason: "ghost"
        )

        viewModel.inputText = "anything"
        await viewModel.send()

        let system = llm.receivedSystem ?? ""
        XCTAssertTrue(system.contains("BEHAVIOR: SUPPORTIVE"))
        XCTAssertFalse(system.contains("RELEVANT PRIOR MEMORY"))

        let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
        XCTAssertEqual(events.first?.fallbackReason, .unknownEntryId)
    }

    @MainActor
    func testJudgeTimeoutFallsBackToSupportive() async throws {
        judge.nextError = .timeout

        viewModel.inputText = "anything"
        await viewModel.send()

        let system = llm.receivedSystem ?? ""
        XCTAssertTrue(system.contains("BEHAVIOR: SUPPORTIVE"))

        let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
        XCTAssertEqual(events.first?.fallbackReason, .timeout)
    }

    @MainActor
    func testLocalProviderSkipsJudge() async throws {
        // Rebuild vm with local provider. judgeLLMServiceFactory returns nil on .local,
        // BUT the orchestration short-circuits on provider == .local BEFORE consulting the
        // factory, so we return nil here and assert the factory is never consulted.
        viewModel = ChatViewModel(
            nodeStore: store,
            vectorStore: VectorStore(nodeStore: store),
            embeddingService: EmbeddingService(),
            graphEngine: GraphEngine(nodeStore: store),
            userMemoryService: UserMemoryService(nodeStore: store, llmServiceProvider: { self.llm }),
            governanceTelemetry: telemetry,
            llmServiceProvider: { self.llm },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            provocationJudgeFactory: { _ in
                // If this ever runs, the test fails loudly.
                let j = StubJudge()
                j.nextError = .apiError
                return j
            }
        )

        viewModel.inputText = "anything"
        await viewModel.send()

        let system = llm.receivedSystem ?? ""
        XCTAssertTrue(system.contains("BEHAVIOR: SUPPORTIVE"))

        let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
        XCTAssertEqual(events.first?.fallbackReason, .providerLocal)
    }

    @MainActor
    func testCloudProviderWithoutJudgeServiceLogsUnavailable() async throws {
        // Cloud provider selected but judgeLLMServiceFactory returned nil (missing API key).
        viewModel = ChatViewModel(
            nodeStore: store,
            vectorStore: VectorStore(nodeStore: store),
            embeddingService: EmbeddingService(),
            graphEngine: GraphEngine(nodeStore: store),
            userMemoryService: UserMemoryService(nodeStore: store, llmServiceProvider: { self.llm }),
            governanceTelemetry: telemetry,
            llmServiceProvider: { self.llm },
            currentProviderProvider: { .claude },
            judgeLLMServiceFactory: { nil },
            provocationJudgeFactory: { _ in
                let j = StubJudge()
                j.nextError = .apiError
                return j
            }
        )

        viewModel.inputText = "anything"
        await viewModel.send()

        let system = llm.receivedSystem ?? ""
        XCTAssertTrue(system.contains("BEHAVIOR: SUPPORTIVE"))

        let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
        XCTAssertEqual(events.first?.fallbackReason, .judgeUnavailable)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/ProvocationOrchestrationTests -quiet
```

Expected: failures because `send()` doesn't yet assemble a pool, invoke the judge, compose a focus block, or log events.

> **Note:** `StubJudge` subclasses `ProvocationJudge`. Mark the `judge(...)` method in `ProvocationJudge` `open` (or move the concrete class to be non-final and the method to `open`) so the subclass can override. Alternative: extract a `Judging` protocol and let both the real judge and the stub conform. **Pick the protocol route** — it's the cleaner boundary. Add this protocol in `ProvocationJudge.swift`:
> ```swift
> protocol Judging {
>     func judge(userMessage: String, citablePool: [CitableEntry], chatMode: ChatMode, provider: LLMProvider) async throws -> JudgeVerdict
> }
> extension ProvocationJudge: Judging {}
> ```
> Then change `provocationJudgeFactory` in `ChatViewModel` to return `any Judging` instead of `ProvocationJudge`, and update the `StubJudge` in the test to conform to `Judging` directly (no subclassing). This is a small refactor but pays for itself in testability — apply it now rather than in a later task.

- [ ] **Step 3: Apply the `Judging` protocol refactor.**

In `Sources/Nous/Services/ProvocationJudge.swift`, add the protocol right above `ProvocationJudge`:

```swift
protocol Judging {
    func judge(
        userMessage: String,
        citablePool: [CitableEntry],
        chatMode: ChatMode,
        provider: LLMProvider
    ) async throws -> JudgeVerdict
}

extension ProvocationJudge: Judging {}
```

`ChatViewModel`'s factory type was already declared as `(any LLMService) -> any Judging` in Task 4.1 Step 2 — no further change needed there.

In the test above, replace `class StubJudge: ProvocationJudge` with `final class StubJudge: Judging` (remove the `init()`, remove `override`, remove the super call; drop the unused `CannedLLMService` init, and pass `self.judge` directly into the factory closure).

- [ ] **Step 4: Extend `send()` to drive the orchestration.**

In `ChatViewModel.send()`, after Step 5 (`assembleContext(...)`) and the existing `governanceTelemetry.recordPromptTrace(promptTrace)` line, insert the judge flow. Replace the current Step 8 (`let stream = try await llm.generate(messages: llmMessages, system: context)`) with a flow that first runs the judge and composes the final system prompt:

```swift
// Step 5b: assemble citable pool for the judge
let nodeHits = citations.map { $0.node.id }
let citablePool = (try? userMemoryService.citableEntryPool(
    projectId: node.projectId,
    conversationId: node.id,
    nodeHits: nodeHits
)) ?? []

// Step 5c: call the judge (or skip on local)
let currentProvider = currentProviderProvider()
let eventId = UUID()
var verdictForLog: JudgeVerdict?
var fallbackReason: JudgeFallbackReason = .ok
var profile: BehaviorProfile = .supportive
var focusBlock: String? = nil

if currentProvider == .local {
    fallbackReason = .providerLocal
} else if let judgeLLM = judgeLLMServiceFactory() {
    // NOTE: Task 4.3 wraps this call in a tracked Task<JudgeVerdict, Error> so it's cancellable
    // on conversation switch. For now the call is inline and synchronous-await — rewritten below.
    let judge = provocationJudgeFactory(judgeLLM)
    do {
        let verdict = try await judge.judge(
            userMessage: promptQuery,
            citablePool: citablePool,
            chatMode: activeChatMode,
            provider: currentProvider
        )
        verdictForLog = verdict

        if verdict.shouldProvoke, let entryIdStr = verdict.entryId {
            if let matched = citablePool.first(where: { $0.id == entryIdStr }),
               let uuid = UUID(uuidString: entryIdStr),
               let rawEntry = try? nodeStore.fetchMemoryEntry(id: uuid) {
                profile = .provocative
                focusBlock = ChatViewModel.buildFocusBlock(entryId: matched.id, rawText: rawEntry.content)
                fallbackReason = .ok
            } else {
                fallbackReason = .unknownEntryId
                profile = .supportive
            }
        } else {
            fallbackReason = .ok
            profile = .supportive
        }
    } catch JudgeError.timeout {
        fallbackReason = .timeout
    } catch JudgeError.badJSON {
        fallbackReason = .badJSON
    } catch is CancellationError {
        // Judge was cancelled (conversation switch / VM teardown). Drop this reply entirely.
        return
    } catch {
        fallbackReason = .apiError
    }
} else {
    // Cloud provider selected but API key missing / factory returned nil.
    fallbackReason = .judgeUnavailable
}

// Step 5d: compose final system prompt
let finalSystem = [context, profile.contextBlock, focusBlock]
    .compactMap { $0 }
    .joined(separator: "\n\n")

// Step 5e: log the judge event (do this BEFORE the main call so we have the record even if the main call fails)
let verdictJSONStr: String = {
    if let v = verdictForLog, let data = try? JSONEncoder().encode(v) {
        return String(data: data, encoding: .utf8) ?? "{}"
    }
    return "{}"
}()
let event = JudgeEvent(
    id: eventId, ts: Date(), nodeId: node.id, messageId: nil,
    chatMode: activeChatMode, provider: currentProvider,
    verdictJSON: verdictJSONStr, fallbackReason: fallbackReason,
    userFeedback: nil, feedbackTs: nil
)
governanceTelemetry.appendJudgeEvent(event)
```

Then the existing Step 8 call becomes:

```swift
let stream = try await llm.generate(messages: llmMessages, system: finalSystem)
```

And after the assistant message is saved (existing Step 9), patch the `messageId`:

```swift
// Step 9b: patch the judge event with the message it produced
try? nodeStore.updateJudgeEventMessageId(eventId: eventId, messageId: assistantMessage.id)
```

Add the helper `buildFocusBlock` as a static method on `ChatViewModel`:

```swift
private static func buildFocusBlock(entryId: String, rawText: String) -> String {
    """
    RELEVANT PRIOR MEMORY (id=\(entryId)):
    \(rawText)

    Surface this memory in your reply. Name the tension with Alex's current claim in plain language.
    Quote one specific line from the memory faithfully if there is one to quote; otherwise paraphrase tightly.
    Do not reword the memory into a summary and pretend you remembered it differently.
    """
}
```

Add a matching `updateJudgeEventMessageId` helper next to `updateJudgeEventFeedback` in `NodeStore.swift`:

```swift
func updateJudgeEventMessageId(eventId: UUID, messageId: UUID) throws {
    let stmt = try db.prepare("""
        UPDATE judge_events SET messageId = ? WHERE id = ?;
    """)
    try stmt.bind(messageId.uuidString, at: 1)
    try stmt.bind(eventId.uuidString, at: 2)
    try stmt.step()
}
```

- [ ] **Step 5: Run integration tests**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/ProvocationOrchestrationTests -quiet
```

Expected: all 5 tests pass.

- [ ] **Step 6: Run the full suite**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' -quiet
```

Expected: no regressions in existing tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/Nous/Services/ProvocationJudge.swift \
        Sources/Nous/Services/NodeStore.swift \
        Sources/Nous/ViewModels/ChatViewModel.swift \
        Tests/NousTests/ProvocationOrchestrationTests.swift
git commit -m "feat(provocation): wire judge into ChatViewModel.send with profile + focus block"
```

---

### Task 4.3: Wrap the judge call in a trackable, cancellable Task

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Test: append to `Tests/NousTests/ProvocationOrchestrationTests.swift`

**Rationale and v1 scope:**
- `send()` begins with `guard ..., !isGenerating else { return }` at `ChatViewModel.swift:206`. A rapid second `send()` while the first turn is streaming is therefore a no-op at the gate — it does NOT drive judge cancellation. We deliberately do NOT loosen this gate in v1; doing so would double-stream the assistant reply into the same conversation, which is a much bigger footgun than the narrow "re-think mid-send" flow it would enable.
- The cancellation vector that IS real in v1 is **conversation switch / VM teardown**. If the user navigates to a different conversation while a judge call is still running, the verdict belongs to a node that is no longer active. We need to cancel cleanly so we don't log a stale event (and the task's `CancellationError` short-circuits `send()` via the existing `catch is CancellationError { return }`).
- To make that cancellation actually propagate, `inFlightJudgeTask` is typed `Task<JudgeVerdict, Error>?` (the **inner** throwing task), not a `Task<Void, Never>` wrapper. Cancelling the wrapper does not cancel the real judge call underneath it; cancelling the inner task directly does.

This task (1) wraps the judge call in a tracked inner `Task<JudgeVerdict, Error>`, (2) exposes `cancelInFlightJudge()` so external triggers (conversation switch, teardown) can cancel it, and (3) adds a test that drives cancellation via that method.

- [ ] **Step 1: Write the failing test** (append to `ProvocationOrchestrationTests.swift`)

```swift
// Append to Tests/NousTests/ProvocationOrchestrationTests.swift

@MainActor
func testExternalCancellationShortCircuitsJudge() async throws {
    // A judge that sleeps long enough for us to fire cancelInFlightJudge() mid-call.
    final class SlowJudge: Judging {
        func judge(userMessage: String, citablePool: [CitableEntry],
                   chatMode: ChatMode, provider: LLMProvider) async throws -> JudgeVerdict {
            try await Task.sleep(nanoseconds: 2_000_000_000)  // 2s — long enough to cancel
            try Task.checkCancellation()  // propagate cancel even if sleep was swallowed
            return JudgeVerdict(tensionExists: false, userState: .exploring,
                                shouldProvoke: false, entryId: nil, reason: "slow")
        }
    }
    viewModel = ChatViewModel(
        nodeStore: store,
        vectorStore: VectorStore(nodeStore: store),
        embeddingService: EmbeddingService(),
        graphEngine: GraphEngine(nodeStore: store),
        userMemoryService: UserMemoryService(nodeStore: store, llmServiceProvider: { self.llm }),
        governanceTelemetry: telemetry,
        llmServiceProvider: { self.llm },
        currentProviderProvider: { .claude },
        judgeLLMServiceFactory: { CannedLLMService() },
        provocationJudgeFactory: { _ in SlowJudge() }
    )

    viewModel.inputText = "test"
    // Fire send() without awaiting; cancel shortly after so the judge is interrupted.
    let sendTask = Task { await viewModel.send() }
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms — judge is now sleeping inside
    viewModel.cancelInFlightJudge()
    await sendTask.value

    // The cancelled judge must not have produced a main-LLM call
    // (send() returns early in the CancellationError branch, before llm.generate()).
    XCTAssertNil(llm.receivedSystem,
                 "cancelled judge must short-circuit send() before the main LLM call")

    // And no judge event should be logged for a cancelled turn.
    let events = telemetry.recentJudgeEvents(limit: 10, filter: .none)
    XCTAssertEqual(events.count, 0, "cancelled judge must not log any judge event")
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/ProvocationOrchestrationTests/testExternalCancellationShortCircuitsJudge \
  -quiet
```

Expected: FAIL — `cancelInFlightJudge()` doesn't exist yet, and the judge call isn't wrapped in a trackable task.

- [ ] **Step 3: Wrap the judge call in a tracked inner `Task`**

In `ChatViewModel.send()` replace the judge invocation block added in Task 4.2 with the tracked-task form:

```swift
if currentProvider == .local {
    fallbackReason = .providerLocal
} else if let judgeLLM = judgeLLMServiceFactory() {
    // Cancel any previous in-flight judge (e.g., from a prior conversation).
    // In v1 this is belt-and-braces — the isGenerating gate already prevents a rapid
    // second send on the *same* conversation. The real trigger for cancellation is
    // cancelInFlightJudge() called externally (e.g., from a future conversation-switch hook).
    inFlightJudgeTask?.cancel()

    let judge = provocationJudgeFactory(judgeLLM)
    // Store the INNER throwing task directly — not a Void wrapper — so cancel() propagates
    // into the judge's async work (Task.sleep, URLSession, etc. all respect cancellation).
    let task = Task { () async throws -> JudgeVerdict in
        try await judge.judge(
            userMessage: promptQuery,
            citablePool: citablePool,
            chatMode: activeChatMode,
            provider: currentProvider
        )
    }
    inFlightJudgeTask = task

    do {
        let verdict = try await task.value
        verdictForLog = verdict

        if verdict.shouldProvoke, let entryIdStr = verdict.entryId {
            if let matched = citablePool.first(where: { $0.id == entryIdStr }),
               let uuid = UUID(uuidString: entryIdStr),
               let rawEntry = try? nodeStore.fetchMemoryEntry(id: uuid) {
                profile = .provocative
                focusBlock = ChatViewModel.buildFocusBlock(entryId: matched.id, rawText: rawEntry.content)
                fallbackReason = .ok
            } else {
                fallbackReason = .unknownEntryId
                profile = .supportive
            }
        } else {
            fallbackReason = .ok
            profile = .supportive
        }
    } catch JudgeError.timeout {
        fallbackReason = .timeout
    } catch JudgeError.badJSON {
        fallbackReason = .badJSON
    } catch is CancellationError {
        // External cancellation (conversation switch / VM teardown). Discard this turn
        // entirely — no main-LLM call, no judge event logged, no assistant message.
        return
    } catch {
        fallbackReason = .apiError
    }

    // Clear the slot only if it still points at our task. If a later send() stored its
    // own task we must not clobber it.
    if inFlightJudgeTask === task {
        inFlightJudgeTask = nil
    }
} else {
    fallbackReason = .judgeUnavailable
}
```

- [ ] **Step 4: Expose `cancelInFlightJudge()` on `ChatViewModel`**

Add this method near the other public methods (e.g., right after `send(...)`):

```swift
/// External hook to cancel an in-flight judge call (conversation switch, VM teardown, etc.).
/// Safe to call at any time — no-op if no judge is running.
@MainActor
func cancelInFlightJudge() {
    inFlightJudgeTask?.cancel()
    inFlightJudgeTask = nil
}
```

- [ ] **Step 5: Run the cancellation test to verify it passes**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/ProvocationOrchestrationTests -quiet
```

Expected: all ProvocationOrchestrationTests pass including the new cancellation one.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift \
        Tests/NousTests/ProvocationOrchestrationTests.swift
git commit -m "feat(provocation): track judge task for external cancellation (conversation switch)"
```

---

### Task 4.4: Wire `cancelInFlightJudge()` into real conversation-switch paths

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Modify: `Sources/Nous/App/ContentView.swift`
- Test: append to `Tests/NousTests/ProvocationOrchestrationTests.swift`

Task 4.3 exposed `cancelInFlightJudge()` but left it as orphan API — nothing in the product calls it, so the cancellation path is only exercised by tests. This task connects it to the four real vectors in the current codebase:

1. **`ChatViewModel.loadConversation(_:)`** (`ChatViewModel.swift:70`) — user picks a different conversation from the sidebar.
2. **`ChatViewModel.startNewConversation(...)`** (`ChatViewModel.swift:55`) — user starts a fresh conversation (also fires from the quick-action flow at line 90).
3. **`ContentView.swift:102`** — explicit reset (`chatVM.currentNode = nil`) when the user clicks "new chat".
4. **`ChatViewModel.deinit`** — process-level cleanup (defensive; in practice the VM outlives any single judge call, but a deinit hook means a leaked judge task can never outlive the VM).

- [ ] **Step 1: Write the failing test** (append to `ProvocationOrchestrationTests.swift`)

```swift
// Append to Tests/NousTests/ProvocationOrchestrationTests.swift

@MainActor
func testLoadConversationCancelsInFlightJudge() async throws {
    final class SlowJudge: Judging {
        var wasCancelled = false
        func judge(userMessage: String, citablePool: [CitableEntry],
                   chatMode: ChatMode, provider: LLMProvider) async throws -> JudgeVerdict {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                wasCancelled = true
                throw CancellationError()
            }
            return JudgeVerdict(tensionExists: false, userState: .exploring,
                                shouldProvoke: false, entryId: nil, reason: "slow")
        }
    }
    let slowJudge = SlowJudge()
    viewModel = ChatViewModel(
        nodeStore: store,
        vectorStore: VectorStore(nodeStore: store),
        embeddingService: EmbeddingService(),
        graphEngine: GraphEngine(nodeStore: store),
        userMemoryService: UserMemoryService(nodeStore: store, llmServiceProvider: { self.llm }),
        governanceTelemetry: telemetry,
        llmServiceProvider: { self.llm },
        currentProviderProvider: { .claude },
        judgeLLMServiceFactory: { CannedLLMService() },
        provocationJudgeFactory: { _ in slowJudge }
    )

    viewModel.inputText = "first"
    let sendTask = Task { await viewModel.send() }
    try await Task.sleep(nanoseconds: 100_000_000)  // let the judge enter its sleep

    // User navigates to a different conversation.
    let otherNode = NousNode(type: .conversation, title: "other", projectId: nil)
    try store.insertNode(otherNode)
    viewModel.loadConversation(otherNode)

    await sendTask.value

    XCTAssertTrue(slowJudge.wasCancelled,
                  "loadConversation must cancel the in-flight judge task")
    XCTAssertNil(llm.receivedSystem,
                 "cancelled judge must short-circuit send() before main LLM call")
    let events = telemetry.recentJudgeEvents(limit: 10, filter: .none)
    XCTAssertEqual(events.count, 0,
                   "cancelled judge must not log any judge event")
}

@MainActor
func testStartNewConversationCancelsInFlightJudge() async throws {
    final class SlowJudge: Judging {
        var wasCancelled = false
        func judge(userMessage: String, citablePool: [CitableEntry],
                   chatMode: ChatMode, provider: LLMProvider) async throws -> JudgeVerdict {
            do { try await Task.sleep(nanoseconds: 2_000_000_000) }
            catch { wasCancelled = true; throw CancellationError() }
            return JudgeVerdict(tensionExists: false, userState: .exploring,
                                shouldProvoke: false, entryId: nil, reason: "slow")
        }
    }
    let slowJudge = SlowJudge()
    viewModel = ChatViewModel(
        nodeStore: store,
        vectorStore: VectorStore(nodeStore: store),
        embeddingService: EmbeddingService(),
        graphEngine: GraphEngine(nodeStore: store),
        userMemoryService: UserMemoryService(nodeStore: store, llmServiceProvider: { self.llm }),
        governanceTelemetry: telemetry,
        llmServiceProvider: { self.llm },
        currentProviderProvider: { .claude },
        judgeLLMServiceFactory: { CannedLLMService() },
        provocationJudgeFactory: { _ in slowJudge }
    )

    viewModel.inputText = "first"
    let sendTask = Task { await viewModel.send() }
    try await Task.sleep(nanoseconds: 100_000_000)

    viewModel.startNewConversation(title: "fresh")

    await sendTask.value

    XCTAssertTrue(slowJudge.wasCancelled,
                  "startNewConversation must cancel the in-flight judge task")
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/ProvocationOrchestrationTests/testLoadConversationCancelsInFlightJudge \
  -only-testing:NousTests/ProvocationOrchestrationTests/testStartNewConversationCancelsInFlightJudge \
  -quiet
```

Expected: FAIL — `loadConversation` and `startNewConversation` don't cancel anything yet.

- [ ] **Step 3: Add the hook calls in `ChatViewModel`**

In `ChatViewModel.swift`, at the **top** of `loadConversation(_:)` (line 70), before `currentNode = node`:

```swift
func loadConversation(_ node: NousNode) {
    cancelInFlightJudge()  // switching conversations invalidates any pending verdict
    currentNode = node
    messages = (try? nodeStore.fetchMessages(nodeId: node.id)) ?? []
    citations = []
    currentResponse = ""
    activeQuickActionMode = nil
}
```

At the top of `startNewConversation(title:projectId:)` (line 55), before building the new `NousNode`:

```swift
func startNewConversation(title: String = "New Conversation", projectId: UUID? = nil) {
    cancelInFlightJudge()  // any in-flight judge belonged to the old conversation
    let node = NousNode(
        type: .conversation,
        title: title,
        projectId: projectId
    )
    // …rest unchanged
}
```

Add a `deinit` on `ChatViewModel` (anywhere in the class body; near the initializer is fine):

```swift
deinit {
    // VM teardown — make sure no judge task outlives us.
    inFlightJudgeTask?.cancel()
}
```

> Note: `deinit` runs on whatever thread releases the last reference, so we can't call the `@MainActor`-isolated `cancelInFlightJudge()` from here. Cancelling the stored `Task` reference directly is thread-safe (Swift `Task.cancel()` is documented as callable from any context) and does the same thing.

- [ ] **Step 4: Hook the `ContentView` "new chat" reset**

In `ContentView.swift`, find the line `chatVM.currentNode = nil` (around line 102) and replace:

```swift
chatVM.currentNode = nil
```

with:

```swift
chatVM.cancelInFlightJudge()
chatVM.currentNode = nil
```

- [ ] **Step 5: Run the cancellation tests to verify they pass**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/ProvocationOrchestrationTests -quiet
```

Expected: all ProvocationOrchestrationTests pass, including the two new hook tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift \
        Sources/Nous/App/ContentView.swift \
        Tests/NousTests/ProvocationOrchestrationTests.swift
git commit -m "feat(provocation): cancel in-flight judge on conversation switch / VM teardown"
```

---

### Task 4.5: PR 4 open

- [ ] **Step 1: Full suite green, push, open PR**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' -quiet
git push
gh pr create --title "feat(provocation): PR 4 — orchestrate judge in ChatViewModel.send" \
  --body "$(cat <<'EOF'
Stacked on PR 3. Spec: docs/superpowers/specs/2026-04-17-proactive-surfacing-design.md

## Summary
**First behavior-changing PR** — interjections start happening.
- send() now: assembles citable pool, calls judge via a small-model LLMService (Haiku / Flash-Lite / gpt-4o-mini), validates entry_id, selects BehaviorProfile, appends focus block, logs JudgeEvent
- Judge uses a separate `judgeLLMServiceFactory` — never the main conversation's LLMService
- Provider .local skips the judge entirely (small local model is unreliable for strict JSON in v1)
- Cloud provider with missing API key → fallbackReason=.judgeUnavailable
- Unknown entry_id / malformed JSON / timeout all fall back to .supportive with appropriate fallbackReason
- Inner-typed `inFlightJudgeTask` exposed via `cancelInFlightJudge()` for external cancellation (conversation switch / VM teardown). v1 does NOT loosen the `isGenerating` gate — rapid second sends are still blocked at the top of `send()`.

## Test plan
- [ ] should_provoke=true injects provocative profile + focus block
- [ ] should_provoke=false uses supportive profile, no focus block
- [ ] unknown entry_id → supportive, fallbackReason=.unknownEntryId
- [ ] judge timeout → supportive, fallbackReason=.timeout
- [ ] local provider → supportive, judge never called, fallbackReason=.providerLocal
- [ ] cloud provider without judge LLMService → supportive, fallbackReason=.judgeUnavailable
- [ ] cancelInFlightJudge() short-circuits send() before the main LLM call and logs nothing
- [ ] loadConversation(_:) cancels an in-flight judge
- [ ] startNewConversation(...) cancels an in-flight judge
EOF
)"
```

---

## PR 5 — Feedback UI + Inspector Review Panel

### Task 5.1: Add 👍/👎 feedback on provoked messages

**Files:**
- Modify: `Sources/Nous/Views/ChatArea.swift`
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift` (expose a mapping from assistant messageId → judge eventId, and a callback for feedback)

> **Note:** feedback UI is only attached to messages produced from a provoked turn. We identify those by querying `judge_events` for a row whose `messageId == message.id` with `fallbackReason == .ok` and (from the embedded `verdictJSON`) `should_provoke == true`.

- [ ] **Step 1: Write the failing test** (append to `ProvocationOrchestrationTests.swift`)

```swift
// Append to Tests/NousTests/ProvocationOrchestrationTests.swift

@MainActor
func testFeedbackUpdatesEvent() async throws {
    let entryId = UUID()
    try store.insertMemoryEntry(MemoryEntry(
        id: entryId, scope: .global, kind: .preference, stability: .stable,
        content: "don't compete on price", sourceNodeIds: []
    ))
    judge.nextVerdict = JudgeVerdict(
        tensionExists: true, userState: .deciding,
        shouldProvoke: true, entryId: entryId.uuidString, reason: "conflict"
    )
    viewModel.inputText = "going cheap"
    await viewModel.send()

    // The last assistant message should be linked to a judge event.
    guard let assistantMessage = viewModel.messages.last(where: { $0.role == .assistant }),
          let eventId = viewModel.judgeEventId(forMessageId: assistantMessage.id)
    else {
        XCTFail("expected a judge event for the provoked assistant message")
        return
    }

    viewModel.recordFeedback(forMessageId: assistantMessage.id, feedback: .down)

    let updated = try store.fetchJudgeEvent(id: eventId)
    XCTAssertEqual(updated?.userFeedback, .down)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/ProvocationOrchestrationTests/testFeedbackUpdatesEvent \
  -quiet
```

Expected: FAIL — `judgeEventId(forMessageId:)` and `recordFeedback(forMessageId:feedback:)` don't exist.

- [ ] **Step 3: Add the query + write methods on `ChatViewModel`**

Add at the bottom of `ChatViewModel.swift`:

```swift
extension ChatViewModel {

    /// Returns the judge event id for a given assistant message, if one was recorded
    /// for the turn that produced it AND the judge actually provoked.
    /// Returns nil for messages from non-provoked or pre-feature turns.
    @MainActor
    func judgeEventId(forMessageId messageId: UUID) -> UUID? {
        // We scan the recent window — this view only ever needs the last few hundred events.
        let events = governanceTelemetry.recentJudgeEvents(limit: 500, filter: .none)
        guard let match = events.first(where: { $0.messageId == messageId }),
              match.fallbackReason == .ok else { return nil }
        guard let verdictData = match.verdictJSON.data(using: .utf8),
              let verdict = try? JSONDecoder().decode(JudgeVerdict.self, from: verdictData),
              verdict.shouldProvoke else { return nil }
        return match.id
    }

    @MainActor
    func recordFeedback(forMessageId messageId: UUID, feedback: JudgeFeedback) {
        guard let eventId = judgeEventId(forMessageId: messageId) else { return }
        governanceTelemetry.recordFeedback(eventId: eventId, feedback: feedback)
    }
}
```

- [ ] **Step 4: Add the UI affordance in `ChatArea.swift`**

Find the assistant-message bubble rendering and append (inside the same `HStack`/`VStack` scope, scaled to the existing design):

```swift
if let eventId = chatVM.judgeEventId(forMessageId: message.id) {
    HStack(spacing: 8) {
        Button(action: { chatVM.recordFeedback(forMessageId: message.id, feedback: .up) }) {
            Image(systemName: "hand.thumbsup")
        }.buttonStyle(.plain)
        Button(action: { chatVM.recordFeedback(forMessageId: message.id, feedback: .down) }) {
            Image(systemName: "hand.thumbsdown")
        }.buttonStyle(.plain)
    }
    .font(.footnote)
    .foregroundStyle(.secondary)
    .help("Was this interjection useful? (event \(eventId.uuidString.prefix(8)))")
}
```

> **Note:** the exact insertion point depends on the current `ChatArea.swift` structure. The pattern: insert into the same container as the existing `Text(message.content)` for assistant messages, below the text. If there's an existing inline footer/metadata row, reuse it.

- [ ] **Step 5: Run the feedback test and the full suite**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' -quiet
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift \
        Sources/Nous/Views/ChatArea.swift \
        Tests/NousTests/ProvocationOrchestrationTests.swift
git commit -m "feat(provocation): add 👍/👎 feedback on provoked messages"
```

---

### Task 5.2: Add review panel to `MemoryDebugInspector`

**Files:**
- Modify: `Sources/Nous/Views/MemoryDebugInspector.swift`

- [ ] **Step 1: Read the current Inspector file** to understand its tab structure.

```bash
grep -n "TabView\|struct.*View\|enum.*Tab" Sources/Nous/Views/MemoryDebugInspector.swift | head -20
```

- [ ] **Step 2: Add a new `judge` tab.** Extend the existing inspector's tab-enum (whatever its name is — look for an enum with cases like `.global`, `.project`, etc.) with `case judge`. Then add a `JudgeEventsTab` view:

```swift
// Append to Sources/Nous/Views/MemoryDebugInspector.swift

struct JudgeEventsTab: View {
    let telemetry: GovernanceTelemetryStore
    @State private var filter: JudgeEventFilter = .none
    @State private var events: [JudgeEvent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Filter", selection: $filter) {
                    Text("All").tag(JudgeEventFilter.none)
                    Text("Provoked").tag(JudgeEventFilter.shouldProvoke(true))
                    Text("Not provoked").tag(JudgeEventFilter.shouldProvoke(false))
                    Text("Failures").tag(JudgeEventFilter.fallback(.timeout))
                    Text("Bad JSON").tag(JudgeEventFilter.fallback(.badJSON))
                    Text("Scope breach").tag(JudgeEventFilter.fallback(.unknownEntryId))
                }
                .pickerStyle(.menu)
                Button("Refresh") { reload() }
            }
            List(events, id: \.id) { event in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(event.ts.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospaced())
                        Text(event.chatMode.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .background(.secondary.opacity(0.15))
                            .clipShape(Capsule())
                        Text(event.fallbackReason.rawValue)
                            .font(.caption)
                            .foregroundStyle(event.fallbackReason == .ok ? .green : .orange)
                        if let fb = event.userFeedback {
                            Image(systemName: fb == .up ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                                .font(.caption)
                                .foregroundStyle(fb == .up ? .green : .red)
                        }
                    }
                    Text(event.verdictJSON)
                        .font(.caption2.monospaced())
                        .lineLimit(3)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .padding()
        .onAppear(perform: reload)
        .onChange(of: filter) { _, _ in reload() }
    }

    private func reload() {
        events = telemetry.recentJudgeEvents(limit: 200, filter: filter)
    }
}
```

Wire it into the existing tab switch alongside the others (mirroring the pattern already used — typically `case .judge: JudgeEventsTab(telemetry: telemetry)`). The `telemetry` reference should already be reachable from the inspector; if not, thread it through the inspector's init the way other dependencies are threaded.

- [ ] **Step 3: Build and run the app manually** (one-shot smoke test — not part of the automated test suite, because SwiftUI view rendering is awkward to unit-test).

```bash
xcodebuild build -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' -quiet
```

Then launch the app, open the inspector, navigate to the judge tab. With no events yet, it shows an empty list. Send a message → a row appears. This step is for the engineer to visually confirm — there is no automated assertion.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Views/MemoryDebugInspector.swift
git commit -m "feat(provocation): add judge-events review tab to MemoryDebugInspector"
```

---

### Task 5.3: PR 5 open

- [ ] **Step 1: Full suite green, push, open PR**

```bash
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' -quiet
git push
gh pr create --title "feat(provocation): PR 5 — feedback UI + inspector review panel" \
  --body "$(cat <<'EOF'
Stacked on PR 4. Spec: docs/superpowers/specs/2026-04-17-proactive-surfacing-design.md

## Summary
- 👍/👎 buttons on provoked assistant messages, wired to GovernanceTelemetryStore.recordFeedback
- MemoryDebugInspector gains a "Judge events" tab with filter controls (All / Provoked / Not provoked / Failures / Bad JSON / Scope breach)
- Internal-only surface — not shipped to normal users

## Test plan
- [ ] Feedback button writes the expected row in judge_events
- [ ] Inspector filter produces the correct subset
- [ ] (Manual) Inspector renders recent verdicts after sending a few messages
EOF
)"
```

---

## PR 6 — Fixture Bank for Judgment-Quality Regression

### Task 6.1: Create fixture format + seed bank with 5 canonical scenarios

**Files:**
- Create: `Tests/NousTests/Fixtures/ProvocationScenarios/README.md`
- Create: 5 fixture JSON files in `Tests/NousTests/Fixtures/ProvocationScenarios/`
- Create: `scripts/run_provocation_fixtures.sh`

These fixtures are **not run in CI** — they require a real LLM call against a cloud provider with an API key. The script runs them on demand before every judge-prompt change. Regressions surface as diffs between produced verdicts and expected shapes.

- [ ] **Step 1: Create fixtures**

`Tests/NousTests/Fixtures/ProvocationScenarios/README.md`:

````markdown
# Provocation Scenarios

Hand-authored fixtures for judgment-quality regression checks on `ProvocationJudge`.

Each `*.json` file is one scenario. Format:

```json
{
  "name": "short-scenario-name",
  "user_message": "what the user said this turn",
  "chat_mode": "companion" | "strategist",
  "citable_pool": [
    { "id": "E1", "text": "…entry text…", "scope": "global" }
  ],
  "expected": {
    "should_provoke": true,
    "user_state": "deciding",
    "entry_id": "E1"
  }
}
```

The `expected` block asserts **shape only**, not exact wording. The runner (`scripts/run_provocation_fixtures.sh`) runs each scenario against the real judge and reports:
- ✅ if `should_provoke`, `user_state`, and (when expected) `entry_id` match
- ❌ with a diff otherwise

When you change the judge prompt, run the script and treat every ❌ as either:
(a) a regression (fix the prompt), or
(b) a legitimate behavior shift (update the fixture's `expected`).
````

`Tests/NousTests/Fixtures/ProvocationScenarios/01-clear-contradiction-deciding.json`:

```json
{
  "name": "01-clear-contradiction-deciding",
  "user_message": "I'm just going to go with the cheapest vendor — whatever gets us live this week.",
  "chat_mode": "companion",
  "citable_pool": [
    { "id": "E1", "text": "Alex has explicitly said multiple times he doesn't want to compete on price and wants to avoid anchoring on cheapest-wins.", "scope": "global" },
    { "id": "E2", "text": "Alex mentioned he prefers 松弛 coffee shops.", "scope": "global" }
  ],
  "expected": { "should_provoke": true, "user_state": "deciding", "entry_id": "E1" }
}
```

`Tests/NousTests/Fixtures/ProvocationScenarios/02-venting-no-interject.json`:

```json
{
  "name": "02-venting-no-interject",
  "user_message": "everything is falling apart today, nothing works, i'm exhausted",
  "chat_mode": "companion",
  "citable_pool": [
    { "id": "E1", "text": "Alex has worried about burning out before and said he wants to build at a sustainable pace.", "scope": "global" }
  ],
  "expected": { "should_provoke": false, "user_state": "venting" }
}
```

`Tests/NousTests/Fixtures/ProvocationScenarios/03-no-tension-benign-question.json`:

```json
{
  "name": "03-no-tension-benign-question",
  "user_message": "what time is it in Tokyo right now?",
  "chat_mode": "companion",
  "citable_pool": [
    { "id": "E1", "text": "Alex prefers morning coffee dark roast.", "scope": "global" }
  ],
  "expected": { "should_provoke": false }
}
```

`Tests/NousTests/Fixtures/ProvocationScenarios/04-soft-tension-strategist-provokes.json`:

```json
{
  "name": "04-soft-tension-strategist-provokes",
  "user_message": "I'm considering adding a referral program to grow faster",
  "chat_mode": "strategist",
  "citable_pool": [
    { "id": "E1", "text": "Last month Alex was skeptical of growth-first tactics and said he wanted to focus on retention before acquisition.", "scope": "project" }
  ],
  "expected": { "should_provoke": true, "user_state": "deciding", "entry_id": "E1" }
}
```

`Tests/NousTests/Fixtures/ProvocationScenarios/05-soft-tension-companion-quiet.json`:

```json
{
  "name": "05-soft-tension-companion-quiet",
  "user_message": "I'm considering adding a referral program to grow faster",
  "chat_mode": "companion",
  "citable_pool": [
    { "id": "E1", "text": "Last month Alex was skeptical of growth-first tactics and said he wanted to focus on retention before acquisition.", "scope": "project" }
  ],
  "expected": { "should_provoke": false }
}
```

> **Note:** fixtures 04 and 05 are paired — same message + pool, different chat mode — to directly exercise the ChatMode-dependent threshold rule.

- [ ] **Step 2: Create the runner script**

`scripts/run_provocation_fixtures.sh`:

```bash
#!/usr/bin/env bash
# Runs the provocation fixture bank against the real judge via a dedicated
# ad-hoc Swift entry point. Usage:
#   ANTHROPIC_API_KEY=... ./scripts/run_provocation_fixtures.sh
#
# Requires the app to have been built at least once so dependencies resolve.

set -euo pipefail
FIXTURES_DIR="$(dirname "$0")/../Tests/NousTests/Fixtures/ProvocationScenarios"

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "Set ANTHROPIC_API_KEY before running." >&2
  exit 1
fi

cd "$(dirname "$0")/.."

# Runs ProvocationFixtureRunner, a small executable target added alongside the main target.
# It iterates the directory, runs each fixture through ProvocationJudge, and prints diff rows.
xcodebuild -project Nous.xcodeproj -scheme ProvocationFixtureRunner \
  -destination 'platform=macOS' -quiet build-for-testing

DERIVED=$(xcodebuild -project Nous.xcodeproj -scheme ProvocationFixtureRunner \
  -destination 'platform=macOS' -showBuildSettings -quiet \
  | awk '/BUILT_PRODUCTS_DIR/ {print $3; exit}')

"$DERIVED/ProvocationFixtureRunner" "$FIXTURES_DIR"
```

Make it executable:

```bash
chmod +x scripts/run_provocation_fixtures.sh
```

- [ ] **Step 3: Add the `ProvocationFixtureRunner` executable target**

In Xcode (or via the pbxproj edit pattern already used in the repo), add a new **Command Line Tool** target `ProvocationFixtureRunner` that links against the `Nous` framework target. Its `main.swift`:

```swift
// Sources/ProvocationFixtureRunner/main.swift
import Foundation
import Nous

struct FixtureCase: Decodable {
    struct Pool: Decodable { let id: String; let text: String; let scope: String }
    struct Expected: Decodable {
        let shouldProvoke: Bool
        let userState: String?
        let entryId: String?
        enum CodingKeys: String, CodingKey {
            case shouldProvoke = "should_provoke"
            case userState = "user_state"
            case entryId = "entry_id"
        }
    }
    let name: String
    let userMessage: String
    let chatMode: String
    let citablePool: [Pool]
    let expected: Expected
    enum CodingKeys: String, CodingKey {
        case name
        case userMessage = "user_message"
        case chatMode = "chat_mode"
        case citablePool = "citable_pool"
        case expected
    }
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: ProvocationFixtureRunner <fixtures-dir>\n", stderr)
    exit(64)
}
let fixturesDir = URL(fileURLWithPath: CommandLine.arguments[1])

guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
    fputs("ANTHROPIC_API_KEY required.\n", stderr); exit(64)
}
let llm = ClaudeLLMService(apiKey: apiKey, model: "claude-haiku-4-5-20251001")
let judge = ProvocationJudge(llmService: llm, timeout: 5.0)

let files = try FileManager.default.contentsOfDirectory(at: fixturesDir,
    includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

var failures = 0

for file in files {
    let data = try Data(contentsOf: file)
    let fx = try JSONDecoder().decode(FixtureCase.self, from: data)
    let pool = fx.citablePool.map { CitableEntry(
        id: $0.id, text: $0.text,
        scope: MemoryScope(rawValue: $0.scope) ?? .global
    )}
    let mode = ChatMode(rawValue: fx.chatMode) ?? .companion

    do {
        let verdict = try await judge.judge(
            userMessage: fx.userMessage,
            citablePool: pool,
            chatMode: mode,
            provider: .claude
        )
        var diffs: [String] = []
        if verdict.shouldProvoke != fx.expected.shouldProvoke {
            diffs.append("should_provoke: got=\(verdict.shouldProvoke) want=\(fx.expected.shouldProvoke)")
        }
        if let wantState = fx.expected.userState, verdict.userState.rawValue != wantState {
            diffs.append("user_state: got=\(verdict.userState.rawValue) want=\(wantState)")
        }
        if let wantEntry = fx.expected.entryId, verdict.entryId != wantEntry {
            diffs.append("entry_id: got=\(verdict.entryId ?? "nil") want=\(wantEntry)")
        }
        if diffs.isEmpty {
            print("✅ \(fx.name)")
        } else {
            failures += 1
            print("❌ \(fx.name)")
            diffs.forEach { print("   \($0)") }
            print("   reason: \(verdict.reason)")
        }
    } catch {
        failures += 1
        print("💥 \(fx.name) — judge threw \(error)")
    }
}

print("")
print("\(files.count - failures)/\(files.count) passed")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 4: Commit**

```bash
git add Tests/NousTests/Fixtures/ProvocationScenarios/ \
        scripts/run_provocation_fixtures.sh \
        Sources/ProvocationFixtureRunner/ \
        Nous.xcodeproj/project.pbxproj
git commit -m "feat(provocation): seed fixture bank + ProvocationFixtureRunner"
```

- [ ] **Step 5: Document in the plan's PR body that the runner is manual, not CI.** Push and open PR:

```bash
git push
gh pr create --title "feat(provocation): PR 6 — judgment-quality fixture bank" \
  --body "$(cat <<'EOF'
Stacked on PR 3. Spec: docs/superpowers/specs/2026-04-17-proactive-surfacing-design.md

## Summary
- 5 seed fixtures exercising: clear contradiction, venting, no tension, strategist-provokes-on-soft, companion-stays-quiet-on-same
- ProvocationFixtureRunner executable that runs each fixture against the real judge and diffs against expected shape
- Manual runner (scripts/run_provocation_fixtures.sh) — NOT in CI, requires ANTHROPIC_API_KEY
- Intended workflow: run before every judge-prompt change, treat ❌s as either regressions to fix or intentional shifts to update

## Test plan
- [ ] Runner executes against all 5 fixtures without crashing (requires API key)
- [ ] Re-run after each judge-prompt edit; treat diffs as review items
EOF
)"
```

---

## Spec Coverage Audit

Cross-checking the spec against the plan:

| Spec requirement | Covered by |
|---|---|
| `ProvocationJudge` with structured JSON | Task 3.1 |
| `BehaviorProfile.supportive` / `.provocative` enum | Task 1.3 |
| `JudgeVerdict` struct | Task 1.1 |
| `CitableEntry` struct | Task 1.2 |
| Response orchestration in ChatViewModel | Tasks 4.1–4.4 |
| UserMemoryService.citableEntryPool | Task 2.2 |
| LLMService unchanged | Explicit no-change (see File Structure) |
| Materially extended GovernanceTelemetryStore | Task 1.5 |
| NodeStore judge_events table + helpers | Task 1.4 |
| ChatMode as explicit judge input | Task 3.1 (prompt includes chat_mode) |
| Data flow steps 1–8 | Tasks 4.2 (5a–5e), 4.3, 4.4 |
| Critical timing (1.5s timeout) | Task 3.1 (withTimeout helper), tests Task 3.1 |
| Citable Pool Retrieval Path (node-hit bridging) | Task 2.2 |
| Judge prompt contract (schema + rules + threshold) | Task 3.1 (buildPrompt) |
| BehaviorProfile contents (focus block guidance) | Task 1.3 + Task 4.2 (buildFocusBlock) |
| Error scenario 1 (timeout/api error) | Task 3.1 tests + Task 4.2 tests |
| Error scenario 2 (malformed JSON) | Task 3.1 tests |
| Error scenario 3 (unknown entry_id) | Task 4.2 test `testUnknownEntryIdForcesSupportiveAndLogsError` |
| Error scenario 4 (user feedback) | Task 5.1 |
| Cancellation API + wiring (conversation switch / VM teardown) | Tasks 4.3, 4.4 |
| Error scenario 6 (local provider) | Task 4.2 test `testLocalProviderSkipsJudge` |
| Testing strategy Layer 1 | Tasks 1.1, 1.4, 2.2, 3.1, 4.2, 4.3 |
| Testing strategy Layer 2 — fixture bank | Task 6.1 |
| Testing strategy Layer 2 — Inspector review panel | Task 5.2 |
| Telemetry substrate SQLite table | Task 1.4 |
| Dependencies — NodeStore migration | Task 1.4 |
| Dependencies — UserMemoryService.citableEntryPool | Task 2.2 |

No spec requirement is left without a task. The spec's "Out of scope" items (ask-back, stale-claim, out-of-chat nudges, markdown-in-bundle profiles, user-editable profiles, local-provider judge support, full ResponseOrchestrator extraction) are explicitly not in this plan.
