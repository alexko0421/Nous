# App-Wide Voice Control Design

**Date:** 2026-04-28
**Status:** User-approved direction, ready for implementation planning after review
**Branch context:** `alexko0421/quick-action-agents`

## Context

Alex wants the microphone button to start a persistent voice mode for Nous, not a one-shot speech command. After one click, he should be able to move through Chat, Galaxy, Notes, and Settings by speaking, while the session stays alive until he turns it off.

The OpenAI `realtime-voice-component` reference pattern is not unconstrained mouse automation. It centers on app-owned tools: the app defines what actions are available, the model chooses from those actions, and the app remains the source of truth for state changes. Nous should follow that pattern natively in SwiftUI.

The current implementation already has the hard parts in place:

- a persistent `VoiceCommandController`
- OpenAI Realtime WebSocket transport
- microphone capture and audio playback
- direct tools for navigation, appearance, settings sections, drafting, and confirmations
- a voice status pill that survives navigation

This design extends that system from a small whitelist into an app-wide voice action registry.

## Product Goal

Clicking the microphone once turns Nous into an app-wide voice-controlled assistant. Alex can keep talking while Nous opens views, drafts text, changes settings, searches memory, and proposes write actions. The session stays active across app navigation until Alex turns it off.

The experience should feel like:

1. Alex clicks the microphone.
2. Nous shows `Listening`.
3. Alex says: "Open Galaxy."
4. Nous switches to Galaxy and keeps listening.
5. Alex says: "Go back to chat and write this down..."
6. Nous opens Chat, fills the composer, and waits for send confirmation.

## Non-Goals

- No system-wide macOS control in this version.
- No arbitrary mouse clicking, coordinate clicking, keyboard typing, AppleScript, or Accessibility automation.
- No destructive voice actions such as deleting nodes or overwriting notes.
- No always-on wake word.
- No browser or React component embedded into the native app.
- No changes to `Sources/Nous/Resources/anchor.md`.

## Core Decision

Build **app-owned universal control**, not simulated clicking.

The voice model can only call actions that Nous exposes. Each action maps to an existing Swift handler or ViewModel method. This makes the feature stable when the UI moves, and it keeps high-risk operations behind confirmation.

## User Experience

### Activation

The microphone button is a toggle:

- inactive -> start voice mode
- active -> stop voice mode

Once active, the Realtime session remains alive across tab changes, settings navigation, and view swaps. The voice controller is owned by the app shell, not by an individual screen.

### Continuous Control

Alex should not need to click the microphone again for each command. Voice mode should accept a sequence like:

- "Open Galaxy."
- "Show me Settings."
- "Turn on dark mode."
- "Go back to chat."
- "Type: I need to review the voice mode idea tonight."
- "Send it."

The first four actions can execute directly. Sending requires confirmation unless the pending draft already exists and Alex explicitly says "send it" while a confirmation is active.

### Visible Feedback

Use the current compact voice pill as the main feedback surface:

- `Listening`
- `Thinking`
- `Opening Galaxy`
- `Drafting message`
- `Confirm send?`
- `OpenAI quota exceeded`
- `Voice unavailable`

The pill is not a transcript panel and should stay visually calm.

## Architecture

```text
Mic toggle
-> VoiceCommandController
-> RealtimeVoiceSession
-> OpenAI Realtime function call
-> VoiceActionRegistry
-> App-owned action handler
-> SwiftUI state or ViewModel mutation
-> voice status pill
```

### VoiceActionRegistry

Add a registry layer that owns the action catalog. It should produce:

- Realtime function tool declarations
- argument validation metadata
- action risk metadata
- execution routing to app-owned handlers
- a state snapshot tool result

This keeps `RealtimeVoiceSession` focused on transport and keeps `VoiceCommandController` from becoming a long switch statement forever.

### VoiceAppSnapshot

Add a small, serializable snapshot of current app state that the model can inspect before acting:

```swift
struct VoiceAppSnapshot: Equatable {
    var currentTab: VoiceNavigationTarget
    var settingsSection: VoiceSettingsSection?
    var composerText: String
    var selectedProjectName: String?
    var sidebarVisible: Bool
    var scratchpadVisible: Bool
    var activeConversationTitle: String?
}
```

The snapshot should describe the app state, not expose private raw database rows. It is context for control decisions.

### Risk Levels

Each action has one of three risk levels:

```swift
enum VoiceActionRisk: Equatable {
    case direct
    case confirmationRequired
    case readOnly
}
```

