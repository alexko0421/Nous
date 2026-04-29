# Voice Transcript Chat Persistence Design

**Date:** 2026-04-29
**Status:** User-approved direction, ready for implementation planning
**Branch context:** `alexko0421/quick-action-agents`
**Related:**
- `2026-04-28-voice-mode-design.md` (voice state machine)
- `2026-04-28-app-wide-voice-control-design.md` (voice action registry)
- `2026-04-29-voice-notch-capsule-design.md` (notch surface for voice state)

## Context

Today, voice mode is ephemeral. Live transcript flows through `VoiceCommandController.transcript: [VoiceTranscriptLine]` and surfaces in `VoiceTranscriptPanel`, but when voice mode ends the transcript disappears. Nothing persists to the chat conversation. The only way voice content reaches chat history is the indirect `propose_send_message` tool: voice agent decides "this should be sent as a chat message", emits a `pendingAction.sendMessage(text:)`, the user confirms, and the text lands as a chat message via `handlers.sendMessage`.

The result is that long voice conversations leave no record. Alex can talk to Nous for ten minutes about a hard decision and walk away with nothing in the chat thread to revisit.

This spec makes voice mode behave like a spoken chat: every finalized utterance — user or assistant — auto-appends to the chat history of the conversation where voice mode started.

## Product Goal

When Alex starts voice mode in a chat, every utterance (user voice → text, assistant voice → text) becomes a message in that chat as soon as the utterance finalizes. After voice mode ends, the chat history contains the full conversation as a normal scrollable thread, with each voice-originated message marked by a small mic icon next to its timestamp. Editing, deletion, and regeneration of voice messages work the same way as typed messages.

The `propose_send_message` voice tool is removed — it was a workaround for voice not being chat. Other voice tools (`propose_create_note`, navigation, settings) stay.

## Non-Goals

- No voice playback for messages already in chat (re-listen feature) — Phase 2.
- No voice search or "show only voice messages" filter — Phase 2.
- No transcript-quality indicator on bubbles (e.g., low-confidence markers) — Phase 2.
- No cross-chat or multi-user voice — single-user, single-chat session at a time.
- No retroactive backfill of past voice sessions that were lost. Only new sessions persist.
- No regeneration that triggers another voice playback. Regenerated assistant responses are text-only with `source: .typed`.

## Core Decisions

### 1. Real-time mirror with final commit per utterance

Voice mode auto-records to chat. Each utterance lands as a separate chat message after the Realtime API marks it final. Live preview during transcription stays in `VoiceTranscriptPanel`; the chat history sees only finalized lines. This matches the ChatGPT-style voice UX Alex referenced and avoids streaming partial text into chat (which would make chat history feel jittery).

### 2. Bind voice session to its starting chat

When voice mode activates in chat X, the controller records `boundConversationId = X.id`. Every subsequent finalized transcript line dispatches into that chat regardless of whether Alex switches chats during the session. This is a deliberate guard against accidentally polluting the wrong chat by clicking another conversation in the sidebar mid-session. To record into a different chat, Alex stops voice and starts a new voice session there.

### 3. Mic icon next to timestamp for voice-originated messages

Voice messages share the typed-message bubble (same shape, same color, same typography). An 11pt SF Symbol `mic.fill` glyph in `AppColor.colaOrange.opacity(0.6)` sits 4pt right of the timestamp. No bubble color shift, no border change, no separate styling — Nous's visual language stays calm.

### 4. Remove `propose_send_message` voice tool

Voice tool definition `propose_send_message` is removed from `VoiceActionRegistry`. The corresponding `VoicePendingAction.sendMessage` enum case, `VoiceActionHandlers.sendMessage` closure, and any wiring through `RealtimeVoiceSession` are deleted. Nous's voice agent will no longer have a way to "compose-and-send" — every utterance auto-records, so the indirection is dead weight.

`propose_create_note` and the other action tools remain unchanged.

### 5. Editing, deletion, regeneration

Voice messages persisted to chat are plain `Message` records with `source: .voice`. They are editable, deletable, and regeneratable through the same chat affordances as typed messages. Specifically:

- **Edit**: source flag stays `.voice` (the message was voice originally; editing doesn't change history).
- **Delete**: removes the message from the conversation.
- **Regenerate** (assistant only): produces a new text response. The new message gets `source: .typed`.

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

Persistence migration: existing chat messages default `source = .typed` on first read. No data backfill needed; the field's default handles legacy rows.

### New service: `VoiceTranscriptCommitter`

Sits between `VoiceCommandController` and `ChatViewModel`. Owns the policy for "when does a transcript line become a chat message." Single-responsibility: subscribe to transcript finalize events, dispatch to the bound chat.

```swift
@MainActor
final class VoiceTranscriptCommitter {
    private weak var voiceController: VoiceCommandController?
    private weak var chatViewModel: ChatViewModel?
    private var observed: Int = 0  // last-committed transcript index

    init(voiceController: VoiceCommandController, chatViewModel: ChatViewModel) {
        self.voiceController = voiceController
        self.chatViewModel = chatViewModel
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = voiceController?.transcript
            _ = voiceController?.boundConversationId
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.commitFinalized()
                self?.observe()  // re-arm
            }
        }
    }

    private func commitFinalized() {
        guard let controller = voiceController,
              let viewModel = chatViewModel,
              let conversationId = controller.boundConversationId else { return }

        // Walk new finalized lines from `observed` forward.
        let lines = controller.transcript
        for i in observed ..< lines.count {
            let line = lines[i]
            guard line.isFinal else { continue }
            viewModel.appendVoiceMessage(
                conversationId: conversationId,
                role: line.role,  // .user / .assistant
                text: line.text,
                timestamp: line.createdAt
            )
            observed = i + 1
        }
    }
}
```

### `VoiceCommandController` extension

Add:
```swift
var boundConversationId: ConversationID?
```

Set in the existing `start(apiKey:)` (or wherever activation happens), cleared in `stop()`. The committer subscribes to changes via `withObservationTracking`.

Also: when the session restarts (`start(apiKey:)` after a `stop()`), `boundConversationId` is re-set from the currently-focused chat. This is how a fresh session in a new chat picks up the new ID.

### `ChatViewModel` extension

Add:
```swift
func appendVoiceMessage(
    conversationId: ConversationID,
    role: MessageRole,
    text: String,
    timestamp: Date
)
```

Implementation reuses the existing append-message path (the typed-message persistence flow) with `source: .voice`. The conversation may not be the currently-focused one — append must work against any conversation by ID.

### Voice action registry change

Remove `propose_send_message` from `VoiceActionRegistry`. The Realtime API session's tool list shrinks by one. Update `RealtimeVoiceSession.makeToolDefinitions()` (or whatever names them) and the corresponding tests.

### `VoiceActionHandlers` change

Remove the `sendMessage: (String) -> Void` closure from `VoiceActionHandlers`. Update `VoiceActionHandlers.empty` and every site that builds a real handler. The compiler will surface every site that needs editing.

### `MessageBubble` view extension

Render the mic glyph next to the timestamp when `message.source == .voice`:

```swift
HStack(spacing: 4) {
    Text(message.timestamp, style: .time)
        .font(.system(size: 10, weight: .regular, design: .rounded))
        .foregroundStyle(AppColor.tertiaryText)
    if message.source == .voice {
        Image(systemName: "mic.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AppColor.colaOrange.opacity(0.6))
    }
}
```

The mic appears for both user and assistant voice messages.

## Phase 1 Scope

In scope:

1. Add `MessageSource` enum and `source` field to the `Message` model + persistence.
2. Add `boundConversationId` to `VoiceCommandController`.
3. Create `VoiceTranscriptCommitter` service.
4. Wire the committer into the app's voice + chat lifecycle (likely `ContentView.onAppear`).
5. Add `appendVoiceMessage(...)` to `ChatViewModel`.
6. Render mic icon in `MessageBubble` when source is voice.
7. Remove `propose_send_message` voice tool: model case, registry entry, action handler closure, every call site.
8. Tests: unit (committer dispatch logic), integration (voice → chat round-trip), regression (sendMessage tool gone).
9. Manual QA: voice session of 5+ utterances, switch chat mid-session, regenerate assistant voice response, edit voice message.

Out of scope (deferred):

- Voice playback / re-listen.
- Voice message filter / search.
- Transcript quality indicators.
- Cross-chat session migration.

## Manual QA Test Plan

Before merging, manually verify each:

### Capture
- [ ] Start voice in chat A. Speak 3 user utterances with assistant responses. Confirm 6 chat messages appear in chat A with mic icons.
- [ ] Each user utterance becomes one user message; each assistant response becomes one assistant message. Order matches the spoken order.
- [ ] Live transcript still shows in `VoiceTranscriptPanel` while utterance is in-flight; commit happens at finalize.

### Bound conversation
- [ ] Start voice in chat A. Switch to chat B mid-session. Speak. New utterances land in chat A, not chat B.
- [ ] Sidebar shows a voice indicator on chat A (the bound chat) while voice is active.
- [ ] Stop voice. Switch back to chat A. Confirm all utterances are persisted in correct order.

### Tool removal
- [ ] Voice agent never proposes `sendMessage` (the tool is gone from its registry).
- [ ] `createNote` still works (proposes confirm, dispatches on confirm).
- [ ] Navigation tools still work.

### Edit / delete / regenerate
- [ ] Edit a voice user message → text updates, mic icon stays.
- [ ] Delete a voice message → removed from chat.
- [ ] Regenerate a voice assistant response → new message has no mic icon (source = .typed).

### Visual
- [ ] Mic icon: 11pt SF Symbol `mic.fill`, colaOrange @ 0.6 opacity, sits 4pt right of timestamp.
- [ ] Bubble shape, color, typography unchanged from typed.

### Mixed media
- [ ] Type a message between voice utterances. Both interleave correctly by timestamp. Mic icon only on the voice ones.

## Success Criteria

- After a voice session ends, the chat history contains every finalized utterance from both sides as ordered messages.
- Voice messages are visually distinguishable from typed by a single mic glyph and nothing else.
- The `propose_send_message` tool is gone — voice agent never emits it.
- Switching chats mid-session does not redirect recording.
- All existing chat affordances (edit, delete, regenerate) work on voice messages without special handling.
- No regression in the notch capsule, voice mode state machine, or other voice tools.

## Open Implementation Questions

1. **Where does the committer live in the dependency graph?** `ContentView` already wires `VoiceCommandController` and `VoiceMainWindowFocusObserver`. The committer can be instantiated alongside, with both controller and `ChatViewModel` injected. Confirm during implementation.
2. **Persistence layer**: how exactly does `appendVoiceMessage` plug into the existing message persistence path? Likely the same SwiftData / file-backed write the typed flow uses, just with `source: .voice`. Verify by reading `ChatViewModel`'s typed append path.
3. **Idempotency under restart**: if voice mode stops and restarts in the same chat, `boundConversationId` re-sets, but the `observed` counter in the committer must reset too — otherwise old already-committed indices skip new lines. Reset `observed` whenever `boundConversationId` changes.
4. **VoiceTranscriptPanel role**: still useful as live preview while utterance is in-flight, but verify that finalized lines disappear from it once committed (otherwise we double-display). The panel may need a small change to hide finalized lines.
