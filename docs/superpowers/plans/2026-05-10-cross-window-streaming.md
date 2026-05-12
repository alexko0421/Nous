# Cross-Window Streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop cancelling in-flight assistant generation when the user switches conversations; let multiple conversations stream concurrently in the background; surface background completions as a small unread dot in the LeftSidebar.

**Architecture:** Move the in-flight `Task` handle and partial streaming state (`currentResponse`, `currentThinking`, `currentThinkingStartedAt`, `currentAgentTrace`, `isGenerating`, `didHitBudgetExhaustion`, abort reason) from `ChatViewModel` into a per-conversation `ConversationStreamingSession` (observable) owned by `ConversationSessionStore`. `ChatViewModel` keeps the same property names but they become computed forwarders over `currentStreamingSession`. `loadConversation` rebinds the session instead of cancelling it. `LeftSidebar` observes `hasUnseenCompletion` to render the dot.

**Tech Stack:** Swift 5.10, `@Observable` (Swift Observation), SwiftUI, XCTest, xcodebuild (per `project_nous_build_tool` memory — never `swift build`).

**Spec:** `docs/superpowers/specs/2026-05-10-cross-window-streaming-design.md`

---

## File Structure

**Create:**
- `Sources/Nous/Services/ConversationStreamingSession.swift` — new observable class holding per-conversation in-flight Task + partial streaming state + unread flag
- `Tests/NousTests/ConversationStreamingSessionTests.swift` — unit tests for the new class

**Modify:**
- `Sources/Nous/Services/ConversationSessionStore.swift` — add `streamingSessions: [UUID: ConversationStreamingSession]` dict + `streamingSession(for:)` accessor
- `Sources/Nous/ViewModels/ChatViewModel.swift` — biggest change: convert direct-stored streaming properties into computed forwarders over `currentStreamingSession`; remove cancel-on-switch from `loadConversation`; route the 3 turn-spawn sites and 2 supersede sites through the session
- `Sources/Nous/Views/LeftSidebar.swift` — render colaOrange dot when conversation has `hasUnseenCompletion`
- `Tests/NousTests/ChatViewModelTests.swift` — adjust existing tests that depended on cancel-on-switch; add new tests for survival across switch
- `Tests/NousTests/ConversationSessionStoreTests.swift` — add streamingSession identity tests

**Note on scope:** `ChatTurnRunner`, `TurnExecutor`, `AgentLoopExecutor` do not need internal changes. They reach streaming state through `ChatViewModel` properties (via the `TurnEventSink` returned by `makeTurnEventSink`). Because we keep the property names on `ChatViewModel` and just change their storage to forward into the session, those callers stay unchanged. The routing happens entirely inside `ChatViewModel`.

---

## Task 1: Create `ConversationStreamingSession` skeleton (model + first tests)

**Files:**
- Create: `Sources/Nous/Services/ConversationStreamingSession.swift`
- Create: `Tests/NousTests/ConversationStreamingSessionTests.swift`

- [ ] **Step 1: Write the first failing test for initial state**

Create `Tests/NousTests/ConversationStreamingSessionTests.swift`:

```swift
import XCTest
@testable import Nous

@MainActor
final class ConversationStreamingSessionTests: XCTestCase {

    func test_initialState_isEmpty() {
        let id = UUID()
        let session = ConversationStreamingSession(conversationId: id)

        XCTAssertEqual(session.conversationId, id)
        XCTAssertEqual(session.currentResponse, "")
        XCTAssertEqual(session.currentThinking, "")
        XCTAssertNil(session.currentThinkingStartedAt)
        XCTAssertTrue(session.currentAgentTrace.isEmpty)
        XCTAssertFalse(session.isGenerating)
        XCTAssertFalse(session.didHitBudgetExhaustion)
        XCTAssertNil(session.inFlightTask)
        XCTAssertNil(session.inFlightTurnId)
        XCTAssertNil(session.inFlightAbortReason)
        XCTAssertFalse(session.hasUnseenCompletion)
        XCTAssertNil(session.lastError)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Nous -only-testing:NousTests/ConversationStreamingSessionTests/test_initialState_isEmpty -destination "platform=macOS"`

Expected: FAIL with "Cannot find 'ConversationStreamingSession' in scope".

- [ ] **Step 3: Create the minimal implementation**

Create `Sources/Nous/Services/ConversationStreamingSession.swift`:

```swift
import Foundation
import Observation

/// Per-conversation streaming state owner.
///
/// Holds the in-flight assistant turn `Task`, the partial streamed buffers
/// (response / thinking / agent trace), and the `hasUnseenCompletion` flag
/// that drives the LeftSidebar unread dot. One instance per conversation
/// that has ever started a turn in this app session, owned by
/// `ConversationSessionStore.streamingSessions`.
///
/// Threading: `@MainActor`. All mutations and reads happen on the main
/// actor. The held `Task` may run off-actor internally but all writes
/// through the `append*` helpers hop back to main.
@Observable
@MainActor
final class ConversationStreamingSession {

    let conversationId: UUID

    // Partial streaming buffers (mirror ChatViewModel's pre-refactor properties).
    var currentResponse: String = ""
    var currentThinking: String = ""
    var currentThinkingStartedAt: Date?
    var currentAgentTrace: [AgentTraceRecord] = []
    var isGenerating: Bool = false
    var didHitBudgetExhaustion: Bool = false

    // In-flight task ownership.
    @ObservationIgnored nonisolated(unsafe) var inFlightTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var inFlightTurnId: UUID?
    @ObservationIgnored nonisolated(unsafe) var inFlightAbortReason: TurnAbortReason?

    // Background completion tracking.
    var hasUnseenCompletion: Bool = false
    var lastError: Error?

    init(conversationId: UUID) {
        self.conversationId = conversationId
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Nous -only-testing:NousTests/ConversationStreamingSessionTests/test_initialState_isEmpty -destination "platform=macOS"`

