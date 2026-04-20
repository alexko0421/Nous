# Memory Retrieval vNext — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the only remaining Phase 1 gap — add a `provocation_kind: contradiction | spark | neutral` discriminator to `JudgeVerdict` so contradiction-oriented interjections can be reviewed separately, and reconcile a small spec/code mismatch around the annotation helper signature.

**Architecture:** `provocationKind` is **derived** in `ChatViewModel` from the verdict + the in-pool `contradictionCandidateIds` set, then stamped onto `verdictForLog` before encoding to `verdictJSON`. No `judge_events` schema migration — `verdictJSON` is already a TEXT blob (`Sources/Nous/Services/NodeStore.swift:172-173`). The LLM prompt is **not** asked to emit this field, keeping the judge contract small and deterministic. A `JudgeEventFilter.provocationKind(...)` query path uses the existing `json_extract(verdictJSON, '$.field')` pattern for the debug inspector picker.

**Tech Stack:** Swift 5.x, Xcode project (`Nous.xcodeproj`), in-memory SQLite for tests (`:memory:`), XCTest. Test command: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS'`.

**Spec:** [2026-04-18-memory-retrieval-vnext.md](/Users/kochunlong/conductor/workspaces/Nous/new-york/docs/superpowers/specs/2026-04-18-memory-retrieval-vnext.md)

---

## Status of Phase 1 Substrate (already shipped on `alexko0421/proactive-surfacing`, commit `1598b00`)

This plan is **not** greenfield. The bulk of the spec has already landed. Do not re-implement these:

| Spec item | Where it lives today |
|---|---|
| `MemoryKind.decision` / `.boundary` | `Sources/Nous/Models/MemoryEntry.swift:9` |
| `MemoryFactEntry` model + `memory_fact_entries` table + indexes | `Sources/Nous/Models/MemoryFactEntry.swift`, `Sources/Nous/Services/NodeStore.swift:155-198` |
| `contradictionRecallFacts(projectId:conversationId:)` | `Sources/Nous/Services/UserMemoryService.swift:381-401` |
| `annotateContradictionCandidates(currentMessage:facts:maxCandidates:)` | `Sources/Nous/Services/UserMemoryService.swift:406-441` |
| `citableEntryPool(...)` 3-lane assembly with graceful degradation | `Sources/Nous/Services/UserMemoryService.swift:1372-1438` |
| `[contradiction-candidate]` prompt marker | `Sources/Nous/Models/CitableEntry.swift:12`, `Sources/Nous/Services/ProvocationJudge.swift:72,102` |
| Wiring in send flow | `Sources/Nous/ViewModels/ChatViewModel.swift:280-340` |
| Backwards-compat for unknown `MemoryKind` rows | `Tests/NousTests/MemoryFactStoreTests.swift:164-200` |
| Governance refresh prompt limited to `decision/boundary/constraint` | `Sources/Nous/Services/UserMemoryService.swift:1030-1048` |

The **only** spec items still outstanding:
1. `provocation_kind` discriminator on `JudgeVerdict` + telemetry plumbing (§Success Metrics in spec)
2. Spec/code mismatch: spec says annotation helper returns `Set<String>`, code returns `[AnnotatedContradictionFact]` (§Provocation Hooks > A in spec)

Everything below addresses **only** those two items.

---

## File Map

### Modified files

| Path | Responsibility |
|---|---|
| `Sources/Nous/Models/JudgeVerdict.swift` | Add `ProvocationKind` enum + `provocationKind` field (default `.neutral`, decoded with fallback for old rows) |
| `Sources/Nous/ViewModels/ChatViewModel.swift` | Add `deriveProvocationKind(...)` static helper; stamp it onto `verdictForLog` before encoding |
| `Sources/Nous/Services/NodeStore.swift` | Add `JudgeEventFilter.provocationKind(ProvocationKind)` query branch |
| `Sources/Nous/Views/MemoryDebugInspector.swift` | Add three picker entries (Contradiction / Spark / Neutral) to the existing `JudgeEventsTab` filter menu |
| `docs/superpowers/specs/2026-04-18-memory-retrieval-vnext.md` | Update §Provocation Hooks > A to match the actual annotation signature |

