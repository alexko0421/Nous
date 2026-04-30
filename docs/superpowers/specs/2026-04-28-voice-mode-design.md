# Voice Mode Design

**Date:** 2026-04-28
**Status:** Approved direction, ready for implementation planning
**Branch context:** `alexko0421/quick-action-agents`

## Context

Alex wants the OpenAI realtime voice-component feeling inside Nous: he should be able to speak and watch the app respond while he is still thinking. The important behavior is not dictation. It is a constrained voice agent that can understand speech, call app-owned tools, and update the current Nous surface.

The referenced OpenAI repo is a React/browser reference implementation for voice-driven UI control on top of OpenAI Realtime. Nous is a native SwiftUI macOS app, so the design borrows the product pattern but does not embed the React widget. A WebView bridge would create a second UI runtime and force every app action through Swift-JavaScript plumbing.

OpenAI's current Realtime docs support the underlying model: low-latency speech-to-speech sessions over WebRTC/WebSocket with function/tool events. For a native macOS app, the correct boundary is: Swift owns the microphone, session lifecycle, tool execution, and UI state. The model may request narrow actions; it does not click the app.

## Product Goal

Voice Mode lets Alex speak naturally while Nous prepares and executes safe app actions in real time. It should feel like:

> "Open Galaxy" -> action pill says "Opening Galaxy" -> the app switches to Galaxy.

It should not feel like a browser automation demo. No ghost cursor. No model-driven mouse clicks. No unconstrained UI control.

## Decisions Locked

1. **Authority model:** Confirm-actions mode. The agent may execute low-risk navigation and drafting actions directly. Persistent or irreversible actions require confirmation.
2. **Primary first version:** All-in voice chat, internally implemented as live drafting plus memory/tool lookup. Alex can speak a whole turn, watch Nous gather context or navigate, then confirm send.
3. **Action feedback:** Use a lightweight action pill, not silent changes and not ghost cursor animation.
4. **Implementation layer:** Native SwiftUI + Swift services. Do not embed the React component as the product path.

## Goals

- Add a visible Voice Mode entry point to the chat surface.
- Stream microphone audio into an OpenAI Realtime session when Voice Mode is active.
- Allow the Realtime model to request a small whitelist of app-owned tools.
- Execute safe UI actions immediately.
- Queue persistent actions behind explicit confirmation.
- Show current voice state and recent action in a calm pill.
- Keep existing chat, RAG, memory, and quick-action turn pipelines intact.

## Non-Goals

- No React, npm, or WKWebView voice runtime in the first implementation.
- No ghost cursor.
- No free-form mouse, keyboard, or accessibility control.
- No deleting, overwriting, or destructive voice action.
- No always-on wake word.
- No local/offline voice model in this version.
- No changes to `Sources/Nous/Resources/anchor.md`.

## User Experience

### Entry Point

`ChatArea` adds a small microphone button near the composer. It follows existing glass/orange styling and should not dominate the screen.

When the OpenAI API key is missing, the microphone button is disabled and its tooltip explains that Voice Mode needs an OpenAI key because audio is sent to OpenAI Realtime. Voice Mode should not silently reuse Gemini, Claude, OpenRouter, or Local because this feature depends on OpenAI Realtime.

### Active State

When active, a compact pill appears above or near the composer. It shows one short status at a time:

- `Listening`
- `Thinking`
- `Searching memory`
- `Opening Galaxy`
- `Drafting message`
- `Confirm send?`
- `Voice unavailable`

The pill is operational feedback, not a transcript panel. It should remain calm and small.

### Example Flows

**Navigate**

1. Alex says: "Open Galaxy."
2. Realtime emits `navigate_to_tab({ "tab": "galaxy" })`.
3. `VoiceCommandController` validates the tool call.
4. `ContentView` sets `selectedTab = .galaxy`.
5. Pill shows `Opening Galaxy`.

**Draft and Confirm Send**

> **Deprecated 2026-04-29**: `propose_send_message` was removed when voice
> mode became direct chat. See
> `docs/superpowers/specs/2026-04-29-voice-transcript-chat-persistence-design.md`.
> Voice user utterances now auto-record into chat history.