Expected: PASS.

- [ ] **Step 5: Add the file to the Xcode project**

Open `Nous.xcodeproj` and add `Sources/Nous/Services/ConversationStreamingSession.swift` to the Nous target. (If using xcodegen / generated project, run the regen command.) Confirm by running `xcodebuild -scheme Nous build` — must compile clean.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Services/ConversationStreamingSession.swift \
        Tests/NousTests/ConversationStreamingSessionTests.swift \
        Nous.xcodeproj/project.pbxproj
git commit -m "feat(streaming): add ConversationStreamingSession skeleton

Per-conversation observable holder for in-flight task + partial stream
buffers. No callers yet — wired up in following commits.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: Add lifecycle helpers to `ConversationStreamingSession`

**Files:**
- Modify: `Sources/Nous/Services/ConversationStreamingSession.swift`
- Modify: `Tests/NousTests/ConversationStreamingSessionTests.swift`

- [ ] **Step 1: Write failing tests for lifecycle helpers**

Append to `ConversationStreamingSessionTests.swift`:

```swift
    func test_beginTurn_setsTaskAndClearsBuffers() {
        let session = ConversationStreamingSession(conversationId: UUID())
        session.currentResponse = "leftover"
        session.currentThinking = "leftover"
        session.currentAgentTrace = [AgentTraceRecord.preview()]
        session.didHitBudgetExhaustion = true

        let turnId = UUID()
        let task = Task<Void, Never> { }
        session.beginTurn(turnId: turnId, task: task)

        XCTAssertEqual(session.inFlightTurnId, turnId)
        XCTAssertNotNil(session.inFlightTask)
        XCTAssertEqual(session.currentResponse, "")
        XCTAssertEqual(session.currentThinking, "")
        XCTAssertTrue(session.currentAgentTrace.isEmpty)
        XCTAssertTrue(session.isGenerating)
        XCTAssertFalse(session.didHitBudgetExhaustion)
        XCTAssertNotNil(session.currentThinkingStartedAt)
    }

    func test_finishTurn_whenViewing_doesNotSetUnseen() {
        let session = ConversationStreamingSession(conversationId: UUID())
        session.beginTurn(turnId: UUID(), task: Task<Void, Never> { })

        session.finishTurn(viewingNow: true)

        XCTAssertFalse(session.isGenerating)
        XCTAssertNil(session.inFlightTask)
        XCTAssertNil(session.inFlightTurnId)
        XCTAssertFalse(session.hasUnseenCompletion)
    }

    func test_finishTurn_whenNotViewing_setsUnseen() {
        let session = ConversationStreamingSession(conversationId: UUID())
        session.beginTurn(turnId: UUID(), task: Task<Void, Never> { })

        session.finishTurn(viewingNow: false)

        XCTAssertTrue(session.hasUnseenCompletion)
    }

    func test_failTurn_recordsErrorAndUnseen() {
        struct E: Error, Equatable {}
        let session = ConversationStreamingSession(conversationId: UUID())
        session.beginTurn(turnId: UUID(), task: Task<Void, Never> { })

        session.failTurn(E(), viewingNow: false)

        XCTAssertTrue(session.hasUnseenCompletion)
        XCTAssertTrue(session.lastError is E)
    }

    func test_markViewed_clearsUnseenAndReturnsError() {
        struct E: Error, Equatable {}
        let session = ConversationStreamingSession(conversationId: UUID())
        session.hasUnseenCompletion = true
        session.lastError = E()

        let surfaced = session.markViewed()

        XCTAssertFalse(session.hasUnseenCompletion)
        XCTAssertNil(session.lastError)
        XCTAssertNotNil(surfaced)
        XCTAssertTrue(surfaced is E)
    }

    func test_cancel_cancelsTask() async {
        let session = ConversationStreamingSession(conversationId: UUID())
        let started = expectation(description: "task started")
        let observedCancelled = expectation(description: "task observed cancel")
        let task = Task<Void, Never> {
            started.fulfill()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            observedCancelled.fulfill()
        }
        session.beginTurn(turnId: UUID(), task: task)
        await fulfillment(of: [started], timeout: 1.0)

        session.cancel()

        await fulfillment(of: [observedCancelled], timeout: 1.0)
        XCTAssertNil(session.inFlightTask)
        XCTAssertNil(session.inFlightTurnId)
    }
```

Note: `AgentTraceRecord.preview()` likely does not exist. If it doesn't, write the test record inline using an existing initializer — grep `AgentTraceRecord(` in `Sources/Nous/Models/` for an example.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Nous -only-testing:NousTests/ConversationStreamingSessionTests -destination "platform=macOS"`