### New tests

| Path | Responsibility |
|---|---|
| `Tests/NousTests/JudgeVerdictProvocationKindTests.swift` | Decode/encode + backwards-compat tests for `provocationKind` |
| `Tests/NousTests/ProvocationKindDerivationTests.swift` | Unit tests for `ChatViewModel.deriveProvocationKind(...)` |

### Modified tests

| Path | Responsibility |
|---|---|
| `Tests/NousTests/JudgeEventsStoreTests.swift` | Add `provocationKind` filter test against `recentJudgeEvents` |
| `Tests/NousTests/ProvocationOrchestrationTests.swift` | Add one orchestration test asserting the persisted `verdictJSON` carries the derived kind |

### Untouched-but-existing call sites that must keep compiling

These construct `JudgeVerdict(...)` today. Adding the new field with a **default `provocationKind: ProvocationKind = .neutral`** in the memberwise init means none of them need edits — but verify they still compile after Task 1:

- `Tests/NousTests/JudgeEventsStoreTests.swift:24`
- `Tests/NousTests/ProvocationOrchestrationTests.swift:32, 134, 158, 192, 212, 385, 434, 483, 523, 593, 607, 614, 630, 699, 714, 770`

---

## PR Structure

Single PR. Roughly ~250 lines including tests. Stack on top of the current `alexko0421/proactive-surfacing` branch.

---

## Task 1: Add `ProvocationKind` enum + `provocationKind` field on `JudgeVerdict`

**Files:**
- Modify: `Sources/Nous/Models/JudgeVerdict.swift`
- Create: `Tests/NousTests/JudgeVerdictProvocationKindTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/NousTests/JudgeVerdictProvocationKindTests.swift`:

```swift
import XCTest
@testable import Nous

final class JudgeVerdictProvocationKindTests: XCTestCase {

    func testDefaultProvocationKindIsNeutralWhenConstructedWithoutField() {
        let verdict = JudgeVerdict(
            tensionExists: false,
            userState: .exploring,
            shouldProvoke: false,
            entryId: nil,
            reason: "no tension",
            inferredMode: .companion
        )
        XCTAssertEqual(verdict.provocationKind, .neutral)
    }

    func testEncodeIncludesProvocationKindKey() throws {
        var verdict = JudgeVerdict(
            tensionExists: true,
            userState: .deciding,
            shouldProvoke: true,
            entryId: "E1",
            reason: "pricing conflict",
            inferredMode: .strategist
        )
        verdict.provocationKind = .contradiction

        let data = try JSONEncoder().encode(verdict)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"provocation_kind\":\"contradiction\""),
                      "encoded verdict must carry provocation_kind under snake_case key, got: \(json)")
    }

    func testDecodeOldVerdictWithoutProvocationKindFallsBackToNeutral() throws {
        // verdictJSON shape from before this field existed.
        let legacyJSON = """
        {"tension_exists":true,"user_state":"deciding","should_provoke":true,
         "entry_id":"E1","reason":"old row","inferred_mode":"strategist"}
        """
        let data = legacyJSON.data(using: .utf8)!
        let verdict = try JSONDecoder().decode(JudgeVerdict.self, from: data)
        XCTAssertEqual(verdict.provocationKind, .neutral,
                       "old judge_events rows missing provocation_kind must decode safely as neutral")
    }

    func testDecodeRoundTripPreservesProvocationKind() throws {
        var original = JudgeVerdict(
            tensionExists: true,
            userState: .deciding,
            shouldProvoke: true,
            entryId: "E1",
            reason: "spark",
            inferredMode: .companion
        )
        original.provocationKind = .spark

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JudgeVerdict.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' \
  -only-testing:NousTests/JudgeVerdictProvocationKindTests
```
Expected: build error — `JudgeVerdict has no member 'provocationKind'`.

