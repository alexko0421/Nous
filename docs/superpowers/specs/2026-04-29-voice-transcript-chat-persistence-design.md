# Voice Transcript Chat Persistence Design

**Date:** 2026-04-29 (rev. 2 — incorporates codex review findings)
**Status:** User-approved direction. Phase 1 scope tightened to user utterances only after codex flagged voice-control-layer pollution risk.
**Branch context:** `alexko0421/quick-action-agents`
**Related:**
- `2026-04-28-voice-mode-design.md` (voice state machine)
- `2026-04-28-app-wide-voice-control-design.md` (voice action registry)
- `2026-04-29-voice-notch-capsule-design.md` (notch surface for voice state)

## Context

Voice mode is ephemeral today. Live transcript flows through `VoiceCommandController.transcript: [VoiceTranscriptLine]` and surfaces in `VoiceTranscriptPanel`, but when voice mode ends the transcript disappears. Nothing persists to the chat conversation.

The result is that long voice conversations leave no record. Alex can talk to Nous for ten minutes about a hard decision and walk away with nothing in the chat thread to revisit.

This spec persists what Alex says, the source-of-truth he most needs, into chat history. **Assistant voice responses are deliberately deferred to a future phase** because of a deeper product question codex review surfaced.

## Phase Scope (revised after codex review)

**In Phase 1: persist user voice utterances only.** Each finalized user transcript line lands in the chat history of the conversation where voice mode started. Assistant voice responses do **not** persist to chat in this phase. They continue to flow through `VoiceTranscriptPanel` as live preview and disappear when voice ends.

**Why the asymmetry:** the voice agent's instructions are a tiny "voice control layer" prompt (`RealtimeVoiceSession.swift:332-340`), not Nous's anchor / RAG-aware chat instructions. If we naively persist voice assistant lines as canonical assistant chat history, future text turns will inherit context that wasn't really Nous answering — it was the control layer answering. That's a product semantic problem, not an implementation problem, and it deserves its own spec.

**Phase 2 (deferred):** Persist assistant voice responses, with whatever metadata or instruction-layer alignment turns out to be the right answer (likely: align voice instructions with anchor/RAG so the two layers produce comparable assistant prose, then persist them as canonical assistant messages).

## Product Goal

After a Phase 1 voice session ends, the chat history of the conversation where voice started contains every finalized user utterance as a chat message, marked by an 11pt mic icon next to the timestamp. Editing, deletion, and any other affordances available to typed user messages work the same way on voice user messages — i.e., they get whatever the typed flow has. Assistant voice responses remain ephemeral; they live in the transcript panel and are not written to chat.

The `propose_send_message` voice tool is **removed** because the voice agent's "compose-and-send" indirection is dead weight once user utterances auto-record. `propose_create_note` and the action / navigation tools stay.

## Non-Goals

- No assistant voice response persistence — Phase 2.
- No voice playback / re-listen — Phase 2.
- No voice search or filter — Phase 2.
- No transcript-quality indicator on bubbles — Phase 2.
- No new edit / delete UI affordances. Voice user messages inherit whatever the typed flow already has. (User typed messages currently have **no** edit/delete UI; voice user messages will be the same. The spec does not invent new UI for edit/delete.)
- No regeneration semantics for voice messages — they're user messages; user messages don't regenerate.
- No retroactive backfill of past voice sessions.
- No cross-chat or multi-user voice.

## Core Decisions

### 1. User utterances only, assistant voice responses stay ephemeral

Each finalized user transcript line writes a new chat message in the bound conversation. Assistant transcript lines stay in `VoiceTranscriptPanel` for live preview, then disappear when the panel re-renders (voice ends or session resets). This is the codex-#13 carve-out — defer the canonical-assistant question to Phase 2.

### 2. Voice mode binds to its starting chat (or auto-creates one)

When voice mode activates, `VoiceCommandController.boundConversationId` is set to the currently-focused conversation. **If no conversation is currently focused** (welcome state, first launch), the controller calls a new `ChatViewModel.ensureConversationForVoice() -> ConversationID` first, which creates an empty conversation if needed and returns its ID. Then voice binds.

Subsequent finalized transcript lines dispatch into the bound conversation regardless of whether Alex switches chats during the session. The bound conversation is the only target.

### 3. Bound conversation deleted mid-session → stop voice with error

