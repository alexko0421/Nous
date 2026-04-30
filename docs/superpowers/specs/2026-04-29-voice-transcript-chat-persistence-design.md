# Voice Transcript Chat Persistence Design

**Date:** 2026-04-29 (rev. 5 — incorporates four rounds of codex review)
**Status:** Ship-ready scope: messages + nodes.content + embedding / Galaxy / emoji refresh after every voice user append. Memory refresh + title generation deliberately defer to the next assistant turn (architectural reality — those pipelines require a user+assistant pair to make semantic sense).
**Branch context:** `alexko0421/quick-action-agents`
**Related:**
- `2026-04-28-voice-mode-design.md` (voice state machine)
- `2026-04-28-app-wide-voice-control-design.md` (voice action registry)
- `2026-04-29-voice-notch-capsule-design.md` (notch surface for voice state)

## Context

Voice mode is ephemeral today. Live transcript flows through `VoiceCommandController.transcript: [VoiceTranscriptLine]`, but when voice mode ends the transcript disappears. Nothing persists.

This spec persists what Alex says — the source-of-truth he most needs — into the chat history of the conversation where voice started, and through the pipelines that keep voice content discoverable: SQL `messages` table, `nodes.content` text blob, vector embeddings, Galaxy edge refresh, conversation emoji refresh.

**Memory projection and title generation are explicitly deferred** to the next assistant turn (typed) or to Phase 2 (when assistant voice persistence is added). Both pipelines are designed around a user+assistant turn pair (`ContextContinuationPlan` runs after `commitAssistantTurn`, title backfill happens inside `applyTitleAndPersistTranscript`). Forcing them on a user-only voice append would either generate incomplete state or require parallel pipelines that diverge from the canonical flow. The cleaner answer: voice user content is searchable, in `nodes.content`, and embedded — so the next typed turn picks it up naturally as context, and any continuation/title decisions then run on the full picture.

Assistant voice responses also defer to Phase 2 — the voice agent uses a tiny "voice control layer" prompt, not Nous's anchor / RAG instructions, so persisting voice assistant lines as canonical chat history would let future text turns inherit context that wasn't really Nous answering.

## Phase Scope

**Phase 1 (this spec):**

After each finalized user voice utterance:

1. INSERT into `messages` (with `source: .voice`).
2. UPDATE `nodes.content` via `ConversationSessionStore.persistTranscript`.
3. RUN `TurnHousekeepingService.run(plan)` covering: embedding refresh + Galaxy edge refinement + conversation emoji refresh.

Voice content is searchable (text-search via `nodes.content`, vector-search via fresh embeddings), surfaces in Galaxy, and updates the conversation's emoji. The chat history shows voice user messages with mic icons.

**Explicitly out of Phase 1 scope:**

- **Memory projection refresh** (`UserMemoryScheduler` / `MemoryProjectionService`): runs through `ContextContinuationPlan` after assistant commit. Voice user content lands in `nodes.content`, so the next typed assistant turn's continuation plan picks it up naturally. Voice-only sessions don't trigger memory refresh until they're followed by a typed turn.
- **Title generation** (`applyTitleAndPersistTranscript`): runs inside `commitAssistantTurn`. Voice-only sessions don't generate titles. The conversation keeps whatever title it has (or "New Conversation" if voice was the first thing).
- **Assistant voice response persistence**: deferred entirely. See § Phase 2.

**Phase 2 (deferred):** Persist assistant voice responses + align voice instructions with anchor/RAG so memory/title pipelines have full input.

## Product Goal

After a Phase 1 voice session ends:
- The chat history of the bound conversation contains every finalized user utterance with mic icons.
- The bound conversation's emoji is refreshed.
- The bound conversation's vector embedding is refreshed (vector search surfaces voice content).
- Galaxy edges between the bound conversation and others are refined.
- Memory projection and conversation title remain unchanged from before voice started — they will refresh naturally on the next typed assistant turn.