- [ ] **Step 3: Add the enum + field with backwards-compatible decode**

Replace the contents of `Sources/Nous/Models/JudgeVerdict.swift` with:

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

/// Review discriminator stamped onto a verdict by `ChatViewModel` before it is
/// persisted into `judge_events.verdictJSON`. Not emitted by the LLM judge —
/// derived deterministically from `shouldProvoke` and whether the cited entry
/// was a contradiction candidate this turn.
enum ProvocationKind: String, Codable, CaseIterable {
    case contradiction
    case spark
    case neutral
}

struct JudgeVerdict: Codable, Equatable {
    let tensionExists: Bool
    let userState: UserState
    let shouldProvoke: Bool
    let entryId: String?
    let reason: String
    let inferredMode: ChatMode
    var provocationKind: ProvocationKind

    init(
        tensionExists: Bool,
        userState: UserState,
        shouldProvoke: Bool,
        entryId: String?,
        reason: String,
        inferredMode: ChatMode,
        provocationKind: ProvocationKind = .neutral
    ) {
        self.tensionExists = tensionExists
        self.userState = userState
        self.shouldProvoke = shouldProvoke
        self.entryId = entryId
        self.reason = reason
        self.inferredMode = inferredMode
        self.provocationKind = provocationKind
    }

    enum CodingKeys: String, CodingKey {
        case tensionExists = "tension_exists"
        case userState = "user_state"
        case shouldProvoke = "should_provoke"
        case entryId = "entry_id"
        case reason
        case inferredMode = "inferred_mode"
        case provocationKind = "provocation_kind"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tensionExists = try c.decode(Bool.self, forKey: .tensionExists)
        self.userState = try c.decode(UserState.self, forKey: .userState)
        self.shouldProvoke = try c.decode(Bool.self, forKey: .shouldProvoke)
        self.entryId = try c.decodeIfPresent(String.self, forKey: .entryId)
        self.reason = try c.decode(String.self, forKey: .reason)
        self.inferredMode = try c.decode(ChatMode.self, forKey: .inferredMode)
        self.provocationKind = try c.decodeIfPresent(ProvocationKind.self, forKey: .provocationKind) ?? .neutral
    }
}
```

- [ ] **Step 4: Run the new tests**

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' \
  -only-testing:NousTests/JudgeVerdictProvocationKindTests
```
Expected: PASS, 4/4.

- [ ] **Step 5: Run the full suite to confirm no existing call site broke**

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS'
```
Expected: PASS — every existing `JudgeVerdict(...)` constructor still compiles because `provocationKind` defaults to `.neutral`. If anything fails, the call site in question was using a non-memberwise init somehow; fix by appending `, provocationKind: .neutral` rather than removing the default.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Models/JudgeVerdict.swift Tests/NousTests/JudgeVerdictProvocationKindTests.swift
git commit -m "feat(judge): add ProvocationKind discriminator on JudgeVerdict"
```

---

## Task 2: Add `deriveProvocationKind(...)` static helper on `ChatViewModel`

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Create: `Tests/NousTests/ProvocationKindDerivationTests.swift`

The derivation rule is:
- `shouldProvoke == false` → `.neutral`
- `shouldProvoke == true` AND `entryId` is present AND `entryId ∈ contradictionCandidateIds` → `.contradiction`
- `shouldProvoke == true` otherwise → `.spark`

- [ ] **Step 1: Write the failing tests**

Create `Tests/NousTests/ProvocationKindDerivationTests.swift`:

```swift
import XCTest
@testable import Nous

final class ProvocationKindDerivationTests: XCTestCase {

    func testNeutralWhenShouldProvokeFalse() {
        let verdict = JudgeVerdict(
            tensionExists: true, userState: .deciding,
            shouldProvoke: false, entryId: "E1",
            reason: "tension but venting elsewhere", inferredMode: .companion
        )
        XCTAssertEqual(
            ChatViewModel.deriveProvocationKind(verdict: verdict, contradictionCandidateIds: ["E1"]),
            .neutral
        )
    }

    func testContradictionWhenCitedEntryWasFlaggedCandidate() {
        let verdict = JudgeVerdict(
            tensionExists: true, userState: .deciding,
            shouldProvoke: true, entryId: "E1",
            reason: "cuts against earlier decision", inferredMode: .strategist
        )
        XCTAssertEqual(
            ChatViewModel.deriveProvocationKind(verdict: verdict, contradictionCandidateIds: ["E1", "E2"]),
            .contradiction
        )
    }

    func testSparkWhenProvokingButCitedEntryWasNotFlagged() {
        let verdict = JudgeVerdict(
            tensionExists: true, userState: .exploring,
            shouldProvoke: true, entryId: "E9",
            reason: "latent connection worth surfacing", inferredMode: .strategist
        )
        XCTAssertEqual(
            ChatViewModel.deriveProvocationKind(verdict: verdict, contradictionCandidateIds: ["E1", "E2"]),
            .spark
        )
    }

    func testSparkWhenProvokingWithoutEntryId() {
        let verdict = JudgeVerdict(
            tensionExists: true, userState: .deciding,
            shouldProvoke: true, entryId: nil,
            reason: "schema violation but flagged anyway", inferredMode: .strategist
        )
        XCTAssertEqual(
            ChatViewModel.deriveProvocationKind(verdict: verdict, contradictionCandidateIds: []),
            .spark
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' \
  -only-testing:NousTests/ProvocationKindDerivationTests
```
Expected: build error — `ChatViewModel has no member 'deriveProvocationKind'`.

- [ ] **Step 3: Add the static helper**

In `Sources/Nous/ViewModels/ChatViewModel.swift`, add this static helper near the other `static func` helpers in the type (e.g., next to `shouldAllowInteractiveClarification`, `assembleContext`, `governanceTrace`). Pick whichever location keeps the file's existing grouping convention:

```swift
/// Derives the review discriminator stamped onto verdictJSON. Pure function;
/// kept static so it is independently testable without spinning up the full
/// view model.
static func deriveProvocationKind(
    verdict: JudgeVerdict,
    contradictionCandidateIds: Set<String>
) -> ProvocationKind {
    guard verdict.shouldProvoke else { return .neutral }
    if let id = verdict.entryId, contradictionCandidateIds.contains(id) {
        return .contradiction
    }
    return .spark
}
```

- [ ] **Step 4: Run the new tests**

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' \
  -only-testing:NousTests/ProvocationKindDerivationTests
```
Expected: PASS, 4/4.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift Tests/NousTests/ProvocationKindDerivationTests.swift
git commit -m "feat(judge): derive provocation kind from verdict + candidate set"
```

---