If the user deletes the bound conversation from the sidebar while voice is active (FK cascade removes its messages, `NodeStore` returns nil for the ID), the controller detects this on the next commit attempt, calls `voiceController.failVoiceSession(message: "Conversation deleted")`, which transitions to `.error` and stops the session. No silent inserts into a missing conversation.

### 4. Mic icon next to timestamp for voice-originated user messages

Voice user messages share the typed-message bubble (same shape, color, typography). An 11pt SF Symbol `mic.fill` glyph in `AppColor.colaOrange.opacity(0.6)` sits 4pt right of the timestamp. No bubble color shift, no border, no separate styling.

### 5. Remove `propose_send_message` voice tool

`propose_send_message` is removed from the voice tool registry. Every site needs an update — the spec enumerates them in § Architecture so the implementer doesn't miss any.

`propose_create_note` and other action tools remain unchanged.

### 6. Persistence: schema migration via SQL ALTER, not Swift default

The codebase uses raw SQLite via `NodeStore`, not SwiftData. Adding a `source` field to `Message` requires:
- A new column in the `messages` schema: `source TEXT NOT NULL DEFAULT 'typed'`.
- A schema-migration helper invocation (`ensureColumnExists` or whatever pattern `NodeStore` already uses) at app start to add the column to existing databases.
- Updating every INSERT/SELECT that touches `messages` to include the new column.

Swift's `Message.source = .typed` default does **nothing** for existing rows; the SQL `DEFAULT 'typed'` clause is what backfills them.

## Architecture

### Data model

`Message` gains a `source` field:

```swift
enum MessageSource: String, Codable, Equatable {
    case typed
    case voice
}

struct Message {
    // ... existing fields ...
    var source: MessageSource = .typed
}
```

### Database schema migration

In `NodeStore.swift` (the file with `createTables` and `ensureColumnExists` patterns):

1. Update the `CREATE TABLE messages` statement to include `source TEXT NOT NULL DEFAULT 'typed'`.
2. Add a migration step in the schema-version path that runs `ALTER TABLE messages ADD COLUMN source TEXT NOT NULL DEFAULT 'typed'` if the column doesn't exist.
3. Update `INSERT INTO messages` (around `NodeStore.swift:798`) to bind the new column.
4. Update `SELECT FROM messages` (around `NodeStore.swift:821`) to read the new column and decode `MessageSource` from the string. If the value is missing or unparseable, default to `.typed`.

Tests must cover: (a) inserting a voice message and reading it back, (b) reading a row written by an old binary (i.e. `source` not present in the row) and decoding as `.typed`.

### `VoiceCommandController` extension

Add:

```swift
var boundConversationId: ConversationID?
```

Set it in `start(apiKey:)` (or wherever activation happens) **after** ensuring a conversation exists. Clear it in **every terminal path**:
- `stop()` (existing line ~85)
- `failVoiceSession(message:)` (existing line ~411)
- `deinit` (defensive)
- Any future reset / cancel surface

Use a single `private func clearBoundConversation()` method so additions to terminal paths can't forget. The committer subscribes to changes by being notified through the same path.

### Replace observer pattern: direct closure injection

Drop the `withObservationTracking` proposal from rev 1. The codex review correctly noted it's fragile — `transcript = []` on `stop()` would race with `observed` index, and panel deduplication would break offset assumptions.

Instead: **`VoiceCommandController` exposes a closure**:

```swift
var onUserUtteranceFinalized: ((VoiceTranscriptLine) -> Void)?
```

Set by `VoiceTranscriptCommitter` at wire time. Called inline at the bottom of `completeInputTranscript(_:)` (`VoiceCommandController.swift:455-465`) **after** the transcript line has been finalized via `VoiceTranscriptLine.finalize(...)`. The closure receives the just-finalized line.

`VoiceTranscriptCommitter`:

```swift
@MainActor
final class VoiceTranscriptCommitter {
    private weak var voiceController: VoiceCommandController?
    private weak var chatViewModel: ChatViewModel?
    private var committedLineIds: Set<UUID> = []

    init(voiceController: VoiceCommandController, chatViewModel: ChatViewModel) {
        self.voiceController = voiceController
        self.chatViewModel = chatViewModel
        voiceController.onUserUtteranceFinalized = { [weak self] line in
            self?.commit(line)
        }
    }

    private func commit(_ line: VoiceTranscriptLine) {
        guard line.role == .user else { return } // Phase 1: user only
        guard !committedLineIds.contains(line.id) else { return } // idempotent guard

        guard let conversationId = voiceController?.boundConversationId else { return }
        guard let viewModel = chatViewModel else { return }

        do {
            try viewModel.appendVoiceMessage(
                conversationId: conversationId,
                role: .user,
                text: line.text,
                timestamp: line.createdAt
            )
            committedLineIds.insert(line.id)
        } catch ChatPersistenceError.conversationMissing {
            // Bound conversation was deleted (codex finding #4)
            voiceController?.failVoiceSession(message: "Conversation deleted")
        } catch {
            // Other failures: log, leave line uncommitted (will retry on next finalize? no — drop)
            // Phase 1 scope: log only. Phase 2 may add a retry queue if needed.
        }
    }

    func reset() {
        committedLineIds.removeAll()
    }
}
```

Tracking by `VoiceTranscriptLine.id` (UUID), not by array index, sidesteps the "stop() resets transcript=[]" problem and lets `VoiceTranscriptPanel` filter committed lines safely.

The committer must be notified to `reset()` whenever the controller resets transcript state — wire `VoiceCommandController` to call `committer?.reset()` from `stop()`, `failVoiceSession()`, and `resetTranscript()`.

### `ChatViewModel.appendVoiceMessage(conversationId:role:text:timestamp:)`

New method. Persists into the conversation specified by ID, even if not the currently-loaded one. Implementation skeleton:

```swift
func appendVoiceMessage(
    conversationId: ConversationID,
    role: MessageRole,
    text: String,
    timestamp: Date
) throws {
    // Verify the conversation still exists. If gone, throw.
    guard let _ = nodeStore.fetchNode(byId: conversationId) else {
        throw ChatPersistenceError.conversationMissing
    }

    let message = Message(
        id: UUID(),
        nodeId: conversationId,
        role: role,
        text: text,
        timestamp: timestamp,
        source: .voice
    )

    try nodeStore.insertMessage(message)

    // If the bound conversation is the currently-loaded one, update the in-memory array
    // so the chat re-renders without a fetch. Otherwise the next time the user opens
    // that conversation, the SELECT path picks up the new row.
    if currentNode?.id == conversationId {
        messages.append(message)
    }
}

enum ChatPersistenceError: Error {
    case conversationMissing
}
```

The "current vs background" split is the whole point of why this method exists separately from the typed flow's `send(...)` — `send` snapshots `currentNode` and `messages` for its own assistant-streaming pipeline; voice persistence cannot reuse that path.

### `VoiceTranscriptPanel` filter committed lines

The panel currently renders every line in `voiceController.transcript` (`VoiceTranscriptPanel.swift:14`). Update the body to:

```swift
let visibleLines = voiceController.transcript.filter { line in
    !line.isFinal || !committedLineIds.contains(line.id)
}
```

The panel needs read-access to `committedLineIds`. Two options:
- Expose `committer.committedLineIds` as `@Published` (or via `@Observable`).
- Move the committed-set onto the controller itself as `committedLineIds: Set<UUID>` and have the committer write to it.

Pick the second — keeps the panel's dependencies simple (just the controller).

### `VoiceActionHandlers` change

Remove the `sendMessage: (String) -> Void` closure from `VoiceActionHandlers`. Update `VoiceActionHandlers.empty` and every site that builds a real handler. Compiler will surface every site.

### `VoicePendingAction.sendMessage` removal blast radius

The codex review flagged that `propose_send_message` removal is bigger than the rev-1 spec implied. Concretely, every one of these needs an update:

| Site | Change |
|---|---|
| `Sources/Nous/Models/Voice/VoiceModeModels.swift:153` | Remove `case sendMessage(text: String)` from `VoicePendingAction` |
| `Sources/Nous/Models/Voice/VoiceModeModels.swift:174,201,216` | Remove `sendMessage` from `VoiceActionHandlers` (closure, init, empty) |
| `Sources/Nous/Services/VoiceActionRegistry.swift` | Remove `propose_send_message` declaration |
| `Sources/Nous/Services/VoiceCommandController.swift:265,308,432` | Remove `case .sendMessage` paths in tool dispatch + pending-action execution |
| `Sources/Nous/Services/RealtimeVoiceSession.swift:335` | Update instruction prose: drop "Use propose_send_message" reference |
| `Sources/Nous/App/AppEnvironment.swift` (or wherever real handlers are built) | Drop `sendMessage:` from the `VoiceActionHandlers(...)` constructor call |
| `Tests/NousTests/VoiceActionRegistryTests.swift:42` | Remove or invert the assertion |
| `Tests/NousTests/VoiceCommandControllerTests.swift:339,704` | Remove tests that exercise `sendMessage` confirmation; update tests that exercise pending-action restore (still valid for `createNote`) |
| `docs/superpowers/specs/2026-04-28-voice-mode-design.md:82` (and similar references in app-wide-voice-control-design) | Add a "deprecated" / "removed in rev 2" note pointing to this spec |

