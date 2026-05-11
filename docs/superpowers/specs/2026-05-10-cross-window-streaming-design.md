# Cross-Window Streaming — Design Spec

**Date**: 2026-05-10
**Status**: design approved, pre-implementation
**Phase**: 1 (in-memory per-conversation sessions; no cross-process persistence)

---

## Problem

When the user sends a message in conversation A and the assistant begins thinking / streaming, navigating away to another conversation B (and especially navigating back to A) cancels A's in-flight generation. The thinking and partial response are lost; the user must re-send.

Root cause (verified):

- `ChatViewModel` is a single, shared view model — not per-conversation.
- The in-flight streaming `Task` is owned by `ChatViewModel.inFlightResponseTask` (`Sources/Nous/ViewModels/ChatViewModel.swift:53`).
- `loadConversation(...)` (`Sources/Nous/ViewModels/ChatViewModel.swift:347`) defaults to `cancelInFlightWork: true` and calls `cancelInFlightResponse(...)` on every conversation switch.
- `cancelInFlightResponse` (`Sources/Nous/ViewModels/ChatViewModel.swift:824`) calls `inFlightResponseTask?.cancel()`, which propagates `Task.checkCancellation()` in the streaming loop (`Sources/Nous/Services/TurnExecutor.swift:88-94`).
- Partial streaming state (`currentResponse`, `currentThinking`, `currentAgentTrace`) lives on `ChatViewModel` as `@Published` — not stored per-conversation, so even without cancellation the view-model rebind would lose it.

## Goal

A turn-in-flight for conversation X must survive the user navigating to any other conversation and back. Streaming continues in the background. Multiple conversations may stream concurrently. When a background-completed turn finishes while the user is not viewing that conversation, the conversation's LeftSidebar entry shows an unread dot, cleared when the user re-enters.

Out of scope: surviving app suspend / process death; Galaxy node "thinking" or "unread" indicators; multi-device sync.

## Architecture

Move the in-flight Task and partial streaming state from `ChatViewModel` to a per-conversation `ConversationStreamingSession`, owned by `ConversationSessionStore`. `ChatViewModel` becomes a thin view-bound forwarder over the *current* conversation's session.

```
BEFORE
  ChatViewModel (singleton, shared)
    ├─ inFlightResponseTask: Task?           // killed on conversation switch
    ├─ currentResponse / currentThinking     // wiped on conversation switch
    └─ currentAgentTrace
        ↑
        │ streaming callbacks
        │
  TurnExecutor / AgentLoopExecutor

AFTER
  ConversationSessionStore
    └─ streamingSessions: [UUID: ConversationStreamingSession]
         each session:
           ├─ conversationId
           ├─ inFlightTask: Task?
           ├─ inFlightTurnId: UUID?
           ├─ currentResponse / currentThinking
           ├─ currentAgentTrace
           ├─ hasUnseenCompletion: Bool
           └─ lastError: Error?

  ChatViewModel (singleton, shared)
    └─ currentSession: ConversationStreamingSession?
         (forwards @Published reads from currentSession; writes go to session)
        ↑
        │ streaming callbacks (now keyed by conversationId)
        │
  TurnExecutor / AgentLoopExecutor
```

Why a separate type (vs. extending the existing `ConversationSessionStore` "session" concept):

- The existing per-conversation state in `ConversationSessionStore` covers persisted history / nodes. The new state is purely in-memory volatile (partial token stream + Task handle). Mixing the two risks accidentally persisting partial token state.
- `ConversationStreamingSession` is `@Observable` (or `ObservableObject`); the existing store can compose it without inheritance.

## Components

### `ConversationStreamingSession` (new)

`Sources/Nous/Services/ConversationStreamingSession.swift` (new file)

Observable class. One instance per conversation that has ever started a turn in this app session. Holds:

- `conversationId: UUID` (immutable)
- `inFlightTask: Task<Void, Never>?` — non-nil while a turn is running for this conversation
- `inFlightTurnId: UUID?`
- `currentResponse: String` — partial streamed assistant text
- `currentThinking: String` — partial streamed thinking
- `currentAgentTrace: [AgentTraceRecord]`
- `hasUnseenCompletion: Bool` — true if last turn finished (success or error) while user was not viewing this conversation; cleared on view-enter
- `lastError: Error?` — surfaced on next view-enter if the background turn failed

Methods:

- `beginTurn(turnId:task:)` — set `inFlightTurnId`, `inFlightTask`; clear partial state
- `appendResponse(_:)` / `appendThinking(_:)` / `appendTrace(_:)` — streaming writes
- `finishTurn(viewingNow:)` — clear task; if `viewingNow == false`, set `hasUnseenCompletion = true`
- `failTurn(_:viewingNow:)` — same as finishTurn, plus `lastError`
- `cancel()` — cancels the in-flight Task and clears it
- `markViewed()` — clears `hasUnseenCompletion` and surfaces `lastError` to the caller (one-shot)

### `ConversationSessionStore` (modified)

`Sources/Nous/Services/ConversationSessionStore.swift`

Add:

- `private var streamingSessions: [UUID: ConversationStreamingSession] = [:]`
- `func streamingSession(for conversationId: UUID) -> ConversationStreamingSession` — lazy create + cache
- `func activeStreamingConversationIds() -> Set<UUID>` — for sidebar dot rendering (returns ids where `hasUnseenCompletion == true` OR `inFlightTask != nil` if we ever want a "thinking" indicator — Phase 1 only uses `hasUnseenCompletion`)

### `ChatViewModel` (modified)

`Sources/Nous/ViewModels/ChatViewModel.swift`

- Remove ownership of `inFlightResponseTask` / `currentResponse` / `currentThinking` / `currentAgentTrace` as primary storage. Replace with:
  - `private(set) var currentSession: ConversationStreamingSession?` — bound on `loadConversation`
  - Expose `currentResponse` / `currentThinking` / `currentAgentTrace` as computed `@Published` forwarders over `currentSession`. Use Combine `assign(to:)` from session publishers so existing SwiftUI bindings keep working without view-side rewrites.
- `loadConversation(...)`:
  - **Delete** the `cancelInFlightResponse(...)` call. Conversation switch never cancels.
  - Rebind `currentSession = store.streamingSession(for: conversationId)`
  - Call `currentSession.markViewed()` — clears the unread dot; surfaces any `lastError` for display
- `runSend(...)` / wherever the turn Task is spawned today:
  - Get session for current conversation
  - Wrap the spawned `Task` and pass to `session.beginTurn(turnId:task:)`
  - All streaming callbacks (response delta, thinking delta, trace append) write to the captured session **by conversationId**, not to ChatViewModel — so a still-running task whose conversation is no longer the foreground continues to update its own session
- `cancelInFlightResponse(...)`:
  - Now operates only on the current conversation's session (which is what the user sees the Stop button for)
- Stop button / explicit cancel path: unchanged surface, routes through `currentSession?.cancel()`

### `ChatTurnRunner` / `TurnExecutor` / `AgentLoopExecutor` (modified)

`Sources/Nous/Services/ChatTurnRunner.swift`, `Sources/Nous/Services/TurnExecutor.swift`, `Sources/Nous/Services/AgentLoopExecutor.swift`

Today these call back to `ChatViewModel` (directly or via closures) with streaming deltas. Change: the callback target is the `ConversationStreamingSession` for the conversation that initiated the turn, captured at spawn time. Concretely, the `runSend` site captures `let session = store.streamingSession(for: conversationId)` before spawning, and the streaming closures close over `session` instead of `self` (where self == ChatViewModel).

No other behavior changes in the executors. Cancellation semantics stay: the task that ran on this session is cancelled when `session.cancel()` is called.

### `LeftSidebar` (modified)

`Sources/Nous/Views/LeftSidebar.swift`

For each conversation entry row, observe `store.streamingSession(for: id).hasUnseenCompletion`. When true, render a small filled circle (4–5pt, `AppColor.colaOrange`) trailing the conversation title — matches the established Nous pixel-art motif (see `feedback_nous_visual_language` memory; do not use 🔵/🟠 emoji or system badges).

Tap row → existing `loadConversation` flow → `markViewed()` runs → dot disappears.

## Data Flow

### Happy path: send in A, switch to B, switch back to A

1. User in A. `runSend` invoked. ChatViewModel captures `sessionA = store.streamingSession(for: A.id)`.
2. `sessionA.beginTurn(turnId, task: spawnedTask)`. spawnedTask runs `ChatTurnRunner.run(...)` whose streaming closures write to `sessionA`.
3. ChatViewModel's forwarded `currentResponse` reflects `sessionA.currentResponse` → ChatArea shows live stream.
4. User taps B in LeftSidebar. `loadConversation(B.id)`:
   - **No cancel.** `sessionA.inFlightTask` keeps running, keeps writing to `sessionA.currentResponse`.
   - ChatViewModel rebinds `currentSession = store.streamingSession(for: B.id)` = `sessionB` (likely fresh, empty).
   - ChatArea now reflects `sessionB.currentResponse` (empty).
5. Background: `sessionA`'s task finishes. `session.finishTurn(viewingNow: false)` because current conversation is B. `sessionA.hasUnseenCompletion = true`. Final message has already been committed to NodeStore by the executor (existing behavior).
6. LeftSidebar row for A now shows a dot (observes `sessionA.hasUnseenCompletion`).
7. User taps A. `loadConversation(A.id)`:
   - `currentSession = sessionA`. ChatArea now reflects `sessionA.currentResponse`.
   - But `currentResponse` is just the partial stream buffer — the *committed* message is in NodeStore and already rendered as a normal message. The partial buffer should be cleared on `finishTurn` to avoid double-render.
   - `markViewed()`: clears `hasUnseenCompletion`.

### Switch-back-while-still-streaming

1–4 as above, but step 5 has not yet occurred when user taps A.
5. `loadConversation(A.id)` rebinds `currentSession = sessionA`.
6. `sessionA.inFlightTask` is still running. `sessionA.currentResponse` has accumulated tokens during the absence. ChatArea immediately shows the full partial buffer — the stream visibly continues from where it is now.
7. When the task finishes, `finishTurn(viewingNow: true)` — no dot.