Expected: FAIL on every new test with "value of type 'ConversationStreamingSession' has no member 'beginTurn'".

- [ ] **Step 3: Implement the lifecycle helpers**

Append to `Sources/Nous/Services/ConversationStreamingSession.swift`:

```swift
extension ConversationStreamingSession {

    func beginTurn(turnId: UUID, task: Task<Void, Never>) {
        inFlightTurnId = turnId
        inFlightTask = task
        inFlightAbortReason = nil
        currentResponse = ""
        currentThinking = ""
        currentThinkingStartedAt = Date()
        currentAgentTrace = []
        didHitBudgetExhaustion = false
        isGenerating = true
    }

    func finishTurn(viewingNow: Bool) {
        isGenerating = false
        inFlightTask = nil
        inFlightTurnId = nil
        inFlightAbortReason = nil
        if !viewingNow {
            hasUnseenCompletion = true
        }
    }

    func failTurn(_ error: Error, viewingNow: Bool) {
        lastError = error
        finishTurn(viewingNow: viewingNow)
        if !viewingNow {
            hasUnseenCompletion = true
        }
    }

    func cancel() {
        inFlightTask?.cancel()
        inFlightTask = nil
        inFlightTurnId = nil
    }

    /// Clears `hasUnseenCompletion` and returns the one-shot `lastError`
    /// (if any) so the caller can surface it once and then move on.
    @discardableResult
    func markViewed() -> Error? {
        hasUnseenCompletion = false
        let err = lastError
        lastError = nil
        return err
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Nous -only-testing:NousTests/ConversationStreamingSessionTests -destination "platform=macOS"`

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/ConversationStreamingSession.swift \
        Tests/NousTests/ConversationStreamingSessionTests.swift
git commit -m "feat(streaming): add ConversationStreamingSession lifecycle helpers

beginTurn/finishTurn/failTurn/cancel/markViewed. Background-completion
unread flag exposed via markViewed one-shot.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: Lazy-create per-conversation sessions in `ConversationSessionStore`

**Files:**
- Modify: `Sources/Nous/Services/ConversationSessionStore.swift`
- Modify: `Tests/NousTests/ConversationSessionStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/NousTests/ConversationSessionStoreTests.swift` (or a new dedicated file `ConversationSessionStoreStreamingTests.swift` if the existing file has a different testing style — match the existing pattern):

```swift
    @MainActor
    func test_streamingSession_isIdentityStableForSameId() {
        let store = makeStoreForStreamingTests()
        let id = UUID()
        let a = store.streamingSession(for: id)
        let b = store.streamingSession(for: id)
        XCTAssertTrue(a === b)
    }

    @MainActor
    func test_streamingSession_distinctIdsProduceDistinctInstances() {
        let store = makeStoreForStreamingTests()
        let a = store.streamingSession(for: UUID())
        let b = store.streamingSession(for: UUID())
        XCTAssertFalse(a === b)
    }
```

Add a helper at the bottom of the file (or reuse an existing factory):

```swift
    @MainActor
    private func makeStoreForStreamingTests() -> ConversationSessionStore {
        // Match how other tests in this file construct ConversationSessionStore.
        // If the existing tests use an in-memory NodeStore helper, use it here too.
        return ConversationSessionStore(nodeStore: TestNodeStoreFactory.inMemory())
    }
```

If `TestNodeStoreFactory` doesn't exist, copy the construction pattern from the first existing test in the file.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Nous -only-testing:NousTests/ConversationSessionStoreTests/test_streamingSession_isIdentityStableForSameId -destination "platform=macOS"`

Expected: FAIL with "value of type 'ConversationSessionStore' has no member 'streamingSession'".

- [ ] **Step 3: Add the accessor to `ConversationSessionStore`**

In `Sources/Nous/Services/ConversationSessionStore.swift`, inside the `final class ConversationSessionStore` body, add:

```swift
    @MainActor
    private var streamingSessions: [UUID: ConversationStreamingSession] = [:]

    @MainActor
    func streamingSession(for conversationId: UUID) -> ConversationStreamingSession {
        if let existing = streamingSessions[conversationId] {
            return existing
        }
        let session = ConversationStreamingSession(conversationId: conversationId)
        streamingSessions[conversationId] = session
        return session
    }

    /// Conversation ids that currently have an unseen background completion.
    /// Used by LeftSidebar to render the unread dot.
    @MainActor
    func conversationIdsWithUnseenCompletion() -> Set<UUID> {
        Set(streamingSessions.compactMap { $0.value.hasUnseenCompletion ? $0.key : nil })
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Nous -only-testing:NousTests/ConversationSessionStoreTests -destination "platform=macOS"`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/ConversationSessionStore.swift \
        Tests/NousTests/ConversationSessionStoreTests.swift
git commit -m "feat(streaming): lazy-create per-conversation streaming sessions

ConversationSessionStore.streamingSession(for:) is identity-stable so
multiple call sites that look up the same conversation get the same
observable instance.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: Migrate `ChatViewModel` streaming state to computed forwarders

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`

This is the largest task. The strategy: convert each stored streaming property on `ChatViewModel` into a computed property that reads/writes through `currentStreamingSession`. Property names and call-site reads/writes are unchanged.

- [ ] **Step 1: Add `currentStreamingSession` ref and bind on conversation entry**

In `ChatViewModel.swift`, near the other state properties (around line 10–20), add:

```swift
    @ObservationIgnored private(set) var currentStreamingSession: ConversationStreamingSession?