The implementer should grep for `sendMessage` and `propose_send_message` across `Sources/Nous` and `Tests/NousTests` to catch anything missed above.

### `MessageBubble` view extension

Render the mic glyph next to the timestamp when `message.source == .voice`. Phase 1 only ever produces voice user messages, so the mic icon only appears on user bubbles in this phase:

```swift
HStack(spacing: 4) {
    Text(message.timestamp, style: .time)
        .font(.system(size: 10, weight: .regular, design: .rounded))
        .foregroundStyle(AppColor.tertiaryText)
    if message.source == .voice {
        Image(systemName: "mic.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AppColor.colaOrange.opacity(0.6))
            .accessibilityLabel("Voice")
    }
}
```

## Phase 1 Implementation Order

To keep each commit safely independent:

1. **Schema migration** — add `source` column via `ALTER TABLE`, update INSERT/SELECT, add tests for backfill of legacy rows. This commit alone passes tests with no behavior change.
2. **`MessageSource` enum + Message struct field** — Swift-side compile gate.
3. **`MessageBubble` mic icon rendering** — visual change for any future voice message; nothing produces them yet so no visible change.
4. **Remove `propose_send_message` (full blast radius)** — single big commit covering every site listed above. Compiler enforces completeness via removed enum case.
5. **`boundConversationId` on `VoiceCommandController` + `clearBoundConversation()` helper + every terminal-path call** — no committer yet, just plumbing.
6. **`onUserUtteranceFinalized` closure on controller** — set in `completeInputTranscript`; no consumer yet.
7. **`ChatViewModel.appendVoiceMessage` + `ChatPersistenceError`** — exercised by unit test, no production caller yet.
8. **`VoiceTranscriptCommitter`** — wire it up in `ContentView.onAppear` next to the existing voice controllers; voice user utterances now persist.
9. **`VoiceTranscriptPanel` filter committed lines** — finalized lines disappear from preview once chat receives them.
10. **Manual QA pass** — see § Manual QA Test Plan.

Steps 1-7 land safe behind feature work; steps 8-9 turn the feature on.

## Manual QA Test Plan

Before merging:

### Capture
- [ ] Start voice in chat A. Speak 3 utterances. Confirm 3 user messages appear in chat A with mic icons. Assistant voice responses do **not** appear in chat (Phase 1 deferred). Live transcript panel shows assistant lines as preview.
- [ ] After each user utterance finalizes, the line disappears from the transcript panel and shows up in chat as a user message with mic icon.

### Bound conversation
- [ ] Start voice in chat A. Switch to chat B mid-session. Speak. New utterances land in chat A, not chat B.
- [ ] Sidebar shows a voice indicator on chat A while voice is active. (If this requires additional UI work, defer and note.)
- [ ] Stop voice. Switch back to chat A. All utterances persisted in correct order.

### Empty-chat boot
- [ ] From welcome state (no conversation focused), start voice. A new conversation is created and bound. Utterances land there. After voice ends, the new conversation is in the sidebar with the voice messages.

### Bound-conversation deletion
- [ ] Start voice in chat A. Speak 1 utterance (lands in chat A). Delete chat A from sidebar. Voice mode transitions to `.error` with message "Conversation deleted". No crash, no corrupt rows.

### Tool removal
- [ ] Voice agent never proposes `sendMessage` — the tool is gone from its registry.
- [ ] `createNote` still works (proposes confirm, dispatches on confirm).
- [ ] Navigation tools still work.

### Schema migration
- [ ] Open the app on a database created by an old binary (no `source` column). The app starts, runs the ALTER TABLE migration, and existing chat history reads as `source: .typed` (no mic icons on old messages).