### Concurrent: send in A, switch to B, send in B

1. A is mid-stream as above.
2. User in B, types and sends. ChatViewModel captures `sessionB = store.streamingSession(for: B.id)`, calls `sessionB.beginTurn(...)`. Independent Task starts.
3. Both `sessionA.inFlightTask` and `sessionB.inFlightTask` run concurrently. Each writes to its own session.
4. Whichever finishes second, if user is not viewing it at completion time → dot.

### Error in background

If a background task throws, `session.failTurn(error, viewingNow: false)`. `lastError` stored, `hasUnseenCompletion = true`. On next `loadConversation` of that session, `markViewed()` returns the error and ChatViewModel surfaces it via existing error display path (toast / inline). No silent swallow.

## Edge Cases

- **Cancel button** while viewing A streaming: routes to `currentSession.cancel()`. Only A's task dies.
- **Same-conversation second turn while first is streaming**: existing input gate (`isAssistantResponding` or equivalent) stays. Per-conversation single-flight. Cross-conversation parallelism is what's newly allowed.
- **App suspend**: out of scope. Task dies with the process. On relaunch, `streamingSessions` is empty; any partial buffer that did not commit to NodeStore is lost; committed messages are loaded normally from NodeStore.
- **Conversation deleted while streaming**: `cancel()` the session, drop from dict. Cleanup hook in whatever path deletes conversations today.
- **Memory growth**: `streamingSessions` accumulates one entry per ever-touched conversation. Acceptable — entry is small (a few strings + nil Task). Optionally evict entries with no in-flight task and `hasUnseenCompletion == false` on conversation close, but Phase 1 keeps them.
- **Race: turn finishes exactly when user is switching**: `finishTurn(viewingNow:)` reads `viewingNow` from a value passed in by the caller, which determines it from `chatVM.currentSession?.conversationId == self.conversationId` at the moment of finish. If that read races with `loadConversation`, worst case the user sees a brief dot they didn't need. Acceptable.

## Testing

Unit tests (`Tests/NousTests/`):

- `ConversationStreamingSessionTests`
  - `beginTurn` sets task and turnId; clears prior partial state
  - `appendResponse` / `appendThinking` mutate published state observably
  - `finishTurn(viewingNow: false)` sets `hasUnseenCompletion`; `true` does not
  - `failTurn(_:viewingNow: false)` sets both `hasUnseenCompletion` and `lastError`
  - `markViewed` clears `hasUnseenCompletion` and returns one-shot `lastError`
  - `cancel` cancels the inner Task and clears it
- `ConversationSessionStoreTests`
  - `streamingSession(for:)` is identity-stable across calls (same instance)
  - distinct conversationIds produce distinct sessions
- `ChatViewModelTests`
  - `loadConversation` no longer cancels prior session's task (mock task with `Task.isCancelled` assertion)
  - Forwarded `currentResponse` reflects new session after rebind
  - Stop button only cancels `currentSession`, not any other session

Integration tests (`Tests/NousIntegrationTests/`):

- "Survive round-trip": send turn in A (mock LLM with controllable streaming), assert A's task running. Switch to B. Switch back to A. Assert A's task still running; assert A's `currentResponse` has accumulated.
- "Background completion dot": send turn in A with mock LLM. Switch to B. Drive mock to finish. Assert A's `hasUnseenCompletion == true`. Drive `loadConversation(A)`. Assert cleared.
- "Concurrent streams independence": start A and B, both with controllable mocks. Cancel A. Assert B unaffected and still streaming.

Manual / dogfood checklist:

- Send long-thinking prompt in A; navigate to B; wait; navigate back to A — see continuation.
- Two conversations streaming at once — both finish independently.
- Background-finished conversation shows colaOrange dot in LeftSidebar; tapping clears.
- Error mid-stream while away — error visible on return.

## Risks

- **Forwarder pattern complexity**: ChatViewModel forwarding `@Published` properties from a swappable inner session is the touchiest part. Combine-based `assign(to:)` requires careful cancellable management to avoid leaks across rebinds. Mitigation: small private helper that re-subscribes on every `currentSession` rebind, dropping prior cancellables. Cover with ChatViewModel tests.
- **NodeStore commit timing**: existing executors commit the final assistant message to NodeStore at turn end. The partial buffer (`currentResponse`) must be cleared on `finishTurn` to prevent double rendering. This is a one-line fix in `finishTurn` but easy to miss — covered by integration test.
- **Memory footprint** of accumulated sessions: negligible in Phase 1; revisit if telemetry shows otherwise.
- **Galaxy / Inspector views that read ChatViewModel state**: any view reading the streaming triple should automatically work because forwarders preserve the API surface. If any view directly accessed `inFlightResponseTask`, those sites need updating — to be confirmed during implementation by grep.

## Future (out of scope)

- Persist partial buffer across app launches.
- Galaxy node "thinking" or "unread" visual states.
- Per-conversation generation history (multiple completed-but-unread turns queueing).
- User-visible global "running tasks" panel.