The `propose_send_message` voice tool is removed.

## Non-Goals / Out of Scope

- Assistant voice response persistence — Phase 2.
- Voice playback / re-listen — Phase 2.
- Voice search or filter — Phase 2.
- Transcript quality indicators — Phase 2.
- Edit / delete UI affordances. Voice user messages inherit whatever the typed flow has (currently: nothing for user-side).
- Regeneration semantics for voice — they are user messages; user messages don't regenerate.
- Retroactive backfill of past voice sessions.
- Cross-chat / multi-user voice.
- **`VoiceTranscriptPanel` changes**: codex round 3 confirmed the panel is unwired in production. The spec does not include panel-side changes.
- **Memory refresh / title backfill on voice-only sessions**: defers to next typed assistant turn or Phase 2 (see § Context for the architectural reason).

## Core Decisions

### 1. Phase 1 fires housekeeping pipeline only (not continuation plan)

Each voice user append runs `messages` INSERT + `persistTranscript` + `TurnHousekeepingService.run(plan)`. The plan covers embedding / Galaxy / emoji. `ContextContinuationPlan` (memory) and title backfill remain on the typed-turn-only path.

### 2. Voice mode binds to its starting chat (or auto-creates one)

`VoiceCommandController.boundConversationId: UUID?` is set on activation by `ContentView.toggleVoiceMode` AFTER calling `chatVM.ensureConversationForVoice()` so a node always exists.

### 3. Bound conversation deleted mid-session → fail voice with error

Committer detects `ConversationSessionStoreError.missingNode`, calls `voiceController.failVoiceSession(message: "Conversation deleted")`.

### 4. Mic icon next to timestamp for voice user messages

11pt SF Symbol `mic.fill`, `AppColor.colaOrange.opacity(0.6)`, 4pt right of timestamp.

### 5. Remove `propose_send_message` voice tool

Removed across full blast radius (§ Architecture).

### 6. Persistence: SQL migration via ALTER TABLE

`ALTER TABLE messages ADD COLUMN source TEXT NOT NULL DEFAULT 'typed'` via `ensureColumnExists` at app start. INSERT/SELECT updated.

### 7. Reset-vs-terminate: separate concerns (codex R4 fix)

`resetTranscript()` clears the transcript array only. `clearBoundConversation()` clears binding + notifies committer to reset its dedup set. They are called from different sites:

| Method | Calls `resetTranscript()` | Calls `clearBoundConversation()` |
|---|---|---|
| `markListening()` | yes (existing behavior) | NO |
| `start(apiKey:)` initial path | inherits via `markListening()` | NO |
| `stop()` | yes | yes |
| `failVoiceSession(...)` | yes | yes |
| `deinit` (defensive) | n/a | yes |

This is the codex R4 finding fix. Rev 4's mistake was making `resetTranscript()` call `clearBoundConversation()`, which would clear the binding the moment voice started (because `markListening` runs `resetTranscript` immediately).

## Architecture

### Data model: `MessageSource` + `Message.source`

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

`Message.init` already accepts `timestamp: Date = Date()` (verified in `Message.swift:17`). Add `source: MessageSource = .typed` to the designated initializer so existing call sites compile unchanged.

### `MessageBubble` API change

Add `source: MessageSource` and `timestamp: Date` parameters to `MessageBubble` (`ChatArea.swift:658`). Update both call sites at `ChatArea.swift:104, :178` to pass `message.source` and `message.timestamp`. The streaming bubble call site uses `source: .typed, timestamp: Date()`.

In `MessageBubble.body`:

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

### `ConversationSessionStore.appendVoiceUserMessage(...)`

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

### Housekeeping: `voiceUserHousekeepingPlan(...)` (codex R4 + R3 fixes)

Codex R4 surfaced the actual `EmbeddingRefreshRequest` shape (`nodeId/fullContent`, not `node/messages`). The fix:

```swift
@MainActor
extension ChatViewModel {
    private func voiceUserHousekeepingPlan(
        node: NousNode,
        messagesAfterAppend: [Message]
    ) -> TurnHousekeepingPlan {
        TurnHousekeepingPlan(
            turnId: UUID(),
            conversationId: node.id,
            geminiCacheRefresh: nil,
            embeddingRefresh: EmbeddingRefreshRequest(
                nodeId: node.id,
                fullContent: node.content      // updated by persistTranscript
            ),
            emojiRefresh: ConversationEmojiRefreshRequest(
                node: node,
                messages: messagesAfterAppend
            )
        )
    }
}
```

`node.content` is the freshly-persisted transcript blob from `persistTranscript`'s return value.

### `ChatViewModel.ensureConversationForVoice()` and `appendVoiceMessage`

`ChatViewModel` is `@MainActor` (verified `ChatViewModel.swift:1`). The actual property names are `conversationSessionStore` (codex R4) and `turnHousekeepingService` (codex R4). The extension goes in `ChatViewModel.swift` so private members are accessible (codex R4).

```swift
@MainActor
extension ChatViewModel {
    /// Returns the ID of the conversation voice should bind to. If a current
    /// node exists, returns its ID. Otherwise creates an empty conversation.
    func ensureConversationForVoice() throws -> UUID {
        if let current = currentNode {
            return current.id
        }
        let node = try conversationSessionStore.startConversation(
            title: "New Conversation",
            projectId: defaultProjectId
        )
        self.currentNode = node
        self.messages = []
        return node.id
    }

    /// Appends a voice user message and runs the housekeeping pipeline.
    func appendVoiceMessage(
        nodeId: UUID,
        text: String,
        timestamp: Date
    ) throws {
        let result = try conversationSessionStore.appendVoiceUserMessage(
            nodeId: nodeId,
            text: text,
            timestamp: timestamp
        )
        if currentNode?.id == nodeId {
            self.messages = result.messagesAfterAppend
        }
        let plan = voiceUserHousekeepingPlan(
            node: result.node,
            messagesAfterAppend: result.messagesAfterAppend
        )
        turnHousekeepingService.run(plan)
    }
}
```

`defaultProjectId` is whatever existing pattern `ChatViewModel` uses for new conversations — verify against `ChatViewModel.send`.

### `VoiceCommandController` extension

```swift
@Observable
@MainActor
final class VoiceCommandController {
    // existing fields ...
    var boundConversationId: UUID?
    var onUserUtteranceFinalized: ((VoiceTranscriptLine) -> Void)?
    var onVoiceSessionTerminated: (() -> Void)?
}
```

#### Reset-vs-terminate split (codex R4 fix)

```swift
private func clearBoundConversation() {
    boundConversationId = nil
    onVoiceSessionTerminated?()
}
```

Call sites:
- `stop()` (`VoiceCommandController.swift:84`): calls `clearBoundConversation()` AND `resetTranscript()`.
- `failVoiceSession(message:)` (`VoiceCommandController.swift:411`): calls `clearBoundConversation()` AND `resetTranscript()` (existing). Also: change access from `private func` to plain `func`.
- `markListening()` (`VoiceCommandController.swift:51`): calls `resetTranscript()` only — does NOT clear binding (binding is set BEFORE `start()` by `ContentView.toggleVoiceMode`).
- `resetTranscript()` itself: clears the transcript array only. Does NOT clear binding.
- `deinit`: defensive `clearBoundConversation()`.

#### `VoiceTranscriptLine.finalize` returns the finalized line

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

In `completeInputTranscript(_:)` (`VoiceCommandController.swift:455`):

```swift
private func completeInputTranscript(_ text: String) {
    // existing setup ...
    let line = VoiceTranscriptLine.finalize(text: text, role: .user, into: &transcript)
    onUserUtteranceFinalized?(line)
}
```

