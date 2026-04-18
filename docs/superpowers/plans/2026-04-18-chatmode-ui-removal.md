# ChatMode UI Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the Companion/Strategist UI picker and let `ProvocationJudge` pick per-turn `ChatMode` with soft continuity bias.

**Architecture:** The per-turn judge already runs in `ChatViewModel.send()` before the main LLM call. We extend `JudgeVerdict` with `inferredMode`, swap the judge's `chatMode` input for `previousMode: ChatMode?`, reorder `send()` so the verdict drives context framing, and hydrate `activeChatMode` from the newest `judge_events` row on conversation load. The UI picker and its bindings are deleted.

**Tech Stack:** Swift 6, SwiftUI, macOS 26 app target, XCTest, XcodeGen project, SQLite (via custom `NodeStore`), `xcodebuild` CLI.

**Spec:** `docs/superpowers/specs/2026-04-17-chatmode-ui-removal-design.md` (commit `11a999a`).

---

## Preflight

Before starting Task 1, verify the working tree is clean and you're on a fresh feature branch off the latest base.

- [ ] **Preflight Step 1: Confirm clean working tree**

Run: `git status`
Expected: `nothing to commit, working tree clean`

- [ ] **Preflight Step 2: Create the feature branch**

Fork off `alexko0421/proactive-surfacing` (the design commits live there; `main` may or may not have merged it yet).

```bash
git checkout -b alexko0421/chatmode-ui-removal
git status
```
Expected: `On branch alexko0421/chatmode-ui-removal`

- [ ] **Preflight Step 3: Confirm baseline tests pass**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -quiet 2>&1 | tail -20`
Expected: Ends with `** TEST SUCCEEDED **`. If it fails, stop and fix the regression before proceeding — every task below assumes a green baseline.

---

## File Structure

Files this plan creates, modifies, or deletes.

**Create:**
- (none — all work extends existing files)

**Modify:**
- `Sources/Nous/Models/JudgeVerdict.swift` — add `inferredMode` field + `CodingKeys` entry
- `Sources/Nous/Services/ProvocationJudge.swift` — rename `chatMode` param to `previousMode: ChatMode?`, rewrite prompt
- `Sources/Nous/Services/NodeStore.swift` — add `latestChatMode(forNode:)` query method
- `Sources/Nous/ViewModels/ChatViewModel.swift` — `activeChatMode: ChatMode?`, remove `setChatMode`, reorder `send()`, hydrate on load/new, hardcode `.companion` in `beginQuickActionConversation`
- `Sources/Nous/Views/WelcomeView.swift` — strip `selectedChatMode` + `onChatModeSelected` params and the `ChatModePicker` call
- `Sources/Nous/Views/ChatArea.swift` — strip the two bindings passed to `WelcomeView` and the standalone `ChatModePicker` above the input
- `Sources/ProvocationFixtureRunner/main.swift` — rename fixture input field to `previous_mode` (optional), decode `expected.inferred_mode`, pass `previousMode:` to the judge, diff-report `inferred_mode`
- `Tests/NousTests/ProvocationOrchestrationTests.swift` — new tests covering new behavior; `StubJudge` signature updated
- `Tests/NousTests/Fixtures/ProvocationScenarios/01-clear-contradiction-deciding.json` through `05-soft-tension-companion-quiet.json` — rename `chat_mode` → `previous_mode`, add `expected.inferred_mode`

**Delete:**
- `Sources/Nous/Views/ChatModePicker.swift`

**Create (test fixtures):**
- `Tests/NousTests/Fixtures/ProvocationScenarios/06-register-shift-snaps-back.json`

---

## Task 1: JudgeVerdict gains `inferredMode`

**Why first:** All downstream work (judge prompt, fixture runner, tests) references this field. Making the change additively first keeps the codebase compiling between tasks.

**Files:**
- Modify: `Sources/Nous/Models/JudgeVerdict.swift`
- Modify: `Tests/NousTests/ProvocationOrchestrationTests.swift` (update `StubJudge`'s default verdict + any test-site `JudgeVerdict(...)` constructions)

- [ ] **Step 1.1: Write the failing decode test**

Add to `Tests/NousTests/ProvocationOrchestrationTests.swift`, inside the existing `ProvocationOrchestrationTests` class:

```swift
func testJudgeVerdictParsesInferredMode() throws {
    let json = """
    {
      "tension_exists": true,
      "user_state": "deciding",
      "should_provoke": true,
      "entry_id": "E1",
      "reason": "pricing conflict",
      "inferred_mode": "strategist"
    }
    """.data(using: .utf8)!

    let verdict = try JSONDecoder().decode(JudgeVerdict.self, from: json)

    XCTAssertEqual(verdict.inferredMode, .strategist)
    XCTAssertEqual(verdict.shouldProvoke, true)
    XCTAssertEqual(verdict.userState, .deciding)
}
```

- [ ] **Step 1.2: Run test to verify it fails**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ProvocationOrchestrationTests/testJudgeVerdictParsesInferredMode 2>&1 | tail -10`
Expected: Compile error — `inferredMode` is not a member of `JudgeVerdict`.

- [ ] **Step 1.3: Add the field to `JudgeVerdict`**

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

struct JudgeVerdict: Codable, Equatable {
    let tensionExists: Bool
    let userState: UserState
    let shouldProvoke: Bool
    let entryId: String?
    let reason: String
    let inferredMode: ChatMode