```

Then in both conversation-entry sites:

In `startNewConversation` (around line 480–498), after `currentNode = node`, add:

```swift
        currentStreamingSession = conversationSessionStore.streamingSession(for: node.id)
```

In `loadConversation` (around line 501), after `currentNode = node`, add:

```swift
        currentStreamingSession = conversationSessionStore.streamingSession(for: node.id)
```

(Cancel-removal happens in Task 7. For now keep the existing cancel call so we can ship Task 4 independently.)

- [ ] **Step 2: Convert `currentResponse` to a computed forwarder**

Find the existing line (around 14): `var currentResponse: String = ""`. Replace with:

```swift
    var currentResponse: String {
        get { currentStreamingSession?.currentResponse ?? "" }
        set { currentStreamingSession?.currentResponse = newValue }
    }
```

- [ ] **Step 3: Convert the other stored streaming properties**

In the same property block, convert:

```swift
    var currentThinking: String {
        get { currentStreamingSession?.currentThinking ?? "" }
        set { currentStreamingSession?.currentThinking = newValue }
    }

    var currentThinkingStartedAt: Date? {
        get { currentStreamingSession?.currentThinkingStartedAt }
        set { currentStreamingSession?.currentThinkingStartedAt = newValue }
    }

    var currentAgentTrace: [AgentTraceRecord] {
        get { currentStreamingSession?.currentAgentTrace ?? [] }
        set { currentStreamingSession?.currentAgentTrace = newValue }
    }

    var isGenerating: Bool {
        get { currentStreamingSession?.isGenerating ?? false }
        set { currentStreamingSession?.isGenerating = newValue }
    }

    var didHitBudgetExhaustion: Bool {
        get { currentStreamingSession?.didHitBudgetExhaustion ?? false }
        set { currentStreamingSession?.didHitBudgetExhaustion = newValue }
    }
```

- [ ] **Step 4: Remove the now-redundant reset assignments**

In `startNewConversation` and `loadConversation`, the explicit resets to these properties (e.g. `currentResponse = ""`, `currentThinking = ""`, `currentAgentTrace = []`, `didHitBudgetExhaustion = false`, `currentThinkingStartedAt = nil`) become writes through the forwarders into the newly-bound session.

For a **fresh** conversation (`startNewConversation`) the session is brand new and already empty — these resets are safe no-ops but keep them for explicitness.

For `loadConversation` the session may already contain partial-stream data from a still-running background turn. **Do not reset those properties in `loadConversation` anymore** — that would wipe legitimately ongoing state. Remove the four lines:

```swift
        currentResponse = ""
        currentThinking = ""
        currentThinkingStartedAt = nil
        currentAgentTrace = []
        didHitBudgetExhaustion = false
```

Keep the conversation-scoped resets that are not streaming-related: `citations = []`, `resolvedCorpusEntries = []`, `activeQuickActionMode = nil`, `pendingSourceMaterialsByTurnId.removeAll()`, `sourceMaterialsByUserMessageId.removeAll()`.

- [ ] **Step 5: Build and run the full test suite**

Run: `xcodebuild test -scheme Nous -destination "platform=macOS"`

Expected: build succeeds; most tests pass. Some `ChatViewModelTests` cases that depended on the old "explicit reset on load" behavior may fail — that is **expected** and will be addressed in Task 7. Note any failures and proceed.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift
git commit -m "refactor(chat): forward streaming state through ConversationStreamingSession

ChatViewModel.currentResponse/currentThinking/currentAgentTrace/
isGenerating/didHitBudgetExhaustion are now computed forwarders over
currentStreamingSession. loadConversation no longer wipes those — the
session keeps them so a background turn can keep streaming.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Move in-flight Task ownership into the session

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`

Today `ChatViewModel` has three stored slots that hold the in-flight task identity (`inFlightResponseTask`, `inFlightResponseTaskId`, `inFlightResponseAbortReason`) and three spawn sites that write to them (`:531`, `:704`, `:867`) plus two supersede sites (`:444`, `:472`).

Strategy: keep these property names on `ChatViewModel` but back them by the session so writes from a spawn site automatically attach the task to the correct conversation's session.

- [ ] **Step 1: Convert the three task-tracking slots to forwarders**

Find the existing (around line 82–84):

```swift
    @ObservationIgnored nonisolated(unsafe) private var inFlightResponseTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var inFlightResponseTaskId: UUID?
    @ObservationIgnored nonisolated(unsafe) private var inFlightResponseAbortReason: TurnAbortReason?
```

Replace with:

```swift
    private var inFlightResponseTask: Task<Void, Never>? {
        get { currentStreamingSession?.inFlightTask }
        set { currentStreamingSession?.inFlightTask = newValue }
    }

    private var inFlightResponseTaskId: UUID? {
        get { currentStreamingSession?.inFlightTurnId }
        set { currentStreamingSession?.inFlightTurnId = newValue }
    }

    private var inFlightResponseAbortReason: TurnAbortReason? {
        get { currentStreamingSession?.inFlightAbortReason }
        set { currentStreamingSession?.inFlightAbortReason = newValue }
    }
```

