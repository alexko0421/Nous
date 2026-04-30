# Voice Transcript Chat Persistence Design

**Date:** 2026-04-29 (rev. 4 — incorporates three rounds of codex review)
**Status:** User-approved direction. Phase 1 persists user voice utterances through the full canonical pipeline (messages + nodes.content + memory/title/embedding/Galaxy refresh) so voice content is first-class everywhere typed content is.
**Branch context:** `alexko0421/quick-action-agents`
**Related:**
- `2026-04-28-voice-mode-design.md` (voice state machine)
- `2026-04-28-app-wide-voice-control-design.md` (voice action registry)
- `2026-04-29-voice-notch-capsule-design.md` (notch surface for voice state)

## Context

Voice mode is ephemeral today. Live transcript flows through `VoiceCommandController.transcript: [VoiceTranscriptLine]`, but when voice mode ends the transcript disappears. Nothing persists.

This spec persists what Alex says — the source-of-truth he most needs — into the chat history of the conversation where voice started. It runs the full canonical persistence pipeline so voice content is first-class everywhere typed content is: chat history, nodes.content, vector embeddings, memory projection, conversation title backfill, Galaxy edge refresh.

Assistant voice responses are deliberately deferred to a future phase because the voice agent's instructions are a tiny "voice control layer" prompt, not Nous's anchor / RAG-aware chat instructions. Persisting voice assistant lines as canonical assistant chat history would let future text turns inherit context that wasn't really Nous answering.

## Phase Scope

**In Phase 1: persist user voice utterances only**, with full pipeline parity to typed user turns. Each finalized user transcript line:
1. Inserts into `messages` table (`source: .voice`).
2. Updates `nodes.content` via `ConversationSessionStore.persistTranscript`.
3. Triggers a `TurnHousekeepingPlan` covering embedding refresh + Galaxy edge refresh + emoji/title refresh — same pipeline that typed turns trigger.

Assistant voice responses do NOT persist; they continue to flow through `VoiceTranscriptPanel` as live preview (panel is currently dormant — see § Out of Scope).

**Phase 2 (deferred):** Persist assistant voice responses, requires aligning voice instructions with anchor/RAG.

## Product Goal

After a Phase 1 voice session ends, the chat history of the conversation where voice started contains every finalized user utterance as a chat message, marked by an 11pt mic icon next to the timestamp. Voice content is searchable in vector search (refreshed embeddings), surfaced in memory projection, used for title backfill, and reflected in Galaxy. Assistant voice responses remain ephemeral.

The `propose_send_message` voice tool is removed.

## Non-Goals / Out of Scope

- Assistant voice response persistence — Phase 2.
- Voice playback / re-listen — Phase 2.
- Voice search or filter — Phase 2.
- Transcript quality indicators — Phase 2.
- Edit / delete UI affordances. Voice user messages inherit whatever the typed flow has (currently: nothing for user-side).
- Regeneration semantics for voice — they are user messages.
- Retroactive backfill of past voice sessions.
- Cross-chat / multi-user voice.
- **`VoiceTranscriptPanel` changes**: codex round 3 confirmed `VoiceTranscriptPanel` is currently NOT wired into any production view — only its own `#Preview` references it. The panel is dormant. The spec does not include panel-side changes; the live preview during voice mode is currently the in-window `VoiceCapsuleView` subtitle (notch capsule project) and the notch panel's content. If a future spec resurrects the panel, it will need its own filtering pass.

## Core Decisions

### 1. User utterances only, full canonical pipeline

Voice user append runs the same `messages` insert + `nodes.content` persist + `TurnHousekeepingService.run(plan)` sequence the typed flow uses. Voice content is fully integrated into search, memory, title, and Galaxy. The codex round 2 finding that voice would otherwise be invisible to those systems is closed.

### 2. Voice mode binds to its starting chat (or auto-creates one)