`completeOutputTranscript` does NOT call the closure — Phase 1 is user-only.

### `VoiceTranscriptCommitter` (new)

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
        guard line.role == .user else { return }
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
            // Phase 1: log only, no retry.
        }
    }
}
```

### Wiring (`AppDependencies` retains the committer)

```swift
final class AppDependencies {
    let voiceTranscriptCommitter: VoiceTranscriptCommitter

    init(...) {
        // After voiceController and chatViewModel are constructed:
        self.voiceTranscriptCommitter = VoiceTranscriptCommitter(
            voiceController: voiceController,
            chatViewModel: chatViewModel
        )
    }
}
```

### `ContentView.toggleVoiceMode` change

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
        // Show error UI; do not start voice.
        return
    }

    // CRITICAL: bind BEFORE start() runs markListening → resetTranscript.
    // resetTranscript no longer clears the binding (rev 5 fix), but the
    // ordering is still meaningful: committer's onUserUtteranceFinalized
    // closure must see boundConversationId set when the first utterance
    // arrives.
    dependencies.voiceController.boundConversationId = conversationId
    Task {
        try? await dependencies.voiceController.start(apiKey: dependencies.apiKey)
    }
}
```

Adapt to actual existing `toggleVoiceMode` shape.

### `VoiceActionHandlers` change

Remove `sendMessage: (String) -> Void`.

### `propose_send_message` removal blast radius

| Site | Change |
|---|---|
| `Sources/Nous/Models/Voice/VoiceModeModels.swift:153` | Remove `case sendMessage(text: String)` |
| `Sources/Nous/Models/Voice/VoiceModeModels.swift:174,201,216` | Remove `sendMessage` from `VoiceActionHandlers` |
| `Sources/Nous/Services/VoiceActionRegistry.swift` | Remove `propose_send_message` declaration |
| `Sources/Nous/Services/VoiceCommandController.swift:265,308,432` | Remove `case .sendMessage` paths |
| `Sources/Nous/Services/RealtimeVoiceSession.swift:332-340` | Update voice instructions: drop `propose_send_message` reference. **Same commit as registry removal so runtime never sees inconsistent state.** |
| `Sources/Nous/App/AppEnvironment.swift` | Drop `sendMessage:` from `VoiceActionHandlers(...)` |
| `Tests/NousTests/VoiceActionRegistryTests.swift:42` | Remove or invert assertion |
| `Tests/NousTests/VoiceCommandControllerTests.swift:339,704` | Remove sendMessage tests; keep createNote pending-action restore |
| `Tests/NousTests/VoiceCommandControllerIdempotencyTests.swift` | Remove `.sendMessage` test cases |
| `docs/superpowers/specs/2026-04-28-voice-mode-design.md:82` | Add deprecation note |
| `docs/superpowers/specs/2026-04-28-app-wide-voice-control-design.md:176` | Same |

## Phase 1 Implementation Order

Each step leaves a buildable state:

1. **`MessageSource` enum** — new file, no callers.
2. **`Message.source` field** + update designated initializer (`source: MessageSource = .typed`).
3. **SQL migration**: `createTables` schema; `ensureColumnExists` call; `insertMessage` (`NodeStore.swift:798`); SELECT decode (`NodeStore.swift:821`). Tests for round-trip + legacy-row decode.
4. **`MessageBubble` API change**: add `source/timestamp` params; update both `ChatArea` call sites + the streaming bubble (`source: .typed, timestamp: Date()`).
5. **Mic icon rendering** when `source == .voice`.
6. **Remove `propose_send_message` (full blast radius commit)**: registry + `RealtimeVoiceSession.swift:332-340` instructions + tests + parent specs in same commit.
7. **`VoiceTranscriptLine.finalize` returns the line** with `@discardableResult`.
8. **`VoiceCommandController` plumbing**: add `boundConversationId`, `onUserUtteranceFinalized`, `onVoiceSessionTerminated`, `clearBoundConversation()`. Wire `clearBoundConversation()` into `stop()`, `failVoiceSession()` (also widened to plain `func`), and `deinit`. **Do NOT call it from `resetTranscript()`** — codex R4 fix. Wire closure call into `completeInputTranscript`.
9. **`ConversationSessionStore.appendVoiceUserMessage(nodeId:text:timestamp:)`** + `CommittedVoiceTurn`. Unit tested.
10. **`ChatViewModel.ensureConversationForVoice()` + `voiceUserHousekeepingPlan(...)` + `appendVoiceMessage(nodeId:text:timestamp:)`** in `ChatViewModel.swift`. Use real property names: `conversationSessionStore`, `turnHousekeepingService`. Use real `EmbeddingRefreshRequest` init: `nodeId/fullContent`. Unit tests.
11. **`VoiceTranscriptCommitter`** + retention in `AppDependencies`.
12. **`ContentView.toggleVoiceMode`** calls `ensureConversationForVoice()` and sets `boundConversationId` BEFORE `voiceController.start(...)`.
13. **Manual QA pass** (see § Manual QA Test Plan).

## Manual QA Test Plan

### Capture & full pipeline (Phase 1 scope only)
- [ ] Start voice in chat A. Speak 3 utterances. 3 user messages appear in chat A with mic icons. Assistant voice does NOT appear in chat.
- [ ] Open vector search and search for a phrase from a voice utterance. It must surface (proves embedding refresh fired). If surfacing requires a code-level inspection point, set a `print` in `EmbeddingService.embed` (or whatever the actual write path is) and verify the print fires after each voice utterance.
- [ ] After voice ends, the bound conversation's emoji updates if it was previously empty (proves emoji refresh fired).
- [ ] `nodes.content` of the bound conversation contains the voice text (verify via DB inspection or by reopening the conversation in a fresh app launch).

