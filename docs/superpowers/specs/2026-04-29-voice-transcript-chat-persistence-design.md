# Voice Transcript Chat Persistence Design

**Date:** 2026-04-29 (rev. 3 — incorporates two rounds of codex review)
**Status:** User-approved direction. Phase 1 persists user voice utterances through the full chat persistence path (`messages` table + `nodes.content` transcript blob) so downstream systems see them.
**Branch context:** `alexko0421/quick-action-agents`
**Related:**
- `2026-04-28-voice-mode-design.md` (voice state machine)
- `2026-04-28-app-wide-voice-control-design.md` (voice action registry)
- `2026-04-29-voice-notch-capsule-design.md` (notch surface for voice state)

## Context

Voice mode is ephemeral today. Live transcript flows through `VoiceCommandController.transcript: [VoiceTranscriptLine]` and surfaces in `VoiceTranscriptPanel`, but when voice mode ends the transcript disappears. Nothing persists.

This spec persists what Alex says — the source-of-truth he most needs — into the chat history of the conversation where voice started, and through the same persistence path the typed flow uses, so downstream systems (memory projection, vector search, Galaxy, Finder export, conversation title backfill) all see voice content.

Assistant voice responses are deliberately deferred to a future phase because the voice agent's instructions are a tiny "voice control layer" prompt, not Nous's anchor / RAG-aware chat instructions. Persisting voice assistant lines as canonical assistant chat history would let future text turns inherit context that wasn't really Nous answering.

## Phase Scope

**In Phase 1: persist user voice utterances only**, through the same `ConversationSessionStore.persistTranscript` path the typed flow uses. Each finalized user transcript line writes to `messages` AND updates `nodes.content`. Assistant voice responses do not persist; they continue to flow through `VoiceTranscriptPanel` as live preview and disappear when voice ends.

**Phase 2 (deferred):** Persist assistant voice responses, with whatever metadata or instruction-layer alignment turns out to be the right answer. This requires aligning voice instructions with anchor/RAG so the two layers produce comparable assistant prose.

## Product Goal

After a Phase 1 voice session ends, the chat history of the conversation where voice started contains every finalized user utterance as a chat message, marked by an 11pt mic icon next to the timestamp. Voice content shows up everywhere typed user content shows up: in chat, in vector search, in Galaxy, in memory evidence, in Finder export, in conversation titles. Assistant voice responses remain ephemeral; they live in the transcript panel and are not written to chat.

The `propose_send_message` voice tool is removed because voice agent's "compose-and-send" indirection is dead weight once user utterances auto-record. `propose_create_note` and the action / navigation tools stay.

## Non-Goals

- No assistant voice response persistence — Phase 2.
- No voice playback / re-listen — Phase 2.
- No voice search or filter — Phase 2.
- No transcript-quality indicator on bubbles — Phase 2.
- No new edit/delete UI affordances. Voice user messages inherit whatever the typed flow already has. (User typed messages currently have no edit/delete UI; voice user messages will be the same.)
- No regeneration semantics for voice — they're user messages; user messages don't regenerate.
- No retroactive backfill of past voice sessions.
- No cross-chat / multi-user voice.

## Core Decisions

### 1. User utterances only, persisted through the canonical typed-flow path

Each finalized user transcript line writes through `ConversationSessionStore` so both `messages` AND `nodes.content` update. This is what the codex round-2 review caught: writing only to `messages` would leave voice content invisible to memory, vector search, Galaxy, Finder export, and title backfill — half a feature.

### 2. Voice mode binds to its starting chat (or auto-creates one)

`VoiceCommandController.boundConversationId: UUID?` is set on activation to the currently-focused conversation's ID. **If no conversation is focused** (welcome state), `ContentView.toggleVoiceMode` calls `chatVM.ensureConversationForVoice() -> UUID` first, which creates an empty conversation via `ConversationSessionStore.startConversation` and returns its ID. Then voice binds.

Subsequent finalized lines dispatch into the bound conversation regardless of chat switching.

### 3. Bound conversation deleted mid-session → fail voice with error