- `direct`: safe UI changes such as navigation and appearance.
- `readOnly`: search and state inspection.
- `confirmationRequired`: actions that persist or send user-authored content.

## Initial Action Catalog

### Read-Only Tools

| Tool | Purpose |
|---|---|
| `get_app_state` | Return the current app snapshot before acting. |
| `search_memory` | Search existing memory context. |
| `recall_recent_conversations` | Return short recent conversation summaries. |

### Direct Tools

| Tool | Purpose |
|---|---|
| `navigate_to_tab` | Switch between Chat, Notes, Galaxy, and Settings. |
| `open_settings_section` | Open Profile, General, Models, or Memory settings without stopping voice mode. |
| `set_appearance_mode` | Switch Light, Dark, or System appearance. |
| `set_sidebar_visibility` | Show or hide the sidebar. |
| `set_scratchpad_visibility` | Show or hide the scratchpad. |
| `set_composer_text` | Replace the chat composer text. |
| `append_composer_text` | Append to the chat composer. |
| `clear_composer` | Clear the chat composer. |
| `start_new_chat` | Start a blank chat state. |

### Confirmation Tools

| Tool | Purpose |
|---|---|
| `propose_send_message` | Prepare a message for sending and show confirmation. |
| `propose_note` | Prepare a note for creation and show confirmation. |
| `confirm_pending_action` | Confirm the current pending action. |
| `cancel_pending_action` | Cancel the current pending action. |

## App-Owned Handlers

`ContentView` continues to bind voice actions to real app state:

- navigation sets `selectedTab`
- settings navigation sets `selectedSettingsSection`
- appearance writes `appearanceMode`
- composer actions mutate `ChatViewModel.inputText`
- sending calls `ChatViewModel.send(attachments: [])`
- note creation calls `NoteViewModel.createNote(...)`

The registry should call handler closures, not access SwiftUI state directly.

## Safety Model

Direct actions can run immediately because they are reversible and do not persist user data.

Persistent actions require confirmation:

- sending a chat message
- creating a note
- any future update that writes to existing content

Rejected for this version:

- delete node
- overwrite note
- arbitrary UI click
- run command
- open external app
- use Accessibility permissions

## Error Handling

- Missing OpenAI key: show `Add OpenAI API key`.
- Quota error: show `OpenAI quota exceeded`.
- Microphone permission denied: show `Microphone blocked`.
- Unknown tool: return a tool error and do not mutate UI.
- Invalid arguments: return a validation error and show `Voice command rejected`.
- Pending action conflict: keep the current pending action and reject the new write action.
- App state snapshot failure: return a minimal snapshot rather than stopping voice mode.

## Testing Strategy

Unit tests should cover:

- mic toggle starts once and stops once
- voice session remains active when opening Settings
- `get_app_state` returns current tab, composer text, sidebar, scratchpad, and settings section
- direct tools call the correct handlers
- confirmation tools do not persist until confirmed
- unknown tools are rejected without mutation
- invalid arguments are rejected without mutation
- pending action conflicts are rejected

Existing `VoiceCommandControllerTests` and `RealtimeVoiceSessionTests` remain the main test surface. Add new focused tests before implementation.

## Implementation Shape

Recommended file ownership:

- `Sources/Nous/Models/Voice/VoiceModeModels.swift`: shared enums and small value types.
- `Sources/Nous/Services/VoiceActionRegistry.swift`: action catalog, schemas, risk metadata, dispatch helpers.
- `Sources/Nous/Services/VoiceCommandController.swift`: session state, pending confirmations, error handling, registry execution.
- `Sources/Nous/Services/RealtimeVoiceSession.swift`: transport and function tool declarations sourced from registry.
- `Sources/Nous/App/ContentView.swift`: app state snapshot and handlers.
- `Tests/NousTests/VoiceActionRegistryTests.swift`: registry schema and dispatch tests.
- `Tests/NousTests/VoiceCommandControllerTests.swift`: behavior and confirmation tests.

## Rollout Plan

1. Extract the existing hard-coded voice tools into `VoiceActionRegistry`.
2. Add `get_app_state` and a `VoiceAppSnapshot` provider.
3. Keep existing actions behaviorally identical.
4. Extend tests to prove persistent voice mode survives tab and settings navigation.
5. Add additional app-wide actions incrementally after the registry boundary is stable.

## Open Questions

None blocking implementation. The first version controls only Nous itself, not macOS or other apps.