### Memory + title (verify Phase 1 deferral)
- [ ] After a voice-only session (no typed turns), open Memory tab — voice user content does NOT appear in memory yet. This is expected per § Phase Scope.
- [ ] Type a message in the same conversation. After Nous responds, memory refresh fires and now picks up the voice content (it's in `nodes.content`). This is the deferred-pickup path.
- [ ] After a voice-only session with no prior title, the conversation title remains "New Conversation". After the next typed assistant turn, title generation runs.

### Bound conversation
- [ ] Start voice in chat A. Switch to chat B mid-session. Speak. Lines land in chat A.
- [ ] Stop voice. Switch back to chat A. All utterances persisted in correct order.

### Empty-chat boot
- [ ] From welcome state, start voice. New conversation created. Utterances land. Sidebar shows the new conversation with mic icons.

### Bound-conversation deletion
- [ ] Start voice in chat A. Speak 1 utterance. Delete chat A. Voice transitions to `.error` with "Conversation deleted". No crash.

### Tool removal
- [ ] Voice agent never proposes `sendMessage`. `createNote` still works.

### Schema migration
- [ ] Open the app on a pre-migration database. ALTER runs; existing messages decode as `.typed`.

### Visual
- [ ] Mic icon: 11pt SF Symbol `mic.fill`, colaOrange @ 0.6, 4pt right of timestamp.
- [ ] Bubble visuals identical to typed.

### Mixed media
- [ ] Type between voice utterances. Both interleave by timestamp. Mic icons only on voice.

### Reset-vs-terminate (codex R4 regression test)
- [ ] **CRITICAL**: Start voice. Within 1 second, the binding must still be set. Speak immediately. The first utterance must land in chat. (Verifies `markListening` → `resetTranscript` does NOT clear binding.)
- [ ] Stop voice → `boundConversationId` is nil, committer's set is empty.
- [ ] Voice fails (network error, bad API key) → same.
- [ ] App relaunch → `boundConversationId` is nil.

## Codex Review Disposition

| # | Round | Finding | Disposition (rev 5) |
|---|---|---|---|
| 1 | R1 | Voice in empty chat | RESOLVED |
| 2 | R1 | SQL migration (raw SQLite) | RESOLVED |
| 3 | R1 | `appendVoiceMessage` cross-conversation | RESOLVED |
| 4 | R1 | Bound conversation deletion | RESOLVED |
| 5 | R1 | Index brittleness | RESOLVED |
| 6 | R1 | Panel dedupe | OUT OF SCOPE (panel unwired) |
| 7 | R1 | `withObservationTracking` | RESOLVED |
| 8 | R1 | Removing `propose_send_message` blast radius | RESOLVED |
| 9 | R1 | Pending action enum removal | RESOLVED |
| 10 | R1 | Edit/delete claims false | RESOLVED |
| 11 | R1 | Audio ghost | RESOLVED (Phase 1 scope) |
| 12 | R1 | Reset across terminal paths | RESOLVED via `onVoiceSessionTerminated` closure |
| 13 | R1 | Voice assistant ≠ canonical | RESOLVED |
| N1 | R2 | `nodes.content` not updated | RESOLVED via `persistTranscript` + housekeeping |
| N2 | R2 | `MessageBubble` API | RESOLVED |
| N3 | R2 | Committer retention | RESOLVED (`AppDependencies`) |
| N4 | R2 | `ConversationID` type | RESOLVED (`UUID`) |
| R3-1 | R3 | `ensureConversationForVoice` compile | RESOLVED |
| R3-3 | R3 | `Message(... source:)` ignored timestamp | RESOLVED |
| R3-6 | R3 | `VoiceTranscriptPanel` unwired | RESOLVED via OUT OF SCOPE |
| R3-12 | R3 | `committer?.reset()` invalid | RESOLVED via closure pattern |
| R3-N1 | R3 | Memory/title not triggered | **PARTIALLY RESOLVED → ACCEPTED via scope reduction**: housekeeping (embedding/Galaxy/emoji) fires; memory/title defer to next typed turn. § Phase Scope and § Non-Goals make this explicit. |
| R3-N5 | R3 | Step buildability | RESOLVED |
| R3-N6 | R3 | API names | RESOLVED |
| R3-N9 | R3 | Panel API mismatch | RESOLVED via OUT OF SCOPE |
| R4-1 | R4 | Binding cleared at voice start (catastrophic) | **RESOLVED — `resetTranscript()` no longer calls `clearBoundConversation()`. § 7 (Reset-vs-terminate) makes the split explicit. Manual QA includes a regression test for this.** |
| R4-2 | R4 | Memory + title not in housekeeping | **RESOLVED via scope reduction → § Phase Scope explicitly defers them.** |
| R4-prop1 | R4 | `sessionStore` wrong name | RESOLVED — `conversationSessionStore` |
| R4-prop2 | R4 | `housekeepingService` wrong name | RESOLVED — `turnHousekeepingService` |
| R4-prop3 | R4 | `EmbeddingRefreshRequest` wrong shape | RESOLVED — `nodeId/fullContent` |
| R4-test | R4 | `EmbeddingService.refresh(for:)` doesn't exist | RESOLVED — QA plan now uses search-side observation, not nonexistent API |

## Open Implementation Questions

1. **`ChatViewModel.defaultProjectId`**: verify the actual symbol used by `ChatViewModel.send` for new-conversation project assignment. Use the same one in `ensureConversationForVoice`.
2. **`AppDependencies` init order**: voice controller and chat view model must both exist before `VoiceTranscriptCommitter` is constructed. Verify the existing init order accommodates this; if not, reorder.
3. **`Message` designated initializer**: confirm exact parameter order when adding `source`. Place it last (after `timestamp`) to keep call-site noise minimal.