- [ ] **Step 2: Audit the 5 mutation sites + the cancel path**

Grep for `inFlightResponseTask` and `inFlightResponseTaskId` in `ChatViewModel.swift`. Confirm every read/write site still works after the conversion to computed properties — no `&inFlightResponseTask` taken, no use as a closure capture (these are stored properties → forwarders, captures of a stored Task ref via `let captured = inFlightResponseTask` still work because the getter returns the current value).

Expected sites (line numbers from current file):
- Read at `:1118`, `:1327`, `:1332` — getters work
- Write at `:444`, `:472`, `:531`, `:704`, `:867`, `:1312`, `:1313`, `:1314`, `:1333`, `:1334` — setters work

If any site does `inout` or address-taking, refactor it to read-then-write.

- [ ] **Step 3: Build and run tests**

Run: `xcodebuild test -scheme Nous -destination "platform=macOS"`

Expected: build succeeds; cancel-on-switch tests still pass (we have not removed the cancel yet); other tests unchanged.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift
git commit -m "refactor(chat): in-flight task slots forward into streaming session

inFlightResponseTask/Id/AbortReason now read/write through
currentStreamingSession. Each turn spawn site automatically attaches
its task to the conversation it originated from, so the task survives
ChatViewModel rebinding to a different conversation.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: Remove cancel-on-switch from `loadConversation`

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Modify: `Tests/NousTests/ChatViewModelTests.swift`

- [ ] **Step 1: Write the failing test that proves the fix**

Append to `Tests/NousTests/ChatViewModelTests.swift`:

```swift
    @MainActor
    func test_loadConversation_doesNotCancelInFlightTaskOnOtherConversation() async {
        let vm = makeChatViewModel()  // use existing test helper in this file
        let nodeA = vm.startNewConversationForTests(title: "A")
        let nodeB = vm.startNewConversationForTests(title: "B")

        // Land on A, install a long-running pseudo task on A's session.
        vm.loadConversation(nodeA)
        let sessionA = vm.currentStreamingSession!
        let started = expectation(description: "A task started")
        let task = Task<Void, Never> {
            started.fulfill()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        sessionA.beginTurn(turnId: UUID(), task: task)
        await fulfillment(of: [started], timeout: 1.0)

        // Switch to B.
        vm.loadConversation(nodeB)

        // A's task must still be alive.
        XCTAssertFalse(task.isCancelled)
        XCTAssertNotNil(sessionA.inFlightTask)

        // Cleanup.
        task.cancel()
    }
```

If `startNewConversationForTests` / `makeChatViewModel` helpers don't exist, follow the pattern of an existing test in the same file. Goal is to exercise the public API.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Nous -only-testing:NousTests/ChatViewModelTests/test_loadConversation_doesNotCancelInFlightTaskOnOtherConversation -destination "platform=macOS"`

Expected: FAIL — A's task gets cancelled by `loadConversation`.

- [ ] **Step 3: Remove the cancel in `loadConversation`**

In `Sources/Nous/ViewModels/ChatViewModel.swift`, find `loadConversation` (around line 501):

```swift
    @MainActor
    func loadConversation(_ node: NousNode, cancelInFlightWork: Bool = true) {
        if cancelInFlightWork {
            cancelInFlightResponse(clearDraft: true, reason: .conversationSwitched)
            cancelInFlightJudge()
        }
        ...
    }
```

Change the default and remove the streaming cancel. The judge cancel stays — judges are conversation-scoped and shouldn't continue against a different active conversation:

```swift
    @MainActor
    func loadConversation(_ node: NousNode, cancelInFlightWork: Bool = false) {
        if cancelInFlightWork {
            cancelInFlightResponse(clearDraft: true, reason: .conversationSwitched)
        }
        cancelInFlightJudge()
        ...
    }
```

The `cancelInFlightWork` parameter stays opt-in for callers that genuinely want to abort (e.g., delete-conversation path). Default flips to `false`.

- [ ] **Step 4: Call `markViewed()` after rebinding the session**

In `loadConversation`, after `currentStreamingSession = conversationSessionStore.streamingSession(for: node.id)`, add:

```swift
        let surfacedError = currentStreamingSession?.markViewed()
        if let surfacedError {
            // Route through the existing error display path. If there isn't a
            // generic one, log via the same channel cancelInFlightResponse uses.
            NSLog("[NousTurn] background turn error surfaced on conversation enter: %@",
                  String(describing: surfacedError))
        }
```

If `ChatViewModel` has a typed error-display property (search for "error" near the top of the file), assign there instead of NSLog. Goal: do not silently swallow background errors.

- [ ] **Step 5: Audit callers of `loadConversation` that pass `cancelInFlightWork: true` or omit it**

Grep: `Grep "loadConversation(" --type swift`. Each call site needs review:

- Calls from view code on conversation switch in the UI — flip to default `false` (or pass `false` explicitly to be loud).
- Calls from conversation-delete or other destructive flows — keep `true` if they want cancellation.

For each found call, evaluate intent and update if needed. Document the call sites you touched in the commit message.

- [ ] **Step 6: Run tests to verify the new test passes**