If the user deletes the bound conversation while voice is active, the next commit attempt sees `nodeStore.fetchNode(id:)` return nil. The committer catches this and calls `voiceController.failVoiceSession(message: "Conversation deleted")`. State transitions to `.error`, voice stops, no silent inserts into a missing conversation.

### 4. Mic icon next to timestamp for voice user messages

Voice user messages share the typed bubble (same shape, color, typography). An 11pt SF Symbol `mic.fill` glyph in `AppColor.colaOrange.opacity(0.6)` sits 4pt right of the timestamp. No bubble color shift, no border, no separate styling.

Note: `MessageBubble` currently does not receive a `Message` or timestamp — only `text/thinking/isUser`. The mic-icon work requires adding `source: MessageSource` and `timestamp: Date` params to `MessageBubble` and updating both call sites in `ChatArea.swift:104, 178`. The spec includes this in the implementation order.

### 5. Remove `propose_send_message` voice tool

Removed across the full blast radius listed in § Architecture. `propose_create_note` and other action tools stay.

### 6. Persistence: SQL migration via ALTER TABLE

The codebase uses raw SQLite. Adding `source` requires:
- Update `CREATE TABLE messages` in `NodeStore.createTables` to include `source TEXT NOT NULL DEFAULT 'typed'`.
- Add `ensureColumnExists(table: "messages", column: "source", alterSQL: "ALTER TABLE messages ADD COLUMN source TEXT NOT NULL DEFAULT 'typed'")` invocation at app start.
- Update `INSERT INTO messages` (`NodeStore.swift:798`) to bind the new column.
- Update the SELECT/decode (`NodeStore.swift:821`) to read the column and decode `MessageSource`. Unknown / missing values default to `.typed`.

Swift's `Message.source = .typed` default does nothing for existing rows; the SQL `DEFAULT` clause is the backfill mechanism.

## Architecture

### Data model: `MessageSource` + `Message.source`

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

Update `Message`'s init to accept `source` (default `.typed`).

### `MessageBubble` API change

`MessageBubble` (`ChatArea.swift:658`) currently takes `text/thinkingContent/agentTraceRecords/isThinkingStreaming/isAgentTraceStreaming/isUser`. Add two more params:

```swift
struct MessageBubble: View {
    // existing params ...
    let source: MessageSource           // NEW
    let timestamp: Date                  // NEW
    // ...
}
```

Update both call sites at `ChatArea.swift:104` and `ChatArea.swift:178` to pass `message.source` and `message.timestamp` (or the appropriate equivalents from the local context).

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

Phase 1 only ever produces voice user messages, so the mic icon only appears on user bubbles in this phase.

### `ConversationSessionStore.appendVoiceUserMessage(nodeId:text:)`

The single most important architectural change. Voice persistence reuses the typed flow's transcript-persistence machinery so `nodes.content` stays in sync.

New method on `ConversationSessionStore`:

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
        source: .voice
    )
    try nodeStore.insertMessage(userMessage)

    // Re-read messages so the in-memory snapshot reflects what's now in the DB,
    // then run the same transcript-persistence path the typed flow uses.
    let messagesAfterAppend = try nodeStore.fetchMessages(nodeId: node.id)
    let updatedNode = try persistTranscript(node: node, messages: messagesAfterAppend)

    return CommittedVoiceTurn(
        node: updatedNode,
        userMessage: userMessage,
        messagesAfterAppend: messagesAfterAppend
    )
}
```

The `Message` init currently takes `content` (not `text`); follow the existing param name. The `timestamp` parameter is plumbed through the `Message` initializer if it accepts one, or via a separate path if `Message` always uses `Date()`.

### `ChatViewModel.ensureConversationForVoice()` and `appendVoiceMessage`

```swift
@MainActor
extension ChatViewModel {
    /// Returns the ID of the conversation voice should bind to. If a current
    /// node exists, returns its ID. Otherwise creates an empty conversation
    /// and returns its ID.
    func ensureConversationForVoice() throws -> UUID {
        if let current = currentNode {
            return current.id
        }
        let node = try sessionStore.startConversation(
            title: "New Conversation",
            projectId: defaultProjectId
        )
        // Switch the current view to the new node.
        await MainActor.run {
            self.currentNode = node
            self.messages = []
        }
        return node.id
    }