## Task 3: Wire derivation into the send flow + orchestration test

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift` (around lines 313–455)
- Modify: `Tests/NousTests/ProvocationOrchestrationTests.swift`

The mutation point is **before** `verdictJSONStr` is encoded at `Sources/Nous/ViewModels/ChatViewModel.swift:443-448`. The set already exists in scope as `contradictionCandidateIds` (declared at line ~295). Mutate `verdictForLog` once, then let the existing encoder run.

- [ ] **Step 1: Write the failing orchestration test**

In `Tests/NousTests/ProvocationOrchestrationTests.swift`, add a new test method (place it next to existing tests that already construct `JudgeVerdict(...)` and inspect `judge_events`). Reuse the existing test scaffolding — do not invent a new harness:

```swift
func testProvocationKindStampedOntoVerdictJSONForContradictionMatch() async throws {
    // ARRANGE: a memory_fact_entry whose id will be the cited entry, AND an in-pool
    // contradiction-candidate id set covering it (the existing test scaffolding builds
    // both via citableEntryPool / contradictionCandidateIds — match the pattern used
    // by the surrounding "judge selects entryId X" tests in this file).
    let cited = makeFactEntry(content: "Do not compete on price.", kind: .decision)
    try store.insertMemoryFactEntry(cited)

    // The orchestration test stub feeds nextVerdict back unchanged — wire it to provoke
    // and cite the seeded entry id.
    judge.nextVerdict = JudgeVerdict(
        tensionExists: true, userState: .deciding,
        shouldProvoke: true, entryId: cited.id.uuidString,
        reason: "cuts against earlier decision", inferredMode: .strategist
    )

    // ACT
    try await sendUserMessage("Maybe we should compete on price after all.")

    // ASSERT: persisted verdictJSON carries provocation_kind = contradiction.
    let events = try store.recentJudgeEvents(limit: 1, filter: .none)
    XCTAssertEqual(events.count, 1)
    let json = events[0].verdictJSON
    XCTAssertTrue(json.contains("\"provocation_kind\":\"contradiction\""),
                  "verdictJSON should be stamped with derived provocation_kind, got: \(json)")
}
```

> **Note for the implementer:** the helper names (`makeFactEntry`, `sendUserMessage`, `store`, `judge`) above mirror the surrounding tests in this file. If the existing test class uses different names, **rename to match** rather than introducing new helpers. The only new behavior asserted is the `provocation_kind` substring in the persisted blob.

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' \
  -only-testing:NousTests/ProvocationOrchestrationTests/testProvocationKindStampedOntoVerdictJSONForContradictionMatch
```
Expected: FAIL — verdictJSON does not contain `provocation_kind`.

- [ ] **Step 3: Wire the derivation into the send flow**

In `Sources/Nous/ViewModels/ChatViewModel.swift`, locate the block at lines 442-448:

```swift
        // Step F: Append the judge_events row using effectiveMode.
        // BEFORE the main call so the row survives main-call failure.
        let verdictJSONStr: String = {
            if let v = verdictForLog, let data = try? JSONEncoder().encode(v) {
                return String(data: data, encoding: .utf8) ?? "{}"
            }
            return "{}"
        }()
```

Insert the derivation immediately before that closure, so the encoded payload picks it up:

```swift
        // Step F: Append the judge_events row using effectiveMode.
        // BEFORE the main call so the row survives main-call failure.
        if verdictForLog != nil {
            verdictForLog?.provocationKind = ChatViewModel.deriveProvocationKind(
                verdict: verdictForLog!,
                contradictionCandidateIds: contradictionCandidateIds
            )
        }
        let verdictJSONStr: String = {
            if let v = verdictForLog, let data = try? JSONEncoder().encode(v) {
                return String(data: data, encoding: .utf8) ?? "{}"
            }
            return "{}"
        }()
```

> **Why mutate before encode rather than re-derive at read time:** the derivation depends on `contradictionCandidateIds` which is per-turn state. Stamping at write time freezes the discriminator with the row, so review tooling reading old `judge_events` rows back gets the correct value without recomputing pool composition retroactively.

- [ ] **Step 4: Run the new test**

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' \
  -only-testing:NousTests/ProvocationOrchestrationTests/testProvocationKindStampedOntoVerdictJSONForContradictionMatch
```
Expected: PASS.

- [ ] **Step 5: Run the full ProvocationOrchestrationTests class to catch regressions**

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' \
  -only-testing:NousTests/ProvocationOrchestrationTests
```
Expected: PASS for every test in the class. The default `provocationKind: .neutral` keeps existing assertions about `verdictJSON` content stable as long as those assertions are not exact-string equality on the full blob; if any test does compare the full JSON exactly, update its expectation to include `"provocation_kind":"<derived value>"`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift Tests/NousTests/ProvocationOrchestrationTests.swift
git commit -m "feat(judge): stamp derived provocation_kind onto verdictJSON before persist"
```

---

## Task 4: Add `JudgeEventFilter.provocationKind(...)` query branch

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift` (lines 1117–1197)
- Modify: `Tests/NousTests/JudgeEventsStoreTests.swift`