Run: `xcodebuild test -scheme Nous -only-testing:NousTests/ChatViewModelTests/test_loadConversation_doesNotCancelInFlightTaskOnOtherConversation -destination "platform=macOS"`

Expected: PASS.

Then run the **full** test suite:

Run: `xcodebuild test -scheme Nous -destination "platform=macOS"`

Expected: any tests that previously asserted "loadConversation cancels the in-flight task" will now fail. Update them in this same task to assert the new behavior (no cancel) — they were enforcing the bug.

- [ ] **Step 7: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift \
        Tests/NousTests/ChatViewModelTests.swift
git commit -m "fix(chat): keep in-flight turn alive when switching conversations

loadConversation no longer cancels the streaming task by default. The
opt-in parameter remains for destructive flows. markViewed clears the
unread dot and surfaces any background error.

Fixes the user-reported regression where leaving A while it's thinking
and coming back to A would lose the reply.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 7: Mark `hasUnseenCompletion` when a turn finishes off-screen

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Modify: `Tests/NousTests/ChatViewModelTests.swift`

The turn-completion path in `ChatViewModel` runs after the streaming Task finishes (success or error). Today it sits in `clearInFlightResponseTaskIfOwned(_:)` (around lines 1327–1334) and adjacent finalization. We need to set `hasUnseenCompletion` if at completion time the user is no longer viewing the originating conversation.

- [ ] **Step 1: Write the failing test**

Append to `ChatViewModelTests.swift`:

```swift
    @MainActor
    func test_backgroundTurnCompletion_setsHasUnseenCompletion() async {
        let vm = makeChatViewModel()
        let nodeA = vm.startNewConversationForTests(title: "A")
        let nodeB = vm.startNewConversationForTests(title: "B")

        vm.loadConversation(nodeA)
        let sessionA = vm.currentStreamingSession!

        let turnId = UUID()
        let task = Task<Void, Never> { /* finishes instantly */ }
        sessionA.beginTurn(turnId: turnId, task: task)

        // Switch to B BEFORE the simulated finish.
        vm.loadConversation(nodeB)

        // Simulate the turn finishing — drive the same completion path the
        // production code uses. Use the public ChatViewModel API if exposed,
        // otherwise call the internal hook via @testable.
        vm.finalizeTurn(turnId: turnId, conversationId: nodeA.id, error: nil)

        XCTAssertTrue(sessionA.hasUnseenCompletion)
    }
```

If `finalizeTurn(turnId:conversationId:error:)` does not exist as an entry point, search for where `clearInFlightResponseTaskIfOwned` is called and either extract a small helper to call directly, or call the existing completion path through whatever public API drives a turn end. Match the pattern of existing tests in the file.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Nous -only-testing:NousTests/ChatViewModelTests/test_backgroundTurnCompletion_setsHasUnseenCompletion -destination "platform=macOS"`

Expected: FAIL — `hasUnseenCompletion` stays false because completion still routes through `ChatViewModel` which doesn't know about background-vs-foreground.

- [ ] **Step 3: Route completion through the originating session**

In `ChatViewModel.swift`, the completion path needs the originating conversation id captured at spawn time. The three spawn sites already capture `responseTaskId: UUID()` locally; do the same with the conversation:

At each of the three spawn sites (`:531`, `:704`, `:867`), immediately before the `Task { ... }` block, capture:

```swift
        guard let originatingConversationId = currentNode?.id else { return }
        let originatingSession = conversationSessionStore.streamingSession(for: originatingConversationId)
```

Then call `originatingSession.beginTurn(turnId: responseTaskId, task: responseTask)` in place of the manual `inFlightResponseTask = responseTask; inFlightResponseTaskId = responseTaskId`.

After the `await responseTask.value` line, replace the existing clear-if-owned block with:

```swift
        let viewingNow = (currentNode?.id == originatingConversationId)
        if let surfacedError = originatingSession.captureFinish(turnId: responseTaskId, viewingNow: viewingNow) {
            // surface error via existing path
            NSLog("[NousTurn] turn failed: %@", String(describing: surfacedError))
        }
```

Add to `ConversationStreamingSession.swift` a tiny owned-clear helper:

```swift
    /// Marks this turn finished only if `turnId` still matches `inFlightTurnId`
    /// (i.e. it has not been superseded). Returns the `lastError`, if any.
    @discardableResult
    func captureFinish(turnId: UUID, viewingNow: Bool, error: Error? = nil) -> Error? {
        guard inFlightTurnId == turnId else { return nil }
        if let error {
            failTurn(error, viewingNow: viewingNow)
        } else {
            finishTurn(viewingNow: viewingNow)
        }
        return viewingNow ? nil : lastError
    }