### Visual
- [ ] Mic icon: 11pt SF Symbol `mic.fill`, colaOrange @ 0.6 opacity, sits 4pt right of timestamp.
- [ ] Bubble shape, color, typography unchanged from typed.
- [ ] Mic icon appears on voice user messages only (Phase 1).

### Mixed media
- [ ] Type a message between voice utterances. Both interleave correctly by timestamp. Mic icon only on the voice ones.

### Terminal-path coverage (boundConversationId reset)
- [ ] Stop voice → boundConversationId cleared.
- [ ] Voice fails (network error, bad API key) → boundConversationId cleared.
- [ ] App relaunch → boundConversationId is nil (controller is freshly constructed; no persisted state).

## Codex Review Disposition

This rev addresses the 13 codex findings as follows:

| # | Finding | Disposition |
|---|---|---|
| 1 | Voice in empty chat is undefined | **Fixed** — § 2 now requires `ChatViewModel.ensureConversationForVoice()` before binding |
| 2 | Migration section was wrong (raw SQLite, not SwiftData) | **Fixed** — § 6 + Architecture both rewritten with SQL `ALTER TABLE` migration, INSERT/SELECT updates, backfill via column DEFAULT |
| 3 | `appendVoiceMessage` was underspecified for cross-conversation | **Fixed** — Architecture now spells out fetch / insert / conditional in-memory update, with `ChatPersistenceError.conversationMissing` for missing nodes |
| 4 | Bound conversation deletion not handled | **Fixed** — § 3 + committer code: throw → fail voice session with "Conversation deleted" |
| 5 | `observed: Int` index brittle on `transcript = []` reset | **Fixed** — switched to `committedLineIds: Set<UUID>` keyed by `VoiceTranscriptLine.id`; reset via explicit `committer.reset()` calls from controller terminal paths |
| 6 | Panel dedupe conflicts with index tracking | **Fixed** — panel filters by `committedLineIds`, no array mutation |
| 7 | `withObservationTracking` is unnecessary | **Fixed** — replaced with direct closure injection at `completeInputTranscript` finalization point |
| 8 | Removing `propose_send_message` breaks instructions/tests | **Fixed** — § 5 + Architecture enumerate every site (instructions in `RealtimeVoiceSession.swift:335`, tests, parent specs, AppEnvironment handler builder) |
| 9 | `VoicePendingAction.sendMessage` enum removal affects confirmation logic | **Fixed** — included in the blast-radius table; tests at `:339, :704` explicitly listed |
| 10 | Edit/delete claims false against current UI | **Fixed** — § Non-Goals now states voice user messages inherit whatever typed has (currently nothing for user-side); spec invents no new edit/delete UI |
| 11 | Assistant audio ghost | **Fixed by scope reduction** — § Phase Scope defers all assistant voice persistence; audio still plays but no chat message is created either way, so no ghost |
| 12 | `boundConversationId` reset incomplete across terminal paths | **Fixed** — § Architecture requires `clearBoundConversation()` helper called from `stop()`, `failVoiceSession()`, `deinit`, plus future surfaces |
| 13 | Voice assistant ≠ canonical Nous response | **Fixed by scope reduction** — Phase 1 persists user utterances only; the canonical-assistant question is deferred to Phase 2 with explicit acknowledgement that the voice instruction layer ≠ chat instruction layer |

## Open Implementation Questions

These are deliberately left to the implementer:

1. **Where to call `ensureConversationForVoice()`?** Likely in `ContentView.toggleVoiceMode` before the controller's `start(apiKey:)` runs, since `ContentView` already has `chatVM` in scope. Alternatively wire it through `AppEnvironment`. Either works; pick what matches existing patterns.
2. **Sidebar voice indicator** for bound chat. The QA plan asks for it but the spec doesn't enforce it in scope. If it requires significant UI work, defer to Phase 1.5 or Phase 2 — it's a nice-to-have, not a correctness requirement.
3. **`failVoiceSession` already resets transcript** (`VoiceCommandController.swift:411`). Make sure the `committer.reset()` path is also triggered by it, not just by `stop()`.
4. **Test database schema migration**: the tests probably need an in-memory SQLite test fixture that simulates a pre-migration row. Check how existing schema-migration tests are structured (if any).
5. **Persistence write happens on `@MainActor` in this design.** SQLite writes are synchronous in the existing codebase (verify in `NodeStore`). If they're slow, voice committing could block the main thread. Consider an `await Task.detached { ... }` wrap if profiling shows it; not required by spec.