- [ ] **Step 1: Write the failing test**

In `Tests/NousTests/JudgeEventsStoreTests.swift`, add this test method:

```swift
func testRecentJudgeEventsFiltersByProvocationKind() throws {
    // Insert three events: one contradiction, one spark, one neutral.
    let nodeId = UUID()
    func encoded(_ kind: ProvocationKind, shouldProvoke: Bool, entryId: String?) -> String {
        var v = JudgeVerdict(
            tensionExists: shouldProvoke,
            userState: shouldProvoke ? .deciding : .exploring,
            shouldProvoke: shouldProvoke,
            entryId: entryId,
            reason: "fixture",
            inferredMode: .strategist
        )
        v.provocationKind = kind
        let data = try! JSONEncoder().encode(v)
        return String(data: data, encoding: .utf8)!
    }

    try store.appendJudgeEvent(JudgeEvent(
        id: UUID(), ts: Date(timeIntervalSince1970: 10),
        nodeId: nodeId, messageId: nil,
        chatMode: .strategist, provider: .openai,
        verdictJSON: encoded(.contradiction, shouldProvoke: true, entryId: "E1"),
        fallbackReason: .ok, userFeedback: nil, feedbackTs: nil
    ))
    try store.appendJudgeEvent(JudgeEvent(
        id: UUID(), ts: Date(timeIntervalSince1970: 20),
        nodeId: nodeId, messageId: nil,
        chatMode: .strategist, provider: .openai,
        verdictJSON: encoded(.spark, shouldProvoke: true, entryId: "E2"),
        fallbackReason: .ok, userFeedback: nil, feedbackTs: nil
    ))
    try store.appendJudgeEvent(JudgeEvent(
        id: UUID(), ts: Date(timeIntervalSince1970: 30),
        nodeId: nodeId, messageId: nil,
        chatMode: .companion, provider: .openai,
        verdictJSON: encoded(.neutral, shouldProvoke: false, entryId: nil),
        fallbackReason: .ok, userFeedback: nil, feedbackTs: nil
    ))

    let contradictionOnly = try store.recentJudgeEvents(
        limit: 50,
        filter: .provocationKind(.contradiction)
    )
    XCTAssertEqual(contradictionOnly.count, 1)
    XCTAssertTrue(contradictionOnly[0].verdictJSON.contains("\"provocation_kind\":\"contradiction\""))

    let sparkOnly = try store.recentJudgeEvents(
        limit: 50,
        filter: .provocationKind(.spark)
    )
    XCTAssertEqual(sparkOnly.count, 1)
}
```

> **Note:** if `JudgeEventsStoreTests.swift` constructs the test `store` differently from this snippet (different ivar name, setUp pattern, available `LLMProvider` cases), match the surrounding conventions — only the `recentJudgeEvents(filter: .provocationKind(...))` assertions are new.

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' \
  -only-testing:NousTests/JudgeEventsStoreTests/testRecentJudgeEventsFiltersByProvocationKind