    /// Appends a voice user message to the conversation identified by
    /// `nodeId`, even if it is not the currently-loaded conversation.
    /// Updates the in-memory `messages` array only if the bound node is
    /// also the currently-loaded one.
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
        // Trigger any post-user-append pipelines (memory, etc.) that the typed
        // flow normally fires. If the typed flow only fires those after the
        // assistant turn, voice will fire them on user-only too. Verify
        // during implementation.
    }
}
```

`ConversationSessionStoreError.missingNode` propagates up; the committer catches it and fails the voice session.

### `VoiceCommandController` extension

#### Add `boundConversationId` and clear helper

```swift
@Observable
@MainActor
final class VoiceCommandController {
    // ... existing fields ...
    var boundConversationId: UUID?

    private func clearBoundConversation() {
        boundConversationId = nil
        committer?.reset()
    }
}
```

Call `clearBoundConversation()` from every terminal path:
- `stop()` (`VoiceCommandController.swift:84`)
- `failVoiceSession(message:)` (`VoiceCommandController.swift:411`) — note: change access from `private` to `internal` (or `func failVoiceSession`) so the committer can call it
- `resetTranscript()` (`VoiceCommandController.swift:484`) — covers the case where transcript is reset without a full session stop

#### Add `onUserUtteranceFinalized` closure

```swift
var onUserUtteranceFinalized: ((VoiceTranscriptLine) -> Void)?
```

Wired by `VoiceTranscriptCommitter` at construction time.

#### Modify `VoiceTranscriptLine.finalize` to return the finalized line

Currently `VoiceTranscriptLine.finalize(text:role:into:)` returns `Void`. Change it to return the finalized `VoiceTranscriptLine` value so callers can pass it to the closure without re-reading the array:

```swift
@discardableResult
static func finalize(
    text: String,
    role: Role,
    into lines: inout [VoiceTranscriptLine],
    now: Date = Date()
) -> VoiceTranscriptLine {
    // ... existing implementation ...
    let line = VoiceTranscriptLine(role: role, text: text, isFinal: true, createdAt: now)
    lines.append(line)
    return line
}
```

`@discardableResult` keeps existing call sites that ignore the return value (currently `appendOutputTranscript`, `appendInputTranscript`) working with no change.

In `completeInputTranscript(_:)` (`VoiceCommandController.swift:455`), change:

```swift
private func completeInputTranscript(_ text: String) {
    // ... existing setup ...
    let line = VoiceTranscriptLine.finalize(text: text, role: .user, into: &transcript)
    onUserUtteranceFinalized?(line)
}
```

`completeOutputTranscript` does **not** call the closure (Phase 1 user-only).

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
        // Set the closure. The closure captures self weakly to avoid retain cycles
        // since the committer is strongly held by AppDependencies (see § Wiring).
        voiceController.onUserUtteranceFinalized = { [weak self] line in
            self?.commit(line)
        }
    }

    deinit {
        voiceController?.onUserUtteranceFinalized = nil
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
            // Log only. Phase 1 does not retry.
        }
    }

    func reset() {
        committedLineIds.removeAll()
    }
}
```

The committer is strongly retained by `AppDependencies` (see § Wiring). The closure's `[weak self]` plus `weak voiceController` prevents the obvious retain cycles.

### Wiring (where to retain the committer)

The committer must outlive any single view. Add to `AppDependencies` (or whichever container is the top-level service holder):

```swift
final class AppDependencies {
    // ... existing fields ...
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

A short-lived `@State` in `ContentView.onAppear` would deinit between view updates and silently break the closure. Don't do that.

### `VoiceTranscriptPanel` — filter committed lines

`VoiceTranscriptPanel` (`Sources/Nous/Views/Voice/VoiceTranscriptPanel.swift:14`) currently takes `lines: [VoiceTranscriptLine]`. Two options:

**Option A — pass committedLineIds explicitly:**

```swift
struct VoiceTranscriptPanel: View {
    let lines: [VoiceTranscriptLine]
    let committedLineIds: Set<UUID>