    enum CodingKeys: String, CodingKey {
        case tensionExists = "tension_exists"
        case userState = "user_state"
        case shouldProvoke = "should_provoke"
        case entryId = "entry_id"
        case reason
        case inferredMode = "inferred_mode"
    }
}
```

Note: `ChatMode` already conforms to `String, CaseIterable` but not `Codable`. Add `Codable` conformance by changing `Sources/Nous/Models/ChatMode.swift` line 3 from:

```swift
enum ChatMode: String, CaseIterable {
```

to:

```swift
enum ChatMode: String, Codable, CaseIterable {
```

- [ ] **Step 1.4: Update `StubJudge` default verdict to include `inferredMode`**

In `Tests/NousTests/ProvocationOrchestrationTests.swift`, find `StubJudge` (currently around line 22-29):

```swift
final class StubJudge: Judging {
    var nextVerdict: JudgeVerdict?
    var nextError: JudgeError?
    func judge(userMessage: String, citablePool: [CitableEntry], chatMode: ChatMode, provider: LLMProvider) async throws -> JudgeVerdict {
        if let err = nextError { throw err }
        return nextVerdict ?? JudgeVerdict(tensionExists: false, userState: .exploring, shouldProvoke: false, entryId: nil, reason: "stub default")
    }
}
```

Replace the `return` line with:

```swift
        return nextVerdict ?? JudgeVerdict(tensionExists: false, userState: .exploring, shouldProvoke: false, entryId: nil, reason: "stub default", inferredMode: .companion)
```

- [ ] **Step 1.5: Fix any other `JudgeVerdict(...)` construction sites**

Run: `grep -rn "JudgeVerdict(" Sources Tests | grep -v "JudgeVerdict.self"`

For every hit that uses positional / named init without `inferredMode:`, append `, inferredMode: .companion` (pick whichever mode keeps existing test intent — `.companion` is the safe default). Do NOT change the `Decodable` test JSON strings — those get `inferred_mode` added in the respective fixture/test tasks.

Expected hits to patch (from prior exploration, verify with grep before editing):
- `Tests/NousTests/ProvocationOrchestrationTests.swift` — `judge.nextVerdict = JudgeVerdict(...)` in `testShouldProvokeTrueInjectsFocusBlock` (~line 79) and similar in other tests.

Example transform:
```swift
// BEFORE
judge.nextVerdict = JudgeVerdict(
    tensionExists: true, userState: .deciding,
    shouldProvoke: true, entryId: entryId.uuidString,
    reason: "pricing conflict"
)
// AFTER
judge.nextVerdict = JudgeVerdict(
    tensionExists: true, userState: .deciding,
    shouldProvoke: true, entryId: entryId.uuidString,
    reason: "pricing conflict",
    inferredMode: .companion
)
```

- [ ] **Step 1.6: Run the new test to verify it passes**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ProvocationOrchestrationTests/testJudgeVerdictParsesInferredMode 2>&1 | tail -5`
Expected: `Test Suite 'Selected tests' passed`

- [ ] **Step 1.7: Run the full test suite to confirm no regressions**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -quiet 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 1.8: Commit**

```bash
git add Sources/Nous/Models/JudgeVerdict.swift Sources/Nous/Models/ChatMode.swift Tests/NousTests/ProvocationOrchestrationTests.swift
git commit -m "feat(judge): add inferred_mode field to JudgeVerdict"
```

---

## Task 2: Rename `chatMode` → `previousMode` on Judging protocol

**Why:** Prepares the judge call to carry the prior turn's mode (or nil on first turn). Pure rename; prompt semantics change in Task 3.

**Files:**
- Modify: `Sources/Nous/Services/ProvocationJudge.swift`
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift` (one call site)
- Modify: `Sources/ProvocationFixtureRunner/main.swift` (one call site)
- Modify: `Tests/NousTests/ProvocationOrchestrationTests.swift` (`StubJudge` signature)

- [ ] **Step 2.1: Update the `Judging` protocol and `ProvocationJudge.judge(...)`**

In `Sources/Nous/Services/ProvocationJudge.swift`, lines 10-17:

```swift
// BEFORE
protocol Judging {
    func judge(
        userMessage: String,
        citablePool: [CitableEntry],
        chatMode: ChatMode,
        provider: LLMProvider
    ) async throws -> JudgeVerdict
}
```

Replace with:

```swift
protocol Judging {
    func judge(
        userMessage: String,
        citablePool: [CitableEntry],
        previousMode: ChatMode?,
        provider: LLMProvider
    ) async throws -> JudgeVerdict
}
```

And in the same file, lines 30-36:

```swift
// BEFORE
func judge(
    userMessage: String,
    citablePool: [CitableEntry],
    chatMode: ChatMode,
    provider: LLMProvider
) async throws -> JudgeVerdict {
    let systemPrompt = Self.buildPrompt(pool: citablePool, chatMode: chatMode)
```

Replace with:

```swift
func judge(
    userMessage: String,
    citablePool: [CitableEntry],
    previousMode: ChatMode?,
    provider: LLMProvider
) async throws -> JudgeVerdict {
    let systemPrompt = Self.buildPrompt(pool: citablePool, previousMode: previousMode)
```

And rename the static prompt builder signature on line 66:

```swift
// BEFORE
static func buildPrompt(pool: [CitableEntry], chatMode: ChatMode) -> String {
```

Replace with:

```swift
static func buildPrompt(pool: [CitableEntry], previousMode: ChatMode?) -> String {
```

Inside `buildPrompt`, find lines 97-98:

```swift
// BEFORE
        CHAT_MODE
        \(chatMode.rawValue)
```

Replace with:

```swift
        PREVIOUS TURN MODE
        \(previousMode?.rawValue ?? "none (first turn)")
```

(Prompt rules still reference `CHAT_MODE` for now — Task 3 rewrites them.)

- [ ] **Step 2.2: Update `StubJudge` signature**

In `Tests/NousTests/ProvocationOrchestrationTests.swift`:

```swift
// BEFORE
func judge(userMessage: String, citablePool: [CitableEntry], chatMode: ChatMode, provider: LLMProvider) async throws -> JudgeVerdict {
```

Replace with:

```swift
func judge(userMessage: String, citablePool: [CitableEntry], previousMode: ChatMode?, provider: LLMProvider) async throws -> JudgeVerdict {
```

- [ ] **Step 2.3: Update `ChatViewModel.send()` call site**

In `Sources/Nous/ViewModels/ChatViewModel.swift`, find the judge invocation (around line 368-374):

```swift
// BEFORE
let task = Task { () async throws -> JudgeVerdict in
    try await judge.judge(
        userMessage: promptQuery,
        citablePool: citablePool,
        chatMode: activeChatMode,
        provider: currentProvider
    )
}
```

Replace with:

```swift
let task = Task { () async throws -> JudgeVerdict in
    try await judge.judge(
        userMessage: promptQuery,
        citablePool: citablePool,
        previousMode: activeChatMode,
        provider: currentProvider
    )
}
```

(At this point `activeChatMode` is still `ChatMode` non-optional; Task 4 makes it optional. The rename compiles fine either way — `ChatMode` is a valid `ChatMode?`.)

- [ ] **Step 2.4: Update fixture runner call site**

In `Sources/ProvocationFixtureRunner/main.swift`, find the call (around lines 69-74):

```swift
// BEFORE
let verdict = try await judge.judge(
    userMessage: fx.userMessage,
    citablePool: pool,
    chatMode: mode,
    provider: .claude
)
```

Replace with:

```swift
let verdict = try await judge.judge(
    userMessage: fx.userMessage,
    citablePool: pool,
    previousMode: mode,
    provider: .claude
)
```

(Fixture JSON schema rename comes in Task 8; `mode` here is still decoded from `chat_mode` input for now.)

- [ ] **Step 2.5: Run the full test suite**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -quiet 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **` — behavior is unchanged, this is a rename.

- [ ] **Step 2.6: Commit**

```bash
git add Sources/Nous/Services/ProvocationJudge.swift Sources/Nous/ViewModels/ChatViewModel.swift Sources/ProvocationFixtureRunner/main.swift Tests/NousTests/ProvocationOrchestrationTests.swift
git commit -m "refactor(judge): rename chatMode param to previousMode on Judging protocol"
```

---

## Task 3: Rewrite judge prompt with continuity bias + `inferred_mode` output

**Why:** This is where the judge actually starts choosing the mode. Prompt now describes continuity bias, adds `inferred_mode` to the output schema, and removes the old `CHAT_MODE`-dependent threshold rule in favor of a single rule that uses `inferred_mode` internally.

**Files:**
- Modify: `Sources/Nous/Services/ProvocationJudge.swift` (only `buildPrompt`)

- [ ] **Step 3.1: Replace the prompt body**

In `Sources/Nous/Services/ProvocationJudge.swift`, replace the entire `return """..."""` block inside `buildPrompt(pool:previousMode:)` (lines 76-104) with:

```swift
        return """
        You are a silent judge deciding (a) whether Nous should interject during its next reply, and (b) what framing mode the next reply should use.
        Do NOT address the user. Your entire output is one JSON object exactly matching the schema below — nothing before or after.

        SCHEMA
        {
          "tension_exists": true | false,
          "user_state": "deciding" | "exploring" | "venting",
          "should_provoke": true | false,
          "entry_id": "<id from citable entries>" | null,
          "reason": "<short natural-language reason>",
          "inferred_mode": "companion" | "strategist"
        }

        RULES (must hold in your output)
        - should_provoke = true REQUIRES: tension_exists = true, user_state != "venting", and entry_id is a real id from CITABLE ENTRIES below.
        - user_state = "venting" FORCES should_provoke = false regardless of any tension. Venting is not a moment to challenge.
        - entry_id MUST be copied verbatim from the `id=` field of one CITABLE ENTRY. Do not invent.
        - inferred_mode-dependent threshold (apply to YOUR OWN inferred_mode choice):
          * strategist → if tension_exists is true AND user_state ∈ {deciding, exploring}, set should_provoke = true. Soft tensions count.
          * companion  → only set should_provoke = true when the tension is strong AND clearly relevant to a decision the user is making. Soft tensions → false.

        MODE INFERENCE
        Pick inferred_mode based on the user's register in the message below:
        - companion: casual, emotional, reflective, open-ended, asking for warmth or reassurance.
        - strategist: analytical, decomposing a problem, asking for structure, planning, tradeoff weighing.
        Prefer CONTINUITY with the previous turn — only switch if the user's register clearly shifted (e.g. casual-emotional → structured-analytical, or vice versa). Small drift within one register is NOT a switch.

        PREVIOUS TURN MODE
        \(previousMode?.rawValue ?? "none (first turn)")

        CITABLE ENTRIES
        \(poolText)

        USER MESSAGE (next after this system block)
        """
```

- [ ] **Step 3.2: Run the full test suite**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -quiet 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`. Existing tests use `StubJudge` so they don't exercise the prompt; real-prompt validation happens via the fixture bank (Task 8).

- [ ] **Step 3.3: Commit**

```bash
git add Sources/Nous/Services/ProvocationJudge.swift
git commit -m "feat(judge): add continuity-biased mode inference to judge prompt"
```

---

## Task 4: `NodeStore.latestChatMode(forNode:)`

**Why:** Hydration source for `activeChatMode` when a conversation is loaded or switched. Independent of the `send()` flow; can land standalone.

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift`
- Modify: `Tests/NousTests/ProvocationOrchestrationTests.swift` (new tests)

- [ ] **Step 4.1: Write the failing tests**

Append to `Tests/NousTests/ProvocationOrchestrationTests.swift`, inside the test class:

```swift
func testLatestChatModeReturnsNewestRow() throws {
    let nodeId = UUID()
    let node = NousNode(id: nodeId, type: .conversation, title: "t", projectId: nil)
    try store.insertNode(node)

    let now = Date()
    let e1 = JudgeEvent(
        id: UUID(), ts: now.addingTimeInterval(-10), nodeId: nodeId, messageId: nil,
        chatMode: .companion, provider: .claude,
        verdictJSON: "{}", fallbackReason: .ok, userFeedback: nil, feedbackTs: nil
    )
    let e2 = JudgeEvent(
        id: UUID(), ts: now, nodeId: nodeId, messageId: nil,
        chatMode: .strategist, provider: .claude,
        verdictJSON: "{}", fallbackReason: .ok, userFeedback: nil, feedbackTs: nil
    )
    try store.appendJudgeEvent(e1)
    try store.appendJudgeEvent(e2)

    XCTAssertEqual(try store.latestChatMode(forNode: nodeId), .strategist)
}

func testLatestChatModeReturnsNilWhenNoRows() throws {
    let nodeId = UUID()
    XCTAssertNil(try store.latestChatMode(forNode: nodeId))
}
```

- [ ] **Step 4.2: Run tests to verify they fail**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ProvocationOrchestrationTests/testLatestChatModeReturnsNewestRow 2>&1 | tail -10`
Expected: Compile error — `latestChatMode(forNode:)` does not exist.

- [ ] **Step 4.3: Implement the query**

In `Sources/Nous/Services/NodeStore.swift`, add this method inside the same extension that contains `appendJudgeEvent` (near the end of the file, before the final `}`):

```swift
func latestChatMode(forNode nodeId: UUID) throws -> ChatMode? {
    let stmt = try db.prepare("""
        SELECT chatMode FROM judge_events
        WHERE nodeId = ?
        ORDER BY ts DESC
        LIMIT 1;
    """)
    try stmt.bind(nodeId.uuidString, at: 1)
    guard try stmt.step() else { return nil }
    let raw = try stmt.string(at: 0)
    return ChatMode(rawValue: raw)
}
```

- [ ] **Step 4.4: Run the new tests to verify they pass**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ProvocationOrchestrationTests/testLatestChatModeReturnsNewestRow -only-testing:NousTests/ProvocationOrchestrationTests/testLatestChatModeReturnsNilWhenNoRows 2>&1 | tail -10`
Expected: Both tests pass.

- [ ] **Step 4.5: Run the full suite**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -quiet 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4.6: Commit**

```bash
git add Sources/Nous/Services/NodeStore.swift Tests/NousTests/ProvocationOrchestrationTests.swift
git commit -m "feat(nodestore): add latestChatMode(forNode:) query"
```

---

## Task 5: `activeChatMode` becomes optional + delete `ChatModePicker` UI

**Why:** Two changes bundled because the test target depends on the Nous app target — removing `setChatMode` from the view model without simultaneously removing the `vm.setChatMode(mode)` call in `ChatArea.swift` would break the test build. Landing both together keeps green.

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Modify: `Sources/Nous/Views/WelcomeView.swift`
- Modify: `Sources/Nous/Views/ChatArea.swift`
- Delete: `Sources/Nous/Views/ChatModePicker.swift`

- [ ] **Step 5.1: Change the type and initial value of `activeChatMode`**

In `Sources/Nous/ViewModels/ChatViewModel.swift`, find line 16:

```swift
// BEFORE
var activeChatMode: ChatMode = .companion
```

Replace with:

```swift
var activeChatMode: ChatMode? = nil
```

- [ ] **Step 5.2: Remove the `setChatMode(_:)` method**

Find lines 105-107:

```swift
// BEFORE
func setChatMode(_ mode: ChatMode) {
    activeChatMode = mode
}
```

Delete the method entirely.

- [ ] **Step 5.3: Patch all `activeChatMode` read sites — unwrap with `.companion` fallback**

This preserves current behavior; Task 6 later replaces these with `effectiveMode`. For each of the following lines, change `activeChatMode` → `activeChatMode ?? .companion`:

Line 131 (`beginQuickActionConversation`, `assembleContext` call):
```swift
// BEFORE
    chatMode: activeChatMode,
// AFTER
    chatMode: activeChatMode ?? .companion,
```

Line 155 (`beginQuickActionConversation`, `governanceTrace` call): same transform.

Line 287 (`send`, `assembleContext` call): same transform.

Line 312 (`send`, `governanceTrace` call): same transform.

Line 372 (`send`, judge call argument `previousMode: activeChatMode`): NO CHANGE — the judge expects `ChatMode?`, so passing the optional directly is correct and matches Task 2.

Line 434 (`send`, `JudgeEvent(chatMode:)` field):
```swift
// BEFORE
    chatMode: activeChatMode, provider: currentProvider,
// AFTER
    chatMode: activeChatMode ?? .companion, provider: currentProvider,
```

- [ ] **Step 5.4: Delete `ChatModePicker.swift`**

```bash
git rm Sources/Nous/Views/ChatModePicker.swift
```

- [ ] **Step 5.5: Strip `WelcomeView.swift`**

In `Sources/Nous/Views/WelcomeView.swift`, delete these three lines:

Line 6:
```swift
    let selectedChatMode: ChatMode
```

Line 11:
```swift
    let onChatModeSelected: (ChatMode) -> Void
```

Line 70:
```swift
                        ChatModePicker(selectedMode: selectedChatMode, onSelect: onChatModeSelected)
```

Verify there's no orphan blank line left behind.

- [ ] **Step 5.6: Strip `ChatArea.swift`**

In `Sources/Nous/Views/ChatArea.swift`, delete:

Line 42 (inside the `WelcomeView(...)` construction):
```swift
                    selectedChatMode: vm.activeChatMode,
```

Line 47 (the callback passed to WelcomeView):
```swift
                    onChatModeSelected: { mode in vm.setChatMode(mode) },
```

Lines 128-130 (the standalone picker above the input):
```swift
                        ChatModePicker(selectedMode: vm.activeChatMode) { mode in
                            vm.setChatMode(mode)
                        }
```

- [ ] **Step 5.7: Confirm no stale references remain**

Run: `grep -rn "ChatModePicker\|onChatModeSelected\|selectedChatMode\|setChatMode" Sources Tests`
Expected: no hits (not even in test code).

- [ ] **Step 5.8: Build the app**

Run: `xcodebuild build -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' -quiet 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5.9: Run the full test suite**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -quiet 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5.10: Smoke-test the UI manually**

Open `Nous.xcodeproj` in Xcode, run the app, and verify:
- Welcome screen no longer shows the Companion/Strategist chips.
- Quick-action chips (Direction / Brainstorm / Mental Health) still render and work.
- Typing a message and sending produces a reply (no crash from missing mode UI).

- [ ] **Step 5.11: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift Sources/Nous/Views/WelcomeView.swift Sources/Nous/Views/ChatArea.swift
git commit -m "refactor(chat): activeChatMode optional; remove ChatModePicker UI"
```

---

## Task 6: Reorder `send()` — judge-first → effectiveMode → context → state update → main call

**Why:** Core of the spec (D3). The old flow assembled context with `activeChatMode` (stale) before the judge ran; the new flow lets the judge's `inferredMode` drive context framing AND the activeChatMode update happens BEFORE the main LLM call so retry-without-reload sees the freshly-judged mode.

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Modify: `Tests/NousTests/ProvocationOrchestrationTests.swift` (new tests)

### 6A: Write the new tests first

- [ ] **Step 6.1: Add `testFirstTurnPassesNilPreviousMode`**

Append inside `ProvocationOrchestrationTests` class. This depends on a recording StubJudge — extend `StubJudge` to capture args:

First, update `StubJudge` in the same file:

```swift
final class StubJudge: Judging {
    var nextVerdict: JudgeVerdict?
    var nextError: JudgeError?
    var lastReceivedPreviousMode: ChatMode? = nil
    var previousModeHistory: [ChatMode?] = []

    func judge(userMessage: String, citablePool: [CitableEntry], previousMode: ChatMode?, provider: LLMProvider) async throws -> JudgeVerdict {
        lastReceivedPreviousMode = previousMode
        previousModeHistory.append(previousMode)
        if let err = nextError { throw err }
        return nextVerdict ?? JudgeVerdict(tensionExists: false, userState: .exploring, shouldProvoke: false, entryId: nil, reason: "stub default", inferredMode: .companion)
    }
}
```

Then add the test:

```swift
func testFirstTurnPassesNilPreviousMode() async throws {
    // Fresh viewModel — activeChatMode starts nil
    XCTAssertNil(viewModel.activeChatMode)

    judge.nextVerdict = JudgeVerdict(
        tensionExists: false, userState: .exploring, shouldProvoke: false,
        entryId: nil, reason: "first turn", inferredMode: .companion
    )
    viewModel.inputText = "hello"
    await viewModel.send()

    XCTAssertEqual(judge.previousModeHistory.count, 1)
    XCTAssertNil(judge.previousModeHistory[0],
                 "first send() must pass previousMode: nil to the judge")
}
```

- [ ] **Step 6.2: Add `testSecondTurnPassesPriorInferredMode`**

```swift
func testSecondTurnPassesPriorInferredMode() async throws {
    judge.nextVerdict = JudgeVerdict(
        tensionExists: false, userState: .exploring, shouldProvoke: false,
        entryId: nil, reason: "t1", inferredMode: .strategist
    )
    viewModel.inputText = "help me think this through"
    await viewModel.send()

    // T2: judge should receive previousMode == .strategist (from T1's inferredMode)
    judge.nextVerdict = JudgeVerdict(
        tensionExists: false, userState: .exploring, shouldProvoke: false,
        entryId: nil, reason: "t2", inferredMode: .strategist
    )
    viewModel.inputText = "continue"
    await viewModel.send()

    XCTAssertEqual(judge.previousModeHistory.count, 2)
    XCTAssertNil(judge.previousModeHistory[0])
    XCTAssertEqual(judge.previousModeHistory[1], .strategist)
}
```

- [ ] **Step 6.3: Add `testSystemPromptUsesEffectiveModeNotPriorActiveMode`**

```swift
func testSystemPromptUsesEffectiveModeNotPriorActiveMode() async throws {
    // Seed prior state: activeChatMode = .companion
    viewModel.activeChatMode = .companion

    // Judge flips to strategist for this turn
    judge.nextVerdict = JudgeVerdict(
        tensionExists: false, userState: .deciding, shouldProvoke: false,
        entryId: nil, reason: "register shift", inferredMode: .strategist
    )
    viewModel.inputText = "break this down for me"
    await viewModel.send()

    let system = llm.receivedSystem ?? ""
    XCTAssertTrue(system.contains("STRATEGIST MODE"),
                  "assembleContext must have run with verdict.inferredMode (.strategist), not prior activeChatMode (.companion)")
    XCTAssertFalse(system.contains("COMPANION MODE"),
                   "prior mode must not leak into this turn's system prompt")
}
```

- [ ] **Step 6.4: Add `testLocalProviderFallbackKeepsActiveMode`**

```swift
func testLocalProviderFallbackKeepsActiveMode() async throws {
    // Switch the VM to .local provider via a fresh VM (providerProvider is captured in closure)
    let localLLM = CannedLLMService()
    let vectorStore = VectorStore(nodeStore: store)
    let memoryService = UserMemoryService(nodeStore: store, llmServiceProvider: { localLLM })
    let localVM = ChatViewModel(
        nodeStore: store,
        vectorStore: vectorStore,
        embeddingService: EmbeddingService(),
        graphEngine: GraphEngine(nodeStore: store, vectorStore: vectorStore),
        userMemoryService: memoryService,
        userMemoryScheduler: UserMemoryScheduler(service: memoryService),
        llmServiceProvider: { localLLM },
        currentProviderProvider: { .local },
        judgeLLMServiceFactory: { CannedLLMService() },
        provocationJudgeFactory: { _ in self.judge },
        governanceTelemetry: telemetry
    )
    localVM.activeChatMode = .strategist  // simulate prior judged state

    localVM.inputText = "hi"
    await localVM.send()

    // Judge does NOT run on .local, so activeChatMode should be unchanged
    XCTAssertEqual(localVM.activeChatMode, .strategist)
    // And the event row's chatMode should reflect the fallback (prior mode), not nil/.companion
    let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
    XCTAssertEqual(events.last?.chatMode, .strategist)
    XCTAssertEqual(events.last?.fallbackReason, .providerLocal)
}
```

- [ ] **Step 6.5: Add `testJudgeTimeoutFallbackKeepsActiveMode`**

```swift
func testJudgeTimeoutFallbackKeepsActiveMode() async throws {
    viewModel.activeChatMode = .strategist
    judge.nextError = .timeout

    viewModel.inputText = "hi"
    await viewModel.send()

    // Judge threw .timeout → effectiveMode = activeChatMode ?? .companion = .strategist
    XCTAssertEqual(viewModel.activeChatMode, .strategist)
    let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
    XCTAssertEqual(events.last?.chatMode, .strategist)
    XCTAssertEqual(events.last?.fallbackReason, .timeout)
}
```

- [ ] **Step 6.6: Add `testActiveChatModeUpdatedBeforeMainCall`**

This test uses a failing main LLM to prove runtime state survives main-call failure.

```swift
func testActiveChatModeUpdatedBeforeMainCall() async throws {
    // Arrange: judge will pick strategist; main LLM will fail
    viewModel.activeChatMode = .companion
    judge.nextVerdict = JudgeVerdict(
        tensionExists: false, userState: .deciding, shouldProvoke: false,
        entryId: nil, reason: "shift", inferredMode: .strategist
    )
    llm.nextError = NSError(domain: "test", code: 1)

    viewModel.inputText = "hi"
    await viewModel.send()

    // Main call errored, but activeChatMode must reflect the freshly-judged mode
    XCTAssertEqual(viewModel.activeChatMode, .strategist,
                   "activeChatMode must be updated before the main LLM call so retry-without-reload has correct previousMode")
}
```

This requires `CannedLLMService` to support `nextError` if it doesn't already. Check by reading `CannedLLMService` near the top of the test file (lines 8-19) and add if missing:

```swift
final class CannedLLMService: LLMService {
    var scriptedChunks: [String] = []
    var receivedSystem: String?
    var nextError: Error?

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        receivedSystem = system
        if let err = nextError { throw err }
        let chunks = scriptedChunks
        return AsyncThrowingStream { cont in
            for chunk in chunks { cont.yield(chunk) }
            cont.finish()
        }
    }
}
```

Keep any other fields that currently exist; only add `nextError` and the guard in `generate`.

- [ ] **Step 6.7: Add `testJudgeEventAppendedBeforeMainCall`**

```swift
func testJudgeEventAppendedBeforeMainCall() async throws {
    judge.nextVerdict = JudgeVerdict(
        tensionExists: false, userState: .exploring, shouldProvoke: false,
        entryId: nil, reason: "t", inferredMode: .companion
    )
    llm.nextError = NSError(domain: "test", code: 1)

    viewModel.inputText = "hi"
    await viewModel.send()

    // Main LLM threw → judge_events row must still exist
    let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
    XCTAssertEqual(events.count, 1, "judge_events row must persist even when main LLM call fails")
    XCTAssertEqual(events.first?.fallbackReason, .ok)
}
```

- [ ] **Step 6.8: Run the new tests to verify they fail**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ProvocationOrchestrationTests/testFirstTurnPassesNilPreviousMode 2>&1 | tail -10`
Expected: FAIL — `send()` currently uses `activeChatMode` ≠ `nil` semantics; the recording `previousModeHistory` is set up but assertions about first-turn nil, continuity, and pre-main state update will not hold yet.

### 6B: Reorder the `send()` flow

The change rewrites roughly lines 247-440 of `ChatViewModel.swift`. Work carefully and reference the spec's D3 ordered steps.

- [ ] **Step 6.9: Replace the `send()` body from the citable-pool step through the `judge_events` append**

In `Sources/Nous/ViewModels/ChatViewModel.swift`, locate the section of `send()` that runs from the `// Step 5: Assemble context` comment (around line 283) through `governanceTelemetry.appendJudgeEvent(event)` (around line 438).

Replace that entire block with the reordered flow below. The block you are replacing contains: assembleContext call, governanceTrace call, citable pool gather, judge call, profile/focusBlock derivation, finalSystem composition, and appendJudgeEvent. The new block produces identical outputs but in spec-D3 order.

```swift
    // --- BEGIN reordered send flow (per spec D3) ---

    // Step A: Gather the citable pool (needed by the judge).
    let nodeHits = citations.map { $0.node.id }
    let citablePool = (try? userMemoryService.citableEntryPool(
        projectId: node.projectId,
        conversationId: node.id,
        nodeHits: nodeHits
    )) ?? []

    // Step B: Run the judge (or skip on .local).
    let currentProvider = currentProviderProvider()
    let eventId = UUID()
    var verdictForLog: JudgeVerdict?
    var fallbackReason: JudgeFallbackReason = .ok
    var profile: BehaviorProfile = .supportive
    var focusBlock: String? = nil
    var inferredMode: ChatMode? = nil

    if currentProvider == .local {
        fallbackReason = .providerLocal
    } else if let judgeLLM = judgeLLMServiceFactory() {
        inFlightJudgeTask?.cancel()

        let judge = provocationJudgeFactory(judgeLLM)
        let taskId = UUID()
        let task = Task { () async throws -> JudgeVerdict in
            try await judge.judge(
                userMessage: promptQuery,
                citablePool: citablePool,
                previousMode: activeChatMode,
                provider: currentProvider
            )
        }
        inFlightJudgeTask = task
        inFlightJudgeTaskId = taskId

        do {
            let verdict = try await task.value
            verdictForLog = verdict
            inferredMode = verdict.inferredMode

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

        if inFlightJudgeTaskId == taskId {
            inFlightJudgeTask = nil
            inFlightJudgeTaskId = nil
        }
    } else {
        fallbackReason = .judgeUnavailable
    }

    // Step C: Decide the effective mode for this turn.
    let effectiveMode: ChatMode = inferredMode ?? (activeChatMode ?? .companion)

    // Step D: Assemble context + governance trace using effectiveMode.
    let shouldAllowInteractiveClarification = activeQuickActionMode != nil
    let context = ChatViewModel.assembleContext(
        chatMode: effectiveMode,
        currentUserInput: promptQuery,
        globalMemory: userMemoryService.currentGlobal(),
        essentialStory: userMemoryService.currentEssentialStory(
            projectId: node.projectId,
            excludingConversationId: node.id
        ),
        userModel: userMemoryService.currentUserModel(
            projectId: node.projectId,
            conversationId: node.id
        ),
        memoryEvidence: userMemoryService.currentBoundedEvidence(
            projectId: node.projectId,
            excludingConversationId: node.id
        ),
        projectMemory: node.projectId.flatMap { userMemoryService.currentProject(projectId: $0) },
        conversationMemory: userMemoryService.currentConversation(nodeId: node.id),
        recentConversations: recentConversations,
        citations: citations,
        projectGoal: projectGoal,
        attachments: attachments,
        activeQuickActionMode: activeQuickActionMode,
        allowInteractiveClarification: shouldAllowInteractiveClarification
    )
    let promptTrace = ChatViewModel.governanceTrace(
        chatMode: effectiveMode,
        currentUserInput: promptQuery,
        globalMemory: userMemoryService.currentGlobal(),
        essentialStory: userMemoryService.currentEssentialStory(
            projectId: node.projectId,
            excludingConversationId: node.id
        ),
        userModel: userMemoryService.currentUserModel(
            projectId: node.projectId,
            conversationId: node.id
        ),
        memoryEvidence: userMemoryService.currentBoundedEvidence(
            projectId: node.projectId,
            excludingConversationId: node.id
        ),
        projectMemory: node.projectId.flatMap { userMemoryService.currentProject(projectId: $0) },
        conversationMemory: userMemoryService.currentConversation(nodeId: node.id),
        recentConversations: recentConversations,
        citations: citations,
        projectGoal: projectGoal,
        attachments: attachments,
        activeQuickActionMode: activeQuickActionMode,
        allowInteractiveClarification: shouldAllowInteractiveClarification
    )
    lastPromptGovernanceTrace = promptTrace
    governanceTelemetry.recordPromptTrace(promptTrace)

    // Step E: Compose final system prompt.
    var finalSystemParts: [String] = [context, profile.contextBlock]
    if let fb = focusBlock { finalSystemParts.append(fb) }
    let finalSystem = finalSystemParts.joined(separator: "\n\n")

    // Step F: Append the judge_events row using effectiveMode.
    // Do this BEFORE the main call so the row (and mode-hydration source) survives main-call failure.
    let verdictJSONStr: String = {
        if let v = verdictForLog, let data = try? JSONEncoder().encode(v) {
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        return "{}"
    }()
    let event = JudgeEvent(
        id: eventId, ts: Date(), nodeId: node.id, messageId: nil,
        chatMode: effectiveMode, provider: currentProvider,
        verdictJSON: verdictJSONStr, fallbackReason: fallbackReason,
        userFeedback: nil, feedbackTs: nil
    )
    governanceTelemetry.appendJudgeEvent(event)

    // Step G: Persist runtime activeChatMode NOW, before the main call.
    // Retry-without-reload must see the freshly-judged mode as previousMode on the next send.
    activeChatMode = effectiveMode

    // --- END reordered send flow ---
```

**Important context for the implementer:** this block replaces:
1. The old Step 5 (assembleContext + governanceTrace), old lines 283-333 — moved below the judge.
2. The old Step 5b (citable pool), old lines 335-340 — moved above the judge.
3. The old Step 5c (judge call), old lines 342-418 — kept, but the judge input changed from `chatMode: activeChatMode` to `previousMode: activeChatMode` (verify this is already the case from Task 2) and the new `inferredMode` is captured.
4. The old Step 5d + 5e (final system + appendJudgeEvent), old lines 420-440 — kept but moved after context assembly and after runtime-state update.

The Step 6-onward parts of the old `send()` (build LLMMessage array, get LLM, stream, save message, patch judgeEvent messageId, embedding background task) are **unchanged** and stay below this block.

- [ ] **Step 6.10: Remove the pre-judge citable-pool and judge-invocation blocks that are now duplicated**

Because steps A and B above have been moved UP, you must delete the original duplicated blocks that lived further down. Search for the second occurrence of `// Step 5b: assemble citable pool for the judge` and `// Step 5c: call the judge` in your edited file and delete them along with everything through the original `governanceTelemetry.appendJudgeEvent(event)`. The file should now read: `-- reordered send flow --` block → (old Step 6: build LLMMessage array) → rest.

Equivalent check: run `grep -n "citablePool" Sources/Nous/ViewModels/ChatViewModel.swift`. You should see exactly one occurrence of the pool definition inside `send()` (in Step A of the new block).

- [ ] **Step 6.11: Run the full test suite**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -quiet 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`. The 7 new tests (6.1–6.7) should now pass, and the existing suite should still pass.

If tests fail:
- `testFirstTurnPassesNilPreviousMode` failure → verify `activeChatMode: ChatMode? = nil` and that `send()` passes `previousMode: activeChatMode` (not `.companion` default).
- `testActiveChatModeUpdatedBeforeMainCall` failure → the `activeChatMode = effectiveMode` assignment must be BEFORE the `llm.generate` call in Step H, not after.
- `testSystemPromptUsesEffectiveModeNotPriorActiveMode` failure → verify `assembleContext(chatMode: effectiveMode, ...)` not `activeChatMode`.
- `testLocalProviderFallbackKeepsActiveMode` failure → on `.local`, `inferredMode` stays nil, so `effectiveMode = activeChatMode ?? .companion = .strategist`; `activeChatMode = effectiveMode` leaves it `.strategist`. Verify this path.

- [ ] **Step 6.12: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift Tests/NousTests/ProvocationOrchestrationTests.swift
git commit -m "feat(chat): judge drives per-turn ChatMode with continuity bias"
```

---

## Task 7: Conversation-switch hydration

**Why:** `activeChatMode` is runtime-only. Without this, switching between conversations would let the prior one's mode bleed into the new one.

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Modify: `Tests/NousTests/ProvocationOrchestrationTests.swift`

- [ ] **Step 7.1: Write the failing tests**

```swift
func testLoadConversationHydratesFromLatestEvent() throws {
    let node = NousNode(type: .conversation, title: "t", projectId: nil)
    try store.insertNode(node)

    let event = JudgeEvent(
        id: UUID(), ts: Date(), nodeId: node.id, messageId: nil,
        chatMode: .strategist, provider: .claude,
        verdictJSON: "{}", fallbackReason: .ok, userFeedback: nil, feedbackTs: nil
    )
    try store.appendJudgeEvent(event)

    viewModel.loadConversation(node)

    XCTAssertEqual(viewModel.activeChatMode, .strategist)
}

func testLoadConversationKeepsNilWhenNoEvents() throws {
    let node = NousNode(type: .conversation, title: "t", projectId: nil)
    try store.insertNode(node)

    // Seed something unrelated first so we know we're testing empty-for-this-node, not empty-table
    viewModel.activeChatMode = .strategist

    viewModel.loadConversation(node)

    XCTAssertNil(viewModel.activeChatMode)
}

func testStartNewConversationResetsToNil() throws {
    viewModel.activeChatMode = .strategist
    viewModel.startNewConversation(title: "new", projectId: nil)
    XCTAssertNil(viewModel.activeChatMode)
}
```

- [ ] **Step 7.2: Run tests — expect failure**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ProvocationOrchestrationTests/testLoadConversationHydratesFromLatestEvent 2>&1 | tail -10`
Expected: FAIL — `activeChatMode` still holds prior state.

- [ ] **Step 7.3: Update `loadConversation` and `startNewConversation`**

In `Sources/Nous/ViewModels/ChatViewModel.swift`, modify `loadConversation` (around lines 91-99):

```swift
// BEFORE
@MainActor
func loadConversation(_ node: NousNode) {
    cancelInFlightJudge()
    currentNode = node
    messages = (try? nodeStore.fetchMessages(nodeId: node.id)) ?? []
    citations = []
    currentResponse = ""
    activeQuickActionMode = nil
}
```

Replace with:

```swift
@MainActor
func loadConversation(_ node: NousNode) {
    cancelInFlightJudge()
    currentNode = node
    messages = (try? nodeStore.fetchMessages(nodeId: node.id)) ?? []
    citations = []
    currentResponse = ""
    activeQuickActionMode = nil
    activeChatMode = (try? nodeStore.latestChatMode(forNode: node.id)) ?? nil
}
```

And `startNewConversation` (around lines 74-89). Add one line at the end:

```swift
@MainActor
func startNewConversation(title: String = "New Conversation", projectId: UUID? = nil) {
    cancelInFlightJudge()
    let node = NousNode(
        type: .conversation,
        title: title,
        projectId: projectId
    )
    try? nodeStore.insertNode(node)
    currentNode = node
    messages = []
    citations = []
    currentResponse = ""
    activeQuickActionMode = nil
    activeChatMode = nil  // NEW: brand-new chat has no prior judgment
    NotificationCenter.default.post(name: .nousNodesDidChange, object: nil)
}
```

- [ ] **Step 7.4: Run the new tests**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ProvocationOrchestrationTests/testLoadConversationHydratesFromLatestEvent -only-testing:NousTests/ProvocationOrchestrationTests/testLoadConversationKeepsNilWhenNoEvents -only-testing:NousTests/ProvocationOrchestrationTests/testStartNewConversationResetsToNil 2>&1 | tail -10`
Expected: All three pass.

- [ ] **Step 7.5: Run the full suite**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -quiet 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7.6: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift Tests/NousTests/ProvocationOrchestrationTests.swift
git commit -m "feat(chat): hydrate activeChatMode from judge_events on load; reset on new"
```

---

## Task 8: Quick-action opener hardcodes `.companion` and skips the judge

**Why:** The quick-action chips trigger a canned opening LLM call before the user has typed anything. There's no user message to judge. Per spec D7, hardcode `.companion` and do not run the judge; `activeChatMode` stays `nil` so the user's first real reply afterward is still a genuine first judged turn.

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift` (only `beginQuickActionConversation`)
- Modify: `Tests/NousTests/ProvocationOrchestrationTests.swift`

- [ ] **Step 8.1: Write the failing test**

```swift
func testQuickActionOpenerUsesCompanionAndDoesNotRunJudge() async throws {
    XCTAssertNil(viewModel.activeChatMode)

    // Seed the judge with a "loud" verdict to prove it DIDN'T run
    judge.nextVerdict = JudgeVerdict(
        tensionExists: true, userState: .deciding, shouldProvoke: true,
        entryId: nil, reason: "should not run", inferredMode: .strategist
    )

    await viewModel.beginQuickActionConversation(.direction)

    // (a) assembled context used .companion
    let system = llm.receivedSystem ?? ""
    XCTAssertTrue(system.contains("COMPANION MODE"),
                  "quick-action opener must assemble with .companion")
    XCTAssertFalse(system.contains("STRATEGIST MODE"))
    // (b) no judge_events row
    let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
    XCTAssertTrue(events.isEmpty, "quick-action opener must not append judge_events")
    // (c) activeChatMode still nil
    XCTAssertNil(viewModel.activeChatMode)
    // (d) the recording stub's history stays empty (no judge.judge(...) call)
    XCTAssertTrue(judge.previousModeHistory.isEmpty)
}
```

**Note:** `QuickActionMode.direction` assumes the enum has a `direction` case. If the test fails with a case name issue, grep for `QuickActionMode` in Sources to find a valid case and substitute.

- [ ] **Step 8.2: Run it — expect failure**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ProvocationOrchestrationTests/testQuickActionOpenerUsesCompanionAndDoesNotRunJudge 2>&1 | tail -10`
Expected: FAIL — assembled system contains COMPANION MODE only if `activeChatMode ?? .companion = .companion` from `nil`, so (a) may accidentally pass; (b) and (c) depend on the change.

Actually with `activeChatMode = nil` at start, current code after Task 5 already unwraps to `.companion` and doesn't call the judge in `beginQuickActionConversation` (the quick-action method never had a judge call). So the only thing to change is: make it explicit by passing `.companion` literal, so the intent is clear and won't regress if someone later changes the default.

- [ ] **Step 8.3: Update `beginQuickActionConversation`**

In `Sources/Nous/ViewModels/ChatViewModel.swift`, around lines 131 and 155, change:

```swift
// BEFORE
    let context = ChatViewModel.assembleContext(
        chatMode: activeChatMode ?? .companion,
// AFTER
    let context = ChatViewModel.assembleContext(
        chatMode: .companion,
```

And the governanceTrace call:

```swift
// BEFORE
    let promptTrace = ChatViewModel.governanceTrace(
        chatMode: activeChatMode ?? .companion,
// AFTER
    let promptTrace = ChatViewModel.governanceTrace(
        chatMode: .companion,
```

Leave everything else in `beginQuickActionConversation` unchanged. The method must NOT set `activeChatMode` and must NOT append a `judge_events` row.

- [ ] **Step 8.4: Run the test**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ProvocationOrchestrationTests/testQuickActionOpenerUsesCompanionAndDoesNotRunJudge 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 8.5: Run the full suite**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -quiet 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8.6: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift Tests/NousTests/ProvocationOrchestrationTests.swift
git commit -m "feat(chat): quick-action opener hardcodes .companion, skips judge"
```

---

## Task 9: Fixture bank migration + new register-shift fixture

**Why:** The fixture bank now must exercise `previousMode` → `inferredMode` inference. Rename the input field, add `expected.inferred_mode`, and add a two-turn snap-back scenario.

**Files:**
- Modify: `Sources/ProvocationFixtureRunner/main.swift` (schema + diff output)
- Modify: `Tests/NousTests/Fixtures/ProvocationScenarios/01-clear-contradiction-deciding.json`
- Modify: `Tests/NousTests/Fixtures/ProvocationScenarios/02-venting-no-interject.json`
- Modify: `Tests/NousTests/Fixtures/ProvocationScenarios/03-no-tension-benign-question.json`
- Modify: `Tests/NousTests/Fixtures/ProvocationScenarios/04-soft-tension-strategist-provokes.json`
- Modify: `Tests/NousTests/Fixtures/ProvocationScenarios/05-soft-tension-companion-quiet.json`
- Create: `Tests/NousTests/Fixtures/ProvocationScenarios/06-register-shift-snaps-back.json`

- [ ] **Step 9.1: Update the `FixtureCase` schema in the runner**

In `Sources/ProvocationFixtureRunner/main.swift`, replace `FixtureCase` (lines 5-29) with:

```swift
struct FixtureCase: Decodable {
    struct Pool: Decodable { let id: String; let text: String; let scope: String }
    struct Expected: Decodable {
        let shouldProvoke: Bool
        let userState: String?
        let entryId: String?
        let inferredMode: String?
        enum CodingKeys: String, CodingKey {
            case shouldProvoke = "should_provoke"
            case userState = "user_state"
            case entryId = "entry_id"
            case inferredMode = "inferred_mode"
        }
    }
    let name: String
    let userMessage: String
    let previousMode: String?   // nil == first turn
    let citablePool: [Pool]
    let expected: Expected
    enum CodingKeys: String, CodingKey {
        case name
        case userMessage = "user_message"
        case previousMode = "previous_mode"
        case citablePool = "citable_pool"
        case expected
    }
}
```

- [ ] **Step 9.2: Update the runner's mode resolution**

In the same file, replace the `guard let mode = ChatMode(rawValue: fx.chatMode) else {...}` block (lines 58-62) with:

```swift
    let previousMode: ChatMode?
    if let raw = fx.previousMode {
        guard let parsed = ChatMode(rawValue: raw) else {
            failures += 1
            print("💥 \(fx.name) — unknown previous_mode '\(raw)'")
            continue
        }
        previousMode = parsed
    } else {
        previousMode = nil
    }
```

- [ ] **Step 9.3: Update the judge call and diff reporter**

Replace the `judge.judge(...)` call + the diff block (lines 68-92) with:

```swift
    do {
        let verdict = try await judge.judge(
            userMessage: fx.userMessage,
            citablePool: pool,
            previousMode: previousMode,
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
        if let wantMode = fx.expected.inferredMode, verdict.inferredMode.rawValue != wantMode {
            diffs.append("inferred_mode: got=\(verdict.inferredMode.rawValue) want=\(wantMode)")
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
```

- [ ] **Step 9.4: Migrate the 5 existing fixtures**

For each JSON file, rename the `chat_mode` input key to `previous_mode` (preserving its value), and add `inferred_mode` to `expected`. The rule: `expected.inferred_mode` should match the existing `chat_mode` input since these fixtures were written to exercise behavior WITHIN a given mode; the judge should now PICK that same mode via continuity bias.

**`01-clear-contradiction-deciding.json`** — replace the entire file with:
```json
{
  "name": "01-clear-contradiction-deciding",
  "user_message": "I'm just going to go with the cheapest vendor — whatever gets us live this week.",
  "previous_mode": "companion",
  "citable_pool": [
    { "id": "E1", "text": "Alex has explicitly said multiple times he doesn't want to compete on price and wants to avoid anchoring on cheapest-wins.", "scope": "global" },
    { "id": "E2", "text": "Alex mentioned he prefers 松弛 coffee shops.", "scope": "global" }
  ],
  "expected": { "should_provoke": true, "user_state": "deciding", "entry_id": "E1", "inferred_mode": "companion" }
}
```

**`02-venting-no-interject.json`** — open the current file, apply the same transform: rename `chat_mode` → `previous_mode`, append `"inferred_mode": "<same value as previous_mode>"` to `expected`. Keep all other fields byte-identical.

**`03-no-tension-benign-question.json`** — same transform.

**`04-soft-tension-strategist-provokes.json`** — same transform (previous_mode and inferred_mode both "strategist").

**`05-soft-tension-companion-quiet.json`** — same transform (both "companion").

- [ ] **Step 9.5: Create `06-register-shift-snaps-back.json`**

Write a new file at `Tests/NousTests/Fixtures/ProvocationScenarios/06-register-shift-snaps-back.json`:

```json
{
  "name": "06-register-shift-snaps-back",
  "user_message": "ok let me just start the outline",
  "previous_mode": "strategist",
  "citable_pool": [
    { "id": "E1", "text": "Alex is preparing a product strategy presentation for Thursday.", "scope": "global" }
  ],
  "expected": { "should_provoke": false, "user_state": "exploring", "entry_id": null, "inferred_mode": "companion" }
}
```

This encodes the spec's "register snap-back" scenario: previous turn was strategist (analytical decomposition), the user's next message is casual-imperative ("ok let me just start"), and the judge should switch to `companion` because the register clearly shifted.

- [ ] **Step 9.6: Run the fixture bank against the real judge**

If `ANTHROPIC_API_KEY` is set in the shell, run:
```bash
ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" ./scripts/run_provocation_fixtures.sh
```

Expected: The script builds `ProvocationFixtureRunner`, runs all 6 fixtures, prints `✅` for each, and ends with `6/6 passed` (exit 0). A ❌ means the judge prompt isn't calibrated; report the diffs to the user and iterate on the prompt in `ProvocationJudge.buildPrompt` before proceeding. A 💥 means a schema error — re-check the JSON.

If `ANTHROPIC_API_KEY` is not set, skip this step and note to the user that the fixture bank must be run manually before merging.

- [ ] **Step 9.7: Run the full test suite**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -quiet 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`. (The fixture runner is a separate target; this step verifies the unit suite still passes after schema changes that shouldn't have touched it.)

- [ ] **Step 9.8: Commit**

```bash
git add Sources/ProvocationFixtureRunner/main.swift Tests/NousTests/Fixtures/ProvocationScenarios/
git commit -m "feat(provocation): migrate fixtures to previous_mode + inferred_mode schema"
```

---

## Task 10: Final verification + push

**Why:** Re-run the entire suite one last time, verify the app launches clean, and push.

- [ ] **Step 10.1: Full clean test run**

```bash
xcodebuild clean test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -quiet 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **` with all tests listed in the summary (baseline ~10 tests + ~11 new = ~21).

- [ ] **Step 10.2: Full clean app build**

```bash
xcodebuild clean build -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' -quiet 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 10.3: Manual smoke — launch and test three paths**

Open the app in Xcode and run. Test all three entry paths:
1. Welcome → type "I'm stuck on this decision" → send. Verify a reply streams in, no crash, no visible mode picker.
2. Welcome → click a quick-action chip (e.g. "Direction") → verify it opens a conversation with an opener reply.
3. Sidebar → pick an existing conversation → verify messages load. Open `MemoryDebugInspector` → Judge Events tab → verify recent events show `chatMode` values matching what the judge inferred.

Report any issues. If any path crashes or shows wrong state, diagnose and fix before pushing.

- [ ] **Step 10.4: Check commits and push**

```bash
git log --oneline alexko0421/proactive-surfacing..HEAD
```
Expected: 8–9 commits, one per task (plus any inline fixes).

```bash
git push -u origin alexko0421/chatmode-ui-removal
```

- [ ] **Step 10.5: Open PR**

Use the project's `ship` skill or `gh pr create` with base branch `alexko0421/proactive-surfacing` (or `main` if that branch has already merged). Title: `feat: remove ChatMode UI picker; AI judges framing per turn`. Body should link the spec.

---

## Self-Review Notes

**Spec coverage confirmed against `docs/superpowers/specs/2026-04-17-chatmode-ui-removal-design.md`:**

| Spec section | Plan task(s) |
|---|---|
| D1 — JudgeVerdict.inferredMode + CodingKeys | Task 1 |
| D1 — Judging protocol previousMode param | Task 2 |
| D2 — Prompt continuity bias + inferred_mode schema | Task 3 |
| D3 — Reordered send() flow steps 1-8 | Task 6 (steps A-G) |
| D3 — activeChatMode ChatMode? | Task 5 |
| D4 — UI removal | Task 5 (bundled) |
| D5 — latestChatMode(forNode:) + hydration | Task 4 (query), Task 7 (callers) |
| D6 — Fallback table | Covered by Task 6 effectiveMode derivation + tests 6.4/6.5 |
| D7 — QuickAction opener rule | Task 8 |
| Tests — unit list | Covered across Tasks 1, 4, 6, 7, 8 |
| Tests — fixture bank | Task 9 |

**Spec section note**: D6's `loadConversation into node with no judge_events → activeChatMode = nil` is covered by `testLoadConversationKeepsNilWhenNoEvents` in Task 7.