```
Expected: build error — `JudgeEventFilter has no case 'provocationKind'`.

- [ ] **Step 3: Add the new filter case + query branch**

In `Sources/Nous/Services/NodeStore.swift`, update the enum declaration around line 1117:

```swift
enum JudgeEventFilter: Equatable, Hashable {
    case none
    case fallback(JudgeFallbackReason)
    case shouldProvoke(Bool)
    case userState(UserState)
    case provocationKind(ProvocationKind)
}
```

In the same file, update `recentJudgeEvents(limit:filter:)` (around lines 1159–1197). Add the where-clause branch and the bind branch alongside the existing cases:

```swift
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
        case .provocationKind:
            whereClause = "WHERE json_extract(verdictJSON, '$.provocation_kind') = ?"
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
            try stmt.bind(limit, at: 1)
        case .fallback(let reason):
            try stmt.bind(reason.rawValue, at: 1)
            try stmt.bind(limit, at: 2)
        case .shouldProvoke(let flag):
            try stmt.bind(flag ? 1 : 0, at: 1)
            try stmt.bind(limit, at: 2)
        case .userState(let state):
            try stmt.bind(state.rawValue, at: 1)
            try stmt.bind(limit, at: 2)
        case .provocationKind(let kind):
            try stmt.bind(kind.rawValue, at: 1)
            try stmt.bind(limit, at: 2)
        }
        var out: [JudgeEvent] = []
        while try stmt.step() {
            if let ev = judgeEventFrom(stmt) { out.append(ev) }
        }
        return out
    }
```

- [ ] **Step 4: Run the new test**

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' \
  -only-testing:NousTests/JudgeEventsStoreTests/testRecentJudgeEventsFiltersByProvocationKind
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/NodeStore.swift Tests/NousTests/JudgeEventsStoreTests.swift
git commit -m "feat(judge): filter judge_events by provocation_kind"
```

---

## Task 5: Surface the new filter in `MemoryDebugInspector`

**Files:**
- Modify: `Sources/Nous/Views/MemoryDebugInspector.swift` (around lines 678–691)

This is a UI-only change. No new test — the picker is exercised by hand from the debug menu, and the filter logic itself is covered by Task 4.

- [ ] **Step 1: Add three picker entries**

In `Sources/Nous/Views/MemoryDebugInspector.swift`, the existing `Picker("Filter", selection: $filter) { ... }` block (lines 681–688) lists six options today. Append three more so the contradiction/spark/neutral split is one click away during review:

```swift
                Picker("Filter", selection: $filter) {
                    Text("All").tag(JudgeEventFilter.none)
                    Text("Provoked").tag(JudgeEventFilter.shouldProvoke(true))
                    Text("Not provoked").tag(JudgeEventFilter.shouldProvoke(false))
                    Text("Contradiction").tag(JudgeEventFilter.provocationKind(.contradiction))
                    Text("Spark").tag(JudgeEventFilter.provocationKind(.spark))
                    Text("Neutral").tag(JudgeEventFilter.provocationKind(.neutral))
                    Text("Failures").tag(JudgeEventFilter.fallback(.timeout))
                    Text("Bad JSON").tag(JudgeEventFilter.fallback(.badJSON))
                    Text("Scope breach").tag(JudgeEventFilter.fallback(.unknownEntryId))
                }
```

- [ ] **Step 2: Build and confirm the inspector compiles**

```bash
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual smoke check (skip if dogfood time is short)**

Open Nous, send a few messages until at least one judge event is produced, open the Memory Debug Inspector → Judge Events tab, switch the picker to "Contradiction" / "Spark" / "Neutral" in turn, and confirm the list filters as expected.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Views/MemoryDebugInspector.swift
git commit -m "feat(inspector): add provocation_kind filter to judge events tab"
```

---

## Task 6: Reconcile spec ↔ code mismatch on `annotateContradictionCandidates`

**Files:**
- Modify: `docs/superpowers/specs/2026-04-18-memory-retrieval-vnext.md` (line 210)

The spec currently claims:

```
preferred home: `UserMemoryService.annotateContradictionCandidates(pool: [CitableEntry], userMessage: String) -> Set<String>` (or an equivalent retrieval-layer helper) — returns the IDs of up to 3 entries flagged as contradiction candidates by relative ranking within the pool. Prompt builder consumes the set when emitting `[contradiction-candidate] id=<entry-id>` markers. Keeps annotation logic out of prompt formatting code.
```

The actual signature in `Sources/Nous/Services/UserMemoryService.swift:406-410` is:

```swift
func annotateContradictionCandidates(
    currentMessage: String,
    facts: [MemoryFactEntry],
    maxCandidates: Int = 3
) -> [AnnotatedContradictionFact]
```