1. Alex speaks a long thought.
2. Realtime emits transcript deltas and maybe memory search tool calls.
3. Nous updates `ChatViewModel.inputText` with the draft.
4. Realtime emits `propose_send_message({ "text": "..." })`.
5. Pill shows `Confirm send?`.
6. Alex clicks confirm or says "send it."
7. Only then does `ChatViewModel.send(...)` run.

**Open Scratchpad**

1. Alex says: "Open scratchpad and put this aside."
2. Voice tool sets `isScratchPadVisible = true`.
3. Drafted content can appear in composer or a pending scratchpad draft, but saving any new persisted note requires confirmation.

## Architecture

```text
AVAudioEngine microphone capture
-> RealtimeVoiceSession
-> OpenAI Realtime events
-> VoiceCommandController
-> VoiceToolRegistry
-> App-owned handlers
-> SwiftUI state updates
-> VoiceActionPill
```

### New Components

**`RealtimeVoiceSession`**

Owns the OpenAI Realtime connection, microphone lifecycle, event parsing, and cancellation. It exposes session events to the main actor and has no direct access to app state.

**`VoiceCommandController`**

Main-actor coordinator that receives Realtime events and decides what to do. It validates tool names and arguments, updates voice state, calls app handlers, and manages pending confirmations.

**`VoiceToolRegistry`**

Defines the whitelist of voice tools and their schemas. It should be separate from `AgentToolRegistry` because voice tools include UI actions and write-intent proposals, while current agent tools are read-only memory/search tools.

**`VoiceActionPill`**

Small SwiftUI view that renders current voice status and pending confirmations. It should be reusable and visually consistent with current glass panels.

**`VoicePermissionNotice`**

Short settings or first-use disclosure: Voice Mode sends microphone audio to OpenAI while active. This is privacy-sensitive and must be explicit.

## Tool Contract

Voice tools are app-owned. Each tool does one concrete thing and maps to existing state or service methods.

### Direct Tools

These can execute immediately:

| Tool | Arguments | Effect |
|---|---|---|
| `navigate_to_tab` | `tab: "chat" / "notes" / "galaxy" / "settings"` | Sets the selected main tab. |
| `set_sidebar_visibility` | `visible: Bool` | Shows or hides the left sidebar. |
| `set_scratchpad_visibility` | `visible: Bool` | Shows or hides scratchpad panel in chat. |
| `set_composer_text` | `text: String` | Replaces the current composer draft. |
| `append_composer_text` | `text: String` | Appends to the current composer draft. |
| `clear_composer` | none | Clears current composer text. |
| `start_new_chat` | none | Starts a blank chat state. |
| `search_memory` | `query: String, limit: Int?` | Uses existing read-only memory/search path and returns short context to the Realtime session. |
| `recall_recent_conversations` | `limit: Int?` | Returns recent conversation summaries. |

### Confirmation Tools

These create a pending action. They do not mutate persistent data until confirmed:

| Tool | Arguments | Pending action |
|---|---|---|
| `propose_send_message` | `text: String` | Shows confirmation to send the current chat turn. |
| `propose_note` | `title: String, body: String` | Shows confirmation to create a note. |
| `propose_scratchpad_entry` | `text: String` | Shows confirmation before persisting scratchpad content, if persistence is added. |

### Rejected Tools

Do not add these in v1:

- `delete_node`
- `overwrite_note`
- `run_shell_command`
- `click_at_point`
- `type_keyboard`
- arbitrary AppleScript or Accessibility actions

## Confirmation Model

`VoiceCommandController` owns one pending confirmation at a time:

```swift
enum VoicePendingAction: Equatable {
    case sendMessage(text: String)
    case createNote(title: String, body: String)
}
```

If a second pending action arrives before the first is resolved, the controller replaces the pending action only if the new request has the same case and clearly supersedes the old draft. Otherwise it rejects the second action and asks the model to wait for confirmation.

Confirm can come from:

- clicking the pill's confirm button
- saying "send it", "confirm", or equivalent, handled by a narrow `confirm_pending_action` tool

Cancel can come from:

- clicking cancel
- saying "cancel that", handled by `cancel_pending_action`
- stopping Voice Mode

## Privacy and Permissions

- Add `NSMicrophoneUsageDescription` to `Info.plist`.
- Voice Mode starts only after user action. No always-listening background mode.
- Audio is sent to OpenAI only while the active pill shows a listening/processing state.
- If no OpenAI key is stored, Voice Mode is unavailable.
- Stopping Voice Mode tears down microphone capture and the Realtime connection.
- Voice transcripts should not be persisted separately in v1. Persist only the final chat message or note after explicit confirmation.

## Error Handling

- Missing microphone permission: pill shows `Microphone blocked`; keep the composer usable.
- Missing OpenAI key: mic button disabled; settings should already expose the OpenAI key field.
- Realtime connection failure: stop session, show `Voice unavailable`.
- Unknown tool: ignore it, return a tool error to the session, and show no UI mutation.
- Invalid arguments: reject the tool call and return a short validation error.
- Pending confirmation timeout: after a short idle period, keep the draft in composer but clear the pending action.

## Integration Points

**`ContentView`**

Owns high-level app actions: tab navigation, sidebar visibility, scratchpad visibility. It should construct the `VoiceCommandController` with closures rather than letting the controller mutate view state through globals.

**`ChatArea`**

Renders the mic button and `VoiceActionPill`. It already owns composer state through `ChatViewModel`, so voice drafting should route through the view model or a small binding closure.

**`ChatViewModel`**

Receives draft text updates and confirmed send requests. It should not know about OpenAI Realtime transport.

**`SettingsViewModel`**

Exposes whether Voice Mode is available from the stored OpenAI key. Do not add a new provider. Voice Mode is a feature that uses OpenAI Realtime, not a replacement foreground provider.

**Existing agent tools**

Current `AgentToolRegistry` remains for text-agent memory tools. Voice v1 may reuse underlying read services, but it should not reuse the same tool type because voice tools include UI mutation and confirmation semantics.

## Testing

Unit tests should cover:

- tool name whitelist rejects unknown tools
- `navigate_to_tab` accepts only known tabs
- direct tools update their injected handlers exactly once
- confirmation tools create pending actions without executing them
- confirm executes the pending action once and clears it
- cancel clears pending action without executing it
- missing OpenAI key reports unavailable state
- stopping Voice Mode cancels any pending confirmation

Manual QA should cover:

- microphone permission prompt
- start and stop session
- saying "open Galaxy"
- saying "open scratchpad"
- dictating a message draft
- confirming send
- canceling a proposed send
- missing OpenAI key disabled state

## Implementation Planning Decisions

1. **Use Realtime WebSocket first.** WebRTC is the browser/client recommendation, but native Swift WebRTC would likely require a new dependency or a large bridge. `URLSessionWebSocketTask` plus `AVAudioEngine` keeps v1 inside system frameworks and the existing dependency rules. Revisit WebRTC only if latency or audio stability is unacceptable.
2. **No assistant audio output in v1.** Voice Mode is a control/drafting surface first. Nous can render the assistant reply through the existing chat UI after confirmed send. This avoids adding output-device routing, interruption handling, and overlapping spoken replies before the core control loop works.
3. **Use a voice-specific read facade.** Voice memory tools may reuse `NodeStore`, `VectorStore`, and `EmbeddingService`, but they should not reuse `AgentTool` types directly because voice tools mix read actions, UI actions, and confirmation-gated write intents.
4. **Use `gpt-realtime` as the initial Realtime model.** Keep the model string local to the voice session implementation so it can be changed without touching foreground chat provider selection.

## References

- OpenAI realtime voice component: https://github.com/openai/realtime-voice-component
- OpenAI Realtime API guide: https://platform.openai.com/docs/guides/realtime
- OpenAI Realtime WebRTC guide: https://platform.openai.com/docs/guides/realtime-webrtc