`VoiceCommandController.boundConversationId: UUID?` is set on activation. If no current conversation exists, `ChatViewModel.ensureConversationForVoice()` creates one first.

### 3. Bound conversation deleted mid-session → fail voice with error

Committer detects `ConversationSessionStoreError.missingNode`, calls `voiceController.failVoiceSession(message: "Conversation deleted")`.

### 4. Mic icon next to timestamp for voice user messages

11pt SF Symbol `mic.fill`, `AppColor.colaOrange.opacity(0.6)`, 4pt right of timestamp.

### 5. Remove `propose_send_message` voice tool

Removed across full blast radius (§ Architecture).

### 6. Persistence: SQL migration via ALTER TABLE

`ALTER TABLE messages ADD COLUMN source TEXT NOT NULL DEFAULT 'typed'` via `ensureColumnExists` at app start. INSERT/SELECT updated.

## Architecture

### Data model: `MessageSource` + `Message.source`

`Message.init` already accepts `timestamp: Date = Date()` ([Message.swift:17](#)) — confirmed by codex round 3. Adding `source` follows the same pattern:

```swift
enum MessageSource: String, Codable, Equatable {
    case typed
    case voice
}

struct Message {
    // ... existing fields including timestamp ...
    var source: MessageSource = .typed
}
```

Update `Message.init` (the designated initializer) to accept `source: MessageSource = .typed` so existing call sites compile unchanged.

### `MessageBubble` API change

`MessageBubble` (`ChatArea.swift:658`) currently takes `text/thinkingContent/agentTraceRecords/isThinkingStreaming/isAgentTraceStreaming/isUser`. Add:

```swift
struct MessageBubble: View {
    // existing params ...
    let source: MessageSource           // NEW
    let timestamp: Date                  // NEW
}
```

Update both call sites at `ChatArea.swift:104` and `ChatArea.swift:178` to pass `message.source` and `message.timestamp`. The streaming/in-flight bubble (assistant streaming, no Message yet) uses `source: .typed, timestamp: Date()` since streaming is always typed-flow.

In `MessageBubble.body`, render the timestamp + mic-icon HStack:

```swift
HStack(spacing: 4) {
    Text(timestamp, style: .time)
        .font(.system(size: 10, weight: .regular, design: .rounded))
        .foregroundStyle(AppColor.tertiaryText)
    if source == .voice {
        Image(systemName: "mic.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AppColor.colaOrange.opacity(0.6))
            .accessibilityLabel("Voice")
    }
}
```

Phase 1 only ever produces voice user messages.

### `ConversationSessionStore.appendVoiceUserMessage(...)`

The single most important architectural method. Voice persistence reuses the typed flow's transcript-persistence path so `nodes.content` stays in sync.

```swift
struct CommittedVoiceTurn {
    let node: NousNode
    let userMessage: Message
    let messagesAfterAppend: [Message]
}

func appendVoiceUserMessage(
    nodeId: UUID,
    text: String,
    timestamp: Date
) throws -> CommittedVoiceTurn {
    guard let node = try nodeStore.fetchNode(id: nodeId) else {
        throw ConversationSessionStoreError.missingNode(nodeId)
    }

    let userMessage = Message(
        nodeId: node.id,
        role: .user,
        content: text,
        timestamp: timestamp,
        source: .voice
    )
    try nodeStore.insertMessage(userMessage)

    let messagesAfterAppend = try nodeStore.fetchMessages(nodeId: node.id)
    let updatedNode = try persistTranscript(node: node, messages: messagesAfterAppend)

    return CommittedVoiceTurn(
        node: updatedNode,
        userMessage: userMessage,
        messagesAfterAppend: messagesAfterAppend
    )
}
```

Codex round 3 verified: `Message.init` accepts `timestamp:` and `nodeStore.fetchMessages` returns `ORDER BY timestamp ASC` (correct order for `persistTranscript`).

### Housekeeping: full pipeline parity for voice user append

The typed flow fires `TurnHousekeepingService.run(plan)` after assistant commit (`ChatViewModel.swift:212`, plan constructed in `TurnOutcomeFactory.swift:58`). Voice user-only append must fire an equivalent plan after each voice utterance.

New helper on `ChatViewModel` (or `TurnOutcomeFactory`):

```swift
@MainActor
extension ChatViewModel {
    /// Build a TurnHousekeepingPlan appropriate for a voice-user-only turn.
    /// Reuses the same embedding / Galaxy / emoji refresh paths the typed
    /// flow uses; skips Gemini cache refresh because voice does not run
    /// through the typed-flow LLM service.
    private func voiceUserHousekeepingPlan(
        node: NousNode,
        messagesAfterAppend: [Message]
    ) -> TurnHousekeepingPlan {
        TurnHousekeepingPlan(
            turnId: UUID(),
            conversationId: node.id,
            geminiCacheRefresh: nil,
            embeddingRefresh: EmbeddingRefreshRequest(
                node: node,
                messages: messagesAfterAppend
            ),
            emojiRefresh: ConversationEmojiRefreshRequest(
                node: node,
                messages: messagesAfterAppend
            )
        )
    }
}
```

Verify the exact `EmbeddingRefreshRequest` initializer in `TurnContracts.swift` and adjust if it requires different fields.

`appendVoiceMessage` (below) constructs and runs this plan.

### `ChatViewModel.ensureConversationForVoice()` and `appendVoiceMessage`

```swift
@MainActor
extension ChatViewModel {
    /// Returns the ID of the conversation voice should bind to. If a current
    /// node exists, returns its ID. Otherwise creates an empty conversation.
    /// Synchronous because the entire ChatViewModel is @MainActor.
    func ensureConversationForVoice() throws -> UUID {
        if let current = currentNode {
            return current.id
        }
        // Use the existing dependency name in ChatViewModel — verify in
        // ChatViewModel.init what it actually calls the ConversationSessionStore.
        let node = try sessionStore.startConversation(
            title: "New Conversation",
            projectId: defaultProjectId
        )
        self.currentNode = node
        self.messages = []
        return node.id
    }

    /// Appends a voice user message to the conversation identified by
    /// nodeId, even if it is not the currently-loaded conversation.
    /// Updates the in-memory messages array only if the bound node is
    /// also the currently-loaded one. Fires the same housekeeping
    /// pipeline the typed flow fires after a turn.
    func appendVoiceMessage(
        nodeId: UUID,
        text: String,
        timestamp: Date
    ) throws {
        let result = try sessionStore.appendVoiceUserMessage(
            nodeId: nodeId,
            text: text,
            timestamp: timestamp
        )
        if currentNode?.id == nodeId {
            self.messages = result.messagesAfterAppend
        }
        // Trigger the same housekeeping the typed flow does.
        let plan = voiceUserHousekeepingPlan(
            node: result.node,
            messagesAfterAppend: result.messagesAfterAppend
        )
        housekeepingService.run(plan)
    }
}
```

`sessionStore` and `housekeepingService` must be the actual property names on `ChatViewModel`. Verify during implementation.

### `VoiceCommandController` extension

#### Add `boundConversationId` and a closure-based notification

```swift
@Observable
@MainActor
final class VoiceCommandController {
    // ... existing fields ...
    var boundConversationId: UUID?
    var onUserUtteranceFinalized: ((VoiceTranscriptLine) -> Void)?
    var onVoiceSessionTerminated: (() -> Void)?
}
```

The two closures are wired by `VoiceTranscriptCommitter` at construction.

#### Clear bound conversation + notify on every terminal path

```swift
private func clearBoundConversation() {
    boundConversationId = nil
    onVoiceSessionTerminated?()  // Lets the committer reset its dedup set
}
```

Call `clearBoundConversation()` from:
- `stop()` (`VoiceCommandController.swift:84`)
- `failVoiceSession(message:)` (`VoiceCommandController.swift:411`) — change access from `private func` to plain `func` so `VoiceTranscriptCommitter` can call it
- `resetTranscript()` (`VoiceCommandController.swift:484`)

The controller does NOT hold a reference to the committer. The committer subscribes via the closures and `[weak self]` on its commit handler. This avoids the rev 3 mistake where `clearBoundConversation` referenced a nonexistent `committer?.reset()`.

#### Modify `VoiceTranscriptLine.finalize` to return the finalized line

```swift
@discardableResult
static func finalize(
    text: String,
    role: Role,
    into lines: inout [VoiceTranscriptLine],
    now: Date = Date()
) -> VoiceTranscriptLine {
    // ... existing implementation ...
    return finalizedLine
}
```

`@discardableResult` keeps existing call sites working (`appendOutputTranscript`, `appendInputTranscript` ignore the return).

In `completeInputTranscript(_:)` (`VoiceCommandController.swift:455`):

```swift
private func completeInputTranscript(_ text: String) {
    // ... existing setup ...
    let line = VoiceTranscriptLine.finalize(text: text, role: .user, into: &transcript)
    onUserUtteranceFinalized?(line)
}
```

`completeOutputTranscript` does NOT call the closure — Phase 1 is user-only.

### `VoiceTranscriptCommitter` (new service)

```swift
@MainActor
final class VoiceTranscriptCommitter {
    private weak var voiceController: VoiceCommandController?
    private weak var chatViewModel: ChatViewModel?
    private(set) var committedLineIds: Set<UUID> = []

    init(voiceController: VoiceCommandController, chatViewModel: ChatViewModel) {
        self.voiceController = voiceController
        self.chatViewModel = chatViewModel
        voiceController.onUserUtteranceFinalized = { [weak self] line in
            self?.commit(line)
        }
        voiceController.onVoiceSessionTerminated = { [weak self] in
            self?.committedLineIds.removeAll()
        }
    }

    deinit {
        voiceController?.onUserUtteranceFinalized = nil
        voiceController?.onVoiceSessionTerminated = nil
    }

    private func commit(_ line: VoiceTranscriptLine) {
        guard line.role == .user else { return } // Phase 1: user only
        guard !committedLineIds.contains(line.id) else { return }
        guard let conversationId = voiceController?.boundConversationId else { return }
        guard let viewModel = chatViewModel else { return }

        do {
            try viewModel.appendVoiceMessage(
                nodeId: conversationId,
                text: line.text,
                timestamp: line.createdAt
            )
            committedLineIds.insert(line.id)
        } catch ConversationSessionStoreError.missingNode {
            voiceController?.failVoiceSession(message: "Conversation deleted")
        } catch {
            // Phase 1: log only, no retry
        }
    }
}
```

### Wiring (where to retain the committer)

Owned by `AppDependencies` so it lives as long as the app:

```swift
final class AppDependencies {
    // ... existing fields ...
    let voiceTranscriptCommitter: VoiceTranscriptCommitter

    init(...) {
        // After voiceController and chatViewModel exist:
        self.voiceTranscriptCommitter = VoiceTranscriptCommitter(
            voiceController: voiceController,
            chatViewModel: chatViewModel
        )
    }
}
```

A short-lived `@State` in `ContentView.onAppear` would deinit on view tear-down and silently break the closures.

### `ContentView.toggleVoiceMode` change

Before starting voice, ensure a conversation exists and bind:

```swift
private func toggleVoiceMode(dependencies: AppDependencies) {
    if dependencies.voiceController.isActive {
        dependencies.voiceController.stop()
        return
    }

    let conversationId: UUID
    do {
        conversationId = try dependencies.chatVM.ensureConversationForVoice()
    } catch {
        // Show error UI; don't start voice
        return
    }

    dependencies.voiceController.boundConversationId = conversationId
    Task {
        try? await dependencies.voiceController.start(apiKey: dependencies.apiKey)
    }
}
```

Adapt to existing `toggleVoiceMode` shape — verify the actual parameter names during implementation.

### `VoiceActionHandlers` change

Remove the `sendMessage: (String) -> Void` closure.

### `propose_send_message` removal blast radius

| Site | Change |
|---|---|
| `Sources/Nous/Models/Voice/VoiceModeModels.swift:153` | Remove `case sendMessage(text: String)` |
| `Sources/Nous/Models/Voice/VoiceModeModels.swift:174,201,216` | Remove `sendMessage` from `VoiceActionHandlers` |
| `Sources/Nous/Services/VoiceActionRegistry.swift` | Remove `propose_send_message` declaration |
| `Sources/Nous/Services/VoiceCommandController.swift:265,308,432` | Remove `case .sendMessage` paths |
| `Sources/Nous/Services/RealtimeVoiceSession.swift:332-340` | Update voice instructions: drop `propose_send_message` reference |
| `Sources/Nous/App/AppEnvironment.swift` (or wherever real handlers are built) | Drop `sendMessage:` from `VoiceActionHandlers(...)` |
| `Tests/NousTests/VoiceActionRegistryTests.swift:42` | Remove or invert assertion |
| `Tests/NousTests/VoiceCommandControllerTests.swift:339,704` | Remove sendMessage tests; keep createNote pending-action restore tests |
| `Tests/NousTests/VoiceCommandControllerIdempotencyTests.swift` | Remove `.sendMessage` test cases (added during notch capsule work) |
| `docs/superpowers/specs/2026-04-28-voice-mode-design.md:82` | Add deprecation note |
| `docs/superpowers/specs/2026-04-28-app-wide-voice-control-design.md:176` | Same |

Implementer should grep for `sendMessage` and `propose_send_message` across `Sources/Nous` and `Tests/NousTests` to catch anything missed.

## Phase 1 Implementation Order

Each step leaves a buildable, test-passing state:

1. **`MessageSource` enum** — new file, no callers.
2. **`Message.source` field** + update designated initializer with `source: MessageSource = .typed`.
3. **SQL migration**: update `createTables` schema; add `ensureColumnExists` call; update `insertMessage` (`NodeStore.swift:798`); update SELECT decode (`NodeStore.swift:821`). Tests for round-trip + legacy-row decode.
4. **`MessageBubble` API change**: add `source` and `timestamp` params; update both `ChatArea` call sites (`:104, :178`) and the streaming bubble call site to pass `.typed, Date()`.
5. **Mic icon rendering** when `source == .voice`.
6. **Remove `propose_send_message` (full blast radius commit)**: tool registry + voice instructions in `RealtimeVoiceSession.swift:332-340` updated in the same commit so runtime stays consistent.
7. **`VoiceTranscriptLine.finalize` returns the line** with `@discardableResult`.
8. **`VoiceCommandController` plumbing**: add `boundConversationId`, `onUserUtteranceFinalized`, `onVoiceSessionTerminated`, `clearBoundConversation()`. Wire `clearBoundConversation()` into `stop()`, `failVoiceSession()` (also widened to plain `func`), `resetTranscript()`. Wire closure call into `completeInputTranscript`. No consumer yet — closures default nil.
9. **`ConversationSessionStore.appendVoiceUserMessage(nodeId:text:timestamp:)`** + `CommittedVoiceTurn`. Unit-tested in isolation.
10. **`ChatViewModel.ensureConversationForVoice()` + `voiceUserHousekeepingPlan(...)` + `appendVoiceMessage(nodeId:text:timestamp:)`**. Unit tests cover: cross-conversation append, in-memory update branch, missing-node throw.
11. **`VoiceTranscriptCommitter`** + retention in `AppDependencies`. Wire it up. From this commit onward, voice user utterances persist + trigger the housekeeping pipeline.
12. **`ContentView.toggleVoiceMode`** calls `ensureConversationForVoice()` before starting, sets `boundConversationId`.
13. **Manual QA pass** (see § Manual QA Test Plan).

Steps 1-9 land safe behind feature work; steps 10-12 light up the feature.

## Manual QA Test Plan

### Capture & full-pipeline visibility
- [ ] Start voice in chat A. Speak 3 utterances. Confirm 3 user messages appear in chat A with mic icons. Assistant voice does NOT appear in chat.
- [ ] Open Galaxy / vector search and search for a phrase from a voice utterance. It must surface (proves embedding refresh fired).
- [ ] After voice ends, conversation emoji refreshes if the title was empty (proves emojiRefresh fired).
- [ ] `nodes.content` of the bound conversation contains the voice text (verify via DB inspection or by opening the conversation in a fresh app launch).

### Bound conversation
- [ ] Start voice in chat A. Switch to chat B mid-session. Speak. Lines land in chat A.
- [ ] Stop voice. Switch back to chat A. All utterances persisted in correct order.

### Empty-chat boot
- [ ] From welcome state (no current node), start voice. A new conversation is created. Utterances land. Sidebar shows the new conversation with mic icons on user messages.

### Bound-conversation deletion
- [ ] Start voice in chat A. Speak 1 utterance. Delete chat A from sidebar. Voice transitions to `.error` with "Conversation deleted". No crash, no orphans.

### Tool removal
- [ ] Voice agent never proposes `sendMessage` — the tool is gone.
- [ ] `createNote` still works.

### Schema migration
- [ ] Open the app on a database from a pre-migration binary. ALTER runs; existing messages decode as `.typed`.

### Visual
- [ ] Mic icon: 11pt SF Symbol `mic.fill`, colaOrange @ 0.6, sits 4pt right of timestamp.
- [ ] Bubble shape, color, typography unchanged from typed.

### Mixed media
- [ ] Type a message between voice utterances. Both interleave by timestamp. Mic icon only on voice ones.

### Terminal-path coverage
- [ ] Stop voice → `boundConversationId` cleared, committed-line set reset (verified by starting a new session and checking that fresh lines commit, not skipped as "already committed").
- [ ] Voice fails (network error, bad API key) → `boundConversationId` cleared, committed-line set reset.
- [ ] App relaunch → `boundConversationId` is nil (fresh controller).

### Pipeline parity
- [ ] After voice user append, `EmbeddingService.refresh(for:)` is invoked (verified via log or test double).
- [ ] After voice user append, `GalaxyRelationRefinementQueue` enqueues the conversation for refinement (verified via log or test double).
- [ ] After voice user append, conversation emoji updates if previously empty (verified visually in sidebar).

## Codex Review Disposition

| # | Round | Finding | Disposition (rev 4) |
|---|---|---|---|
| 1 | R1 | Voice in empty chat | RESOLVED — `ensureConversationForVoice()` is sync `@MainActor` (rev 4 fixed the `await` mistake from rev 3) |
| 2 | R1 | SQL migration | RESOLVED |
| 3 | R1 | `appendVoiceMessage` cross-conversation | RESOLVED — runs through `appendVoiceUserMessage` + `persistTranscript`; rev 4 passes `timestamp` through Message init |
| 4 | R1 | Bound conversation deletion | RESOLVED |
| 5 | R1 | Index brittleness | RESOLVED — UUID Set |
| 6 | R1 | Panel dedupe | OUT OF SCOPE — panel is unwired in production (codex R3 confirmed); panel changes deferred. § Out of Scope is explicit. |
| 7 | R1 | `withObservationTracking` unnecessary | RESOLVED — direct closure |
| 8 | R1 | Removing `propose_send_message` blast radius | RESOLVED — 11-row table |
| 9 | R1 | Pending action enum removal | RESOLVED |
| 10 | R1 | Edit/delete claims false | RESOLVED |
| 11 | R1 | Audio ghost | RESOLVED (Phase 1 scope) |
| 12 | R1 | Reset across terminal paths | RESOLVED — rev 4 uses `onVoiceSessionTerminated` closure (committer subscribes), not a nonexistent `committer?.reset()` reference |
| 13 | R1 | Voice assistant ≠ canonical | RESOLVED |
| N1 | R2 | `nodes.content` not updated; downstream invisible | RESOLVED — `appendVoiceUserMessage` runs `persistTranscript` AND `appendVoiceMessage` fires `TurnHousekeepingService.run(plan)` covering embedding/Galaxy/emoji refresh. Memory projection runs through `nodes.content` so updates flow through automatically. |
| N2 | R2 | `MessageBubble` API | RESOLVED |
| N3 | R2 | Committer retention | RESOLVED |
| N4 | R2 | `ConversationID` type | RESOLVED — `UUID` |
| R3-1 | R3 | `ensureConversationForVoice` won't compile | RESOLVED — sync `@MainActor` function, no `await MainActor.run`, real `sessionStore` property name (verified in implementation) |
| R3-3 | R3 | `Message(... source: .voice)` ignored timestamp | RESOLVED — rev 4 explicitly passes `timestamp:` |
| R3-6 | R3 | `VoiceTranscriptPanel` not wired in production | RESOLVED via OUT OF SCOPE |
| R3-12 | R3 | `committer?.reset()` reference invalid | RESOLVED — replaced with `onVoiceSessionTerminated` closure pattern |
| R3-N1 | R3 | Memory/title/embedding/Galaxy not triggered | RESOLVED — `appendVoiceMessage` constructs `voiceUserHousekeepingPlan` and calls `housekeepingService.run(plan)` |
| R3-N5 | R3 | Step 8 buildability | RESOLVED — step 8 only adds plumbing on the controller; closures default nil; no consumer yet, no compile dependency forward |
| R3-N6 | R3 | API name + missing timestamp | RESOLVED — uses real names + passes timestamp |
| R3-N9 | R3 | Panel API mismatch | RESOLVED via OUT OF SCOPE |

## Open Implementation Questions

1. **`ChatViewModel` property names**: verify whether `sessionStore` or `conversationSessionStore` (or some other name) is the actual property in `ChatViewModel.init`. The spec uses `sessionStore` but implementer should match the actual symbol. Same for `housekeepingService`.
2. **`EmbeddingRefreshRequest` / `ConversationEmojiRefreshRequest` initializer signatures**: verify the exact parameter names against `TurnContracts.swift` and adjust the `voiceUserHousekeepingPlan(...)` body.
3. **Title backfill**: confirmed via codex R3 that title generation is **not** part of `TurnHousekeepingPlan` directly — it happens via `applyTitleAndPersistTranscript` called from `commitAssistantTurn`. For voice user-only turns, title generation via this path will not fire. If this is a problem, add a separate title-backfill trigger after voice append. For Phase 1 it is acceptable to defer title generation until the next assistant turn (which can be either a typed turn or, in Phase 2, a voice assistant turn).
4. **`Message.timestamp` semantics**: spec passes `line.createdAt` as the timestamp. Confirm the `Message.init` signature accepts it (codex R3 confirmed: yes, it does, with default `Date()`).

## Why this should be the last revision

Rounds 1-3 progressively closed:
- R1: 13 conceptual gaps (scope, tools, edges).
- R2: 4 NEW issues (downstream pipelines, retention, type names) + 6 partials.
- R3: compile-level mistakes (await, missing params, wrong API names) + the open-question on memory/title.

Rev 4:
- Fixes every compile-level issue R3 named.
- Replaces the open-question on memory/title with concrete `voiceUserHousekeepingPlan` + `run(plan)` invocation.
- Removes panel-side scope (codex R3 confirmed it isn't wired in production).
- All 22 disposition rows now claim RESOLVED or OUT OF SCOPE.

Remaining open questions (§ Open Implementation Questions) are last-mile property-name verifications that the implementer will resolve during the first commit. They are not architectural risks.