```

(For Task 7 we only thread the no-error path; error path comes when wiring AgentLoop/TurnExecutor error propagation — same code path, just pass `error:` non-nil at the await-throws site.)

- [ ] **Step 4: Run tests**

Run: `xcodebuild test -scheme Nous -destination "platform=macOS"`

Expected: new test passes; existing tests pass. If any test was implicitly asserting the old completion path, update it to assert the new path.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift \
        Sources/Nous/Services/ConversationStreamingSession.swift \
        Tests/NousTests/ChatViewModelTests.swift \
        Tests/NousTests/ConversationStreamingSessionTests.swift
git commit -m "feat(streaming): mark hasUnseenCompletion on off-screen turn finish

Each turn spawn site captures the originating session; on completion,
checks whether the user is still viewing that conversation. If not, the
session flips hasUnseenCompletion, which the sidebar dot observes.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 8: LeftSidebar unread dot

**Files:**
- Modify: `Sources/Nous/Views/LeftSidebar.swift`
- Test: manual visual verification + a unit test on the data path

- [ ] **Step 1: Locate the conversation-row rendering in LeftSidebar**

Grep `LeftSidebar.swift` for the loop / view that renders one row per conversation. Each row needs to know whether its conversation has `hasUnseenCompletion`. The row likely already has the `NousNode` (or at least its id) in scope.

- [ ] **Step 2: Inject `ConversationSessionStore` into the row context**

If `LeftSidebar` already receives the store (directly or via a view model), use it. If not, plumb it through the existing dependency injection point — probably the parent view that constructs `LeftSidebar`.

- [ ] **Step 3: Render the dot**

In the conversation-row body, after the title text, add:

```swift
            if conversationSessionStore.streamingSession(for: node.id).hasUnseenCompletion {
                Circle()
                    .fill(AppColor.colaOrange)
                    .frame(width: 5, height: 5)
                    .padding(.leading, 4)
                    .accessibilityLabel("New reply")
            }
```

The dot must be observable: because `ConversationStreamingSession` is `@Observable`, reading `hasUnseenCompletion` inside a SwiftUI view body subscribes to that property — no extra wiring needed.

- [ ] **Step 4: Verify clear-on-enter**

The view's tap handler already calls `vm.loadConversation(node)`, which (post-Task 6) calls `markViewed()` and flips `hasUnseenCompletion` to false. The dot disappears via the observation system. Confirm by manual run after Task 9 (build) — at this step, just trust the wiring.

- [ ] **Step 5: Build and quick smoke**

Run: `xcodebuild build -scheme Nous -destination "platform=macOS"`

Expected: clean build. No new tests required for this UI change — covered by the manual checklist in Task 10.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Views/LeftSidebar.swift
git commit -m "feat(sidebar): unread dot for background-completed turns

5pt colaOrange circle trailing the conversation title when the
conversation's ConversationStreamingSession.hasUnseenCompletion is true.
Clears automatically on row tap (loadConversation -> markViewed).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 9: Integration test for full round-trip

**Files:**
- Create: `Tests/NousTests/CrossWindowStreamingIntegrationTests.swift`

- [ ] **Step 1: Write the integration test**

```swift
import XCTest
@testable import Nous

@MainActor
final class CrossWindowStreamingIntegrationTests: XCTestCase {

    func test_sendInA_switchToB_switchBackToA_streamStillAccumulates() async throws {
        // Build a ChatViewModel wired with a deterministic mock LLM that
        // streams a known sequence of tokens at a slow cadence so we can
        // assert mid-stream.
        let env = try TestChatEnvironment.makeForStreaming()
        let nodeA = env.viewModel.startNewConversationForTests(title: "A")
        let nodeB = env.viewModel.startNewConversationForTests(title: "B")

        env.viewModel.loadConversation(nodeA)
        env.viewModel.inputText = "hello"
        env.viewModel.sendMessageForTests()

        // Wait for stream to start emitting in A's session.
        let sessionA = env.viewModel.currentStreamingSession!
        try await waitFor(timeout: 2.0) { !sessionA.currentResponse.isEmpty }
        let snapshotA1 = sessionA.currentResponse

        // Switch to B mid-stream.
        env.viewModel.loadConversation(nodeB)
        let sessionB = env.viewModel.currentStreamingSession!
        XCTAssertEqual(sessionB.currentResponse, "")  // B is fresh

        // Let the mock emit a few more tokens.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThan(sessionA.currentResponse.count, snapshotA1.count,
                             "A's session must keep accumulating after switch")

        // Switch back to A.
        env.viewModel.loadConversation(nodeA)
        XCTAssertEqual(env.viewModel.currentResponse, sessionA.currentResponse)