    private var visibleLines: [VoiceTranscriptLine] {
        lines.filter { line in
            !line.isFinal || !committedLineIds.contains(line.id)
        }
    }
    // ... body uses visibleLines ...
}
```

Update the call site in `ChatArea.swift:269` to pass `voiceController.committedLineIds` (mirror the set onto the controller — see below) or `committer.committedLineIds`.

**Option B — pass the controller:**

`VoiceTranscriptPanel(voiceController: voiceController)` and let the panel read both `transcript` and `committedLineIds` from there.

Pick **A** to keep the panel's dependency surface small. Mirror `committedLineIds` onto the controller as `var committedUserUtteranceIds: Set<UUID>` so the panel and committer can both see the same source. The committer writes to `voiceController.committedUserUtteranceIds` instead of (or in addition to) its own field.

Actually, simpler: just expose `committer.committedLineIds` via observation since `VoiceTranscriptCommitter` is `@MainActor` and Swift Observation can be added with `@Observable` macro on the class. Avoid mirroring state.

### `VoiceActionHandlers` change

Remove `sendMessage: (String) -> Void` from `VoiceActionHandlers`. Compiler surfaces every site.

### `propose_send_message` removal blast radius

Concrete sites the implementer must update:

| Site | Change |
|---|---|
| `Sources/Nous/Models/Voice/VoiceModeModels.swift:153` | Remove `case sendMessage(text: String)` from `VoicePendingAction` |
| `Sources/Nous/Models/Voice/VoiceModeModels.swift:174,201,216` | Remove `sendMessage` from `VoiceActionHandlers` (closure, init, empty) |
| `Sources/Nous/Services/VoiceActionRegistry.swift` | Remove `propose_send_message` declaration |
| `Sources/Nous/Services/VoiceCommandController.swift:265,308,432` | Remove `case .sendMessage` paths in tool dispatch + pending-action execution |
| `Sources/Nous/Services/RealtimeVoiceSession.swift:332-340` | Update voice instructions: drop "Use propose_send_message" reference |
| `Sources/Nous/App/AppEnvironment.swift` (or wherever real handlers are built) | Drop `sendMessage:` from `VoiceActionHandlers(...)` constructor call |
| `Tests/NousTests/VoiceActionRegistryTests.swift:42` | Remove or invert assertion |
| `Tests/NousTests/VoiceCommandControllerTests.swift:339,704` | Remove tests that exercise sendMessage; keep / update tests for createNote pending-action restore |
| `Tests/NousTests/VoiceCommandControllerIdempotencyTests.swift` | Remove or replace `.sendMessage` test cases (they were our own additions during the notch capsule work) |
| `docs/superpowers/specs/2026-04-28-voice-mode-design.md:82` | Add a "deprecated in rev 2 of voice-transcript-chat-persistence-design" note |
| `docs/superpowers/specs/2026-04-28-app-wide-voice-control-design.md:176` | Same deprecation note |

The implementer should grep `Sources/Nous` and `Tests/NousTests` for `sendMessage` and `propose_send_message` to catch anything missed.

## Phase 1 Implementation Order (revised)

The order is rebuilt from rev 2 to fix codex's ordering complaint (rev 2 step 1 updated INSERT/SELECT before `Message.source` existed):

1. **Add `MessageSource` enum** to `Sources/Nous/Models/Voice/MessageSource.swift` (or alongside `Message`). No callers yet, no DB change.
2. **Add `source: MessageSource = .typed` field to `Message`**. Update `Message.init` if it has a designated initializer. Compile passes; no SQL involvement yet.
3. **SQL migration**: update `NodeStore.createTables` schema; add `ensureColumnExists` call for the new column; update `insertMessage` to bind the source string; update the SELECT decode path. Add tests for round-trip and legacy-row decode.
4. **`MessageBubble` API change**: add `source: MessageSource` and `timestamp: Date` params; update `ChatArea.swift:104, 178` call sites to pass these.
5. **Mic icon rendering** when `source == .voice` (only voice user bubbles get the icon in Phase 1; nothing produces them yet).
6. **Remove `propose_send_message` (full blast radius commit)**. Compiler enforces completeness via removed enum case. All affected tests updated.
7. **Modify `VoiceTranscriptLine.finalize` to return the finalized line** (`@discardableResult` so existing call sites still work).
8. **`VoiceCommandController` plumbing**: add `boundConversationId`, `onUserUtteranceFinalized`, `clearBoundConversation()`; wire `clearBoundConversation()` into `stop()`, `failVoiceSession()`, `resetTranscript()`. Change `failVoiceSession` access to `internal`. Wire the closure call into `completeInputTranscript`.
9. **`ConversationSessionStore.appendVoiceUserMessage(nodeId:text:timestamp:)`** + `CommittedVoiceTurn`. Unit test with an in-memory test fixture.
10. **`ChatViewModel.ensureConversationForVoice()`** and **`appendVoiceMessage(nodeId:text:timestamp:)`**. Unit-test the conditional in-memory update branch and the cross-conversation case.
11. **`VoiceTranscriptCommitter`** + retention in `AppDependencies`. Wire it up.
12. **`ContentView.toggleVoiceMode`** calls `chatVM.ensureConversationForVoice()` before `voiceController.start(...)`, then sets `boundConversationId` on the controller.
13. **`VoiceTranscriptPanel`** filter committed lines via `committedLineIds`.
14. **Manual QA pass** (see § Manual QA Test Plan).

Steps 1-7 are pure plumbing and prep — nothing visible in production. Step 8-12 light up the feature. Step 13 polishes the panel preview.

## Manual QA Test Plan

### Capture & full-pipeline visibility
- [ ] Start voice in chat A. Speak 3 utterances. Confirm 3 user messages appear in chat A with mic icons. Assistant voice does NOT appear in chat (Phase 1 deferred).
- [ ] After voice ends, open Galaxy / vector search and search for a phrase from a voice utterance. It must surface (proves `nodes.content` was updated).
- [ ] Memory projection runs include voice utterances as evidence (after voice session ends and the next memory pipeline tick).
- [ ] Conversation title backfill picks up voice content if title hasn't been set.
- [ ] Finder export of the conversation includes voice content.

### Bound conversation
- [ ] Start voice in chat A. Switch to chat B. Speak. Lines land in chat A.
- [ ] Stop voice. Switch back to chat A. All utterances persisted.

### Empty-chat boot
- [ ] From welcome state (no current node), start voice. A new conversation is created and bound. Utterances land there. After voice ends, the conversation appears in the sidebar with mic icons on user messages.

### Bound-conversation deletion
- [ ] Start voice in chat A. Speak 1 utterance (lands in chat A). Delete chat A from sidebar. Voice transitions to `.error` with message "Conversation deleted". No crash, no orphan rows.

### Tool removal
- [ ] Voice agent never proposes `sendMessage` — the tool is gone.
- [ ] `createNote` still works.

### Schema migration
- [ ] Open the app with a database created by an old binary (no `source` column). The app starts, runs the ALTER, existing chat history reads as `.typed` (no mic icons on legacy messages).

### Visual
- [ ] Mic icon: 11pt SF Symbol `mic.fill`, colaOrange @ 0.6, sits 4pt right of timestamp.
- [ ] Bubble shape, color, typography unchanged from typed.

### Mixed media
- [ ] Type a message between voice utterances. Both interleave by timestamp. Mic icon only on voice ones.

### Terminal-path coverage
- [ ] Stop voice → boundConversationId cleared, committer reset.
- [ ] Voice fails (network error, bad API key) → boundConversationId cleared, committer reset.
- [ ] Reset transcript (e.g., new utterance after a previous one finalized) — committer is NOT reset just for a new utterance, only when the entire transcript array is cleared.

### Retention
- [ ] Trigger a memory-pressure scenario (or just wait through several view re-renders). Voice still records — committer survives.

## Codex Review Disposition

Round 1 found 13 issues (rev 1 → rev 2). Round 2 found 4 NEW issues + 6 partials (rev 2 → rev 3). This rev 3 disposes:

| # | Round | Finding | Disposition |
|---|---|---|---|
| 1 | R1 | Voice in empty chat undefined | RESOLVED — `ensureConversationForVoice()` before binding |
| 2 | R1 | Migration was wrong (no SwiftData) | RESOLVED — SQL `ALTER TABLE` + `DEFAULT 'typed'` |
| 3 | R1 | `appendVoiceMessage` cross-conversation underspecified | RESOLVED in rev 3 — implemented via `ConversationSessionStore.appendVoiceUserMessage` reusing the typed-flow persistTranscript path |
| 4 | R1 | Bound conversation deletion not handled | RESOLVED — `failVoiceSession("Conversation deleted")` on `missingNode` |
| 5 | R1 | Index brittle | RESOLVED — UUID-keyed `committedLineIds: Set<UUID>` |
| 6 | R1 | Panel dedupe conflicts with index | RESOLVED — panel filters by ID set, no array mutation |
| 7 | R1 | `withObservationTracking` unnecessary | RESOLVED — direct closure; `finalize` returns the line so the closure receives it |
| 8 | R1 | Removing `propose_send_message` blast radius | RESOLVED — 11-row table including `VoiceCommandControllerIdempotencyTests` (rev 3 addition) |
| 9 | R1 | Pending action enum removal affects confirmation logic | RESOLVED — same blast-radius table covers tool dispatch + pending-action restore |
| 10 | R1 | Edit/delete claim false | RESOLVED — § Non-Goals explicit, no UI invented |
| 11 | R1 | Audio ghost real | RESOLVED via Phase 1 scope (assistant voice not persisted) |
| 12 | R1 | Reset across terminal paths | RESOLVED — `clearBoundConversation()` from `stop()`, `failVoiceSession()`, `resetTranscript()` |
| 13 | R1 | Voice assistant ≠ canonical Nous | RESOLVED via Phase 1 scope reduction |
| N1 | R2 | `nodes.content` not updated; voice invisible to memory/Galaxy/export | **RESOLVED — `appendVoiceUserMessage` runs `persistTranscript` to update `nodes.content`** |
| N2 | R2 | `MessageBubble` doesn't take `Message`/`timestamp` | RESOLVED — § Architecture adds the params and the call-site updates |
| N3 | R2 | `VoiceTranscriptCommitter` retention | RESOLVED — owned by `AppDependencies` |
| N4 | R2 | `ConversationID` type doesn't exist | RESOLVED — uses `UUID` everywhere |
| N5 | R2 (partial) | Step ordering wrong | RESOLVED — implementation order rebuilt with dependencies satisfied |
| N6 | R2 (partial) | `fetchNode(byId:)` / `Message(text:)` API names wrong | RESOLVED — uses `nodeStore.fetchNode(id:)` and `Message(nodeId:role:content:source:)` |
| N7 | R2 (partial) | `failVoiceSession` is private | RESOLVED — § Architecture requires changing access to internal |
| N8 | R2 (partial) | `VoiceTranscriptLine.finalize` returns Void | RESOLVED — modify it to return the line with `@discardableResult` |
| N9 | R2 (partial) | `VoiceTranscriptPanel` wiring unclear | RESOLVED — § Architecture specifies the call-site change |

## Open Implementation Questions

1. **Memory / title pipeline trigger timing**: typed flow likely fires user-memory and title backfill after the assistant turn commits, not after the user-message insert. Voice has no assistant turn in Phase 1. Verify whether memory / title pipelines also run on user-only inserts; if not, voice user content will be in `nodes.content` but won't trigger memory projection / title generation until the next assistant turn (which may happen later or never). May need a manual fire on voice append. Flag for implementation; not a blocker.
2. **`Message.timestamp`**: verify whether the `Message` initializer accepts an explicit timestamp or always uses `Date()`. The voice path needs the line's `createdAt` to be the message timestamp. If `Message` always uses `Date()` at insert time, the difference is small (microseconds) and acceptable for Phase 1.
3. **`VoiceTranscriptLine.id` on append vs finalize**: confirm that finalize preserves the id of the in-progress line if one exists, or uses a new id. Consistent ids are needed for the committed-set dedup. Verify in implementation.
4. **`@Observable` on `VoiceTranscriptCommitter`**: if we want `VoiceTranscriptPanel` to reactively update when `committedLineIds` changes, the committer needs to be `@Observable`. Add the macro and verify the panel re-renders.