…and `ChatViewModel` then derives the `Set<String>` of IDs at the call site (`Sources/Nous/ViewModels/ChatViewModel.swift:295-300`) for `citableEntryPool`. The wrapper return type (carrying `relevanceScore`) is the better shape because the inspector and future ask-back work both want the score, not just the IDs.

- [ ] **Step 1: Replace the bullet on line 210 of the spec**

Open `docs/superpowers/specs/2026-04-18-memory-retrieval-vnext.md` and replace the `- preferred home:` bullet under §Provocation Hooks > A with this exact text:

```markdown
- preferred home: `UserMemoryService.annotateContradictionCandidates(currentMessage: String, facts: [MemoryFactEntry], maxCandidates: Int = 3) -> [AnnotatedContradictionFact]`. Returns each in-pool fact wrapped with an `isContradictionCandidate` flag and a relative `relevanceScore` so the debug inspector and any future ask-back surface can both read scores back. The call site (today: `ChatViewModel`) collects flagged IDs into a `Set<String>` and feeds them to `citableEntryPool(...)` via `contradictionCandidateIds:`, which is what becomes the `[contradiction-candidate] id=<entry-id>` prompt marker. Keeps annotation ranking out of prompt formatting code.
```

- [ ] **Step 2: Verify the update**

```bash
grep -n "annotateContradictionCandidates" docs/superpowers/specs/2026-04-18-memory-retrieval-vnext.md
```
Expected: one line matching the new signature; no leftover `Set<String>` claim.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-04-18-memory-retrieval-vnext.md
git commit -m "docs(spec): reconcile annotateContradictionCandidates signature with code"
```

---

## Task 7: Final whole-suite check + push

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite**

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS'
```
Expected: every test passes. Pay particular attention to:

- `JudgeVerdictProvocationKindTests` (Task 1)
- `ProvocationKindDerivationTests` (Task 2)
- `ProvocationOrchestrationTests` (Task 3 + regression coverage)
- `JudgeEventsStoreTests` (Task 4)
- `ContradictionRecallTests` and `MemoryFactStoreTests` (no changes — must still pass)

- [ ] **Step 2: Run the build for the app target**

```bash
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED. Confirms the inspector picker compiles in app context, not just test context.

- [ ] **Step 3: Confirm `git status` is clean and stack is shippable**

```bash
git status
git log --oneline alexko0421/proactive-surfacing..HEAD
```
Expected: 6 commits on top of `alexko0421/proactive-surfacing`, working tree clean.

---

## Success Criteria

This plan is complete when:

- `JudgeVerdict` carries `provocationKind: ProvocationKind` and decodes pre-existing `judge_events` rows safely as `.neutral`.
- Every persisted `verdictJSON` blob from a new turn includes a `provocation_kind` key whose value is derived deterministically from the verdict + contradiction-candidate set.
- The Memory Debug Inspector can filter judge events by Contradiction / Spark / Neutral with one picker change.
- The spec section on `annotateContradictionCandidates` matches the signature actually in source.
- All existing tests (governance, fact store, contradiction recall, orchestration, judge events) still pass.

## Do Not Expand

If implementation drifts into any of the following, stop and open a follow-up plan:

- Asking the LLM judge to emit `provocation_kind` in its output JSON (the whole point is keeping the judge contract small and the discriminator deterministic).
- Adding a dedicated `provocationKind` SQLite column on `judge_events` (the blob comment at `NodeStore.swift:172-173` is a deliberate design choice — `json_extract` is enough).
- Re-deriving `provocationKind` at read time (then old rows would lose their stamp when pool composition changes upstream).
- Touching `ProvocationJudge.swift` prompt text — Phase 1 keeps the LLM contract unchanged.
- Backfilling old `judge_events` rows. They decode as `.neutral`; that is correct because we cannot reconstruct the historical contradiction-candidate set after the fact.