        // Drive the mock to completion and confirm hasUnseenCompletion is false
        // (we are viewing A at completion).
        env.mockLLM.completeStream()
        try await waitFor(timeout: 2.0) { !sessionA.isGenerating }
        XCTAssertFalse(sessionA.hasUnseenCompletion)
    }

    func test_backgroundCompletion_setsDotForSidebar() async throws {
        let env = try TestChatEnvironment.makeForStreaming()
        let nodeA = env.viewModel.startNewConversationForTests(title: "A")
        let nodeB = env.viewModel.startNewConversationForTests(title: "B")

        env.viewModel.loadConversation(nodeA)
        env.viewModel.inputText = "hi"
        env.viewModel.sendMessageForTests()

        let sessionA = env.viewModel.currentStreamingSession!
        try await waitFor(timeout: 2.0) { !sessionA.currentResponse.isEmpty }

        env.viewModel.loadConversation(nodeB)
        env.mockLLM.completeStream()
        try await waitFor(timeout: 2.0) { !sessionA.isGenerating }

        XCTAssertTrue(sessionA.hasUnseenCompletion)
        XCTAssertTrue(env.store.conversationIdsWithUnseenCompletion().contains(nodeA.id))

        // Returning to A clears it.
        env.viewModel.loadConversation(nodeA)
        XCTAssertFalse(sessionA.hasUnseenCompletion)
    }
}
```

`TestChatEnvironment.makeForStreaming()` and `waitFor` must exist or be created. Search for an existing `TestChatEnvironment` or `ChatViewModelTests` helper that builds a `ChatViewModel` with a controllable mock LLM. If only a pure-completion mock exists (no streaming), extend it with a `completeStream()` hook and a per-token-delay. Match the existing test infrastructure style.

- [ ] **Step 2: Run the integration tests**

Run: `xcodebuild test -scheme Nous -only-testing:NousTests/CrossWindowStreamingIntegrationTests -destination "platform=macOS"`

Expected: both PASS.

- [ ] **Step 3: Run the full suite**

Run: `xcodebuild test -scheme Nous -destination "platform=macOS"`

Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add Tests/NousTests/CrossWindowStreamingIntegrationTests.swift
git commit -m "test(streaming): integration coverage for cross-window survival

End-to-end test that sending in A, switching to B mid-stream, and
returning to A preserves the accumulated stream. Plus the unread-dot
data path test.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 10: Manual dogfood verification

**Files:** none — this is a live-run checklist. Per project memory `feedback_concrete_examples_before_approval` and `validation_phase21_shipped`, Nous changes need fresh-conversation live tests before being called done.

- [ ] **Step 1: Build and run the app**

Run: `xcodebuild -scheme Nous -destination "platform=macOS" build` then launch the built app from Xcode or the Conductor app pane.

- [ ] **Step 2: Round-trip in one conversation**

  - Open conversation A (or start one). Send a prompt that produces a long reply (`/brainstorm` followed by a meaty question, or a normal chat ask).
  - As soon as the thinking indicator appears, click a different conversation (B) in the sidebar.
  - Wait a few seconds, then click A again.
  - Expected: the reply continues streaming where it was (or has finished and now renders as a normal message).

- [ ] **Step 3: Concurrent streams**

  - Send a long prompt in A. Switch to B. Send a long prompt in B. Switch back to A.
  - Expected: both streams continue; both finish on their own; no crashes; no message bleeding between conversations.

- [ ] **Step 4: Unread dot**

  - Send a prompt in A, switch to B, wait for A to finish in the background.
  - Expected: small colaOrange dot appears next to A's title in the sidebar. Tap A → dot disappears, message is there.

- [ ] **Step 5: Cancel still works**

  - Send a prompt in A. While streaming, click the Stop button.
  - Expected: A's stream stops, only A's stream — B's state untouched.

- [ ] **Step 6: Background error visibility**

  - If easy to reproduce, force an LLM error (e.g., disconnect network mid-stream, or use a debug toggle if one exists). Otherwise skip.
  - Expected: returning to the conversation surfaces an error indication, does not silently swallow.

- [ ] **Step 7: If anything fails**

Document the failure, decide whether to fix in this branch or file follow-up. Per project memory `feedback_governance_overstack_anti_pattern`, do not stack a new patch over a broken base — fix the base first.

---

## Self-Review

After completing all tasks:

1. **Spec coverage:** every section of `docs/superpowers/specs/2026-05-10-cross-window-streaming-design.md`:
   - Problem / Goal ✅ (Tasks 6 + 7 deliver the user-visible fix)
   - Architecture (per-conversation session) ✅ (Tasks 1 + 3)
   - Components (`ConversationStreamingSession`, store accessor, ChatViewModel forwarder, LeftSidebar) ✅ (Tasks 1, 2, 3, 4, 5, 8)
   - Data flow (happy path / switch-back-during-stream / concurrent / error) ✅ (Task 9 integration tests + Task 10 manual)
   - Edge cases (cancel button per-conversation / single-flight per session / suspend out-of-scope / delete-conversation cleanup) — cancel button handled in Task 5/7; same-conversation single-flight already enforced by the existing input gate (`isGenerating` forwarder); delete-conversation cleanup is **not** in this plan because the existing conversation-delete path isn't on the critical path of this bug — add follow-up if needed.
   - Testing (unit + integration + manual) ✅ (Tasks 1, 2, 3, 6, 7, 9, 10)
   - Risks (forwarder cancellable management → N/A under `@Observable`; NodeStore commit timing → existing executor behavior, unchanged; memory footprint → noted, no eviction; Galaxy reads → forwarders preserve API) — addressed.

2. **Placeholder scan:** no TBDs, no "implement later", no "similar to". Every step has the code or the exact command.

3. **Type consistency:** property names match across tasks — `currentResponse`, `currentThinking`, `currentAgentTrace`, `isGenerating`, `didHitBudgetExhaustion`, `inFlightTask`, `inFlightTurnId`, `inFlightAbortReason`, `hasUnseenCompletion`, `lastError`, `markViewed`, `captureFinish`, `beginTurn`, `finishTurn`, `failTurn`, `cancel`, `streamingSession(for:)`, `conversationIdsWithUnseenCompletion()`.

4. **Scope:** focused on the cross-window streaming bug. No drive-by refactors. The follow-up items in the spec (`Future`) are explicitly out of scope.
