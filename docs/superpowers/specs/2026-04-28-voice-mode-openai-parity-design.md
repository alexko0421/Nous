# Voice Mode — OpenAI Parity Design

**Date:** 2026-04-28
**Status:** Approved direction, ready for implementation planning
**Branch context:** `alexko0421/quick-action-agents`
**Supersedes (partially):** `2026-04-28-voice-mode-design.md` — specifically the "No ghost cursor" non-goal. Other decisions in that doc remain in force.

## Context

Alex wants Nous's voice mode to feel like the OpenAI `realtime-voice-component` reference. The earlier voice spec borrowed that pattern but explicitly opted out of three things: ghost cursor, transcript panel, and a live audio waveform. After watching voice mode in use, Alex re-decided he wants those three pieces. This spec defines the design for adding them while keeping the existing native Swift voice stack intact.

We do **not** embed the OpenAI React widget. Implementation stays native SwiftUI, consuming our existing `RealtimeVoiceSession`, `VoiceAudioCapture`, `VoiceCommandController`, `VoiceActionRegistry`, and `VoiceCapsuleView`. The OpenAI repo is treated as a reference for behavior, timing, and visual semantics — not as a runtime dependency.

## Reference Verification

We cloned `https://github.com/openai/realtime-voice-component` and read the source directly so this spec is grounded in actual reference behavior rather than guessed behavior. Three places where the design must distinguish faithful parity from Nous-original work:

- **Ghost cursor** — Real in the reference. Constants and behavior in this spec are ported from `src/useGhostCursor.ts`, `src/components/GhostCursorOverlay.tsx`, and `src/styles.css`.
- **Transcript panel** — Not present in the reference as a UI component. The reference exposes `transcript: string` on its controller snapshot but does not render a panel. Nous's transcript panel is original work, designed in the spirit of the reference's tool-constrained product pattern.
- **Audio waveform** — Not present in the reference. The reference uses six state-coded SVG icons (idle / listening / live / connecting / busy / error). Nous's bar waveform is original work.

The Nous-original pieces and the chromatic accents on the ported ghost cursor all use the colaOrange identity per the standing visual-language memory. The reference uses cyan/zinc tones by default and warm orange for error; we replace the cyan/zinc accents with colaOrange while keeping the cursor's pointer body dark and reserving system red for error. We diverge on color intentionally; behavior, layout, and timing for the ghost cursor stay reference-faithful.

## Decisions Locked

1. **Authority model** — unchanged from prior spec. Confirm-actions mode. Low-risk navigation/drafting executes directly. Persistent or irreversible actions still require confirmation.
2. **Launcher placement** — Nous keeps the existing top-center floating capsule (`VoiceCapsuleView` in `ChatArea.swift`). No corner-snap launcher. The reference's bottom-right launcher pattern does not apply because Nous already has an upper-middle floating UI vocabulary.
3. **Ghost cursor execution timing** — reference-faithful. Travel completes first, then the tool's side-effect runs. Reference `useGhostCursor` does `await animateMainCursorTravel(...)` then `await operation()`. We do the same.
4. **Transcript panel** — Nous-original. Streamed bubble panel, ephemeral, cleared on voice mode close.
5. **Audio waveform** — Nous-original. Bar visualization, colaOrange palette, not the reference's SVG icon set.
6. **Color identity** — chromatic accents on all three new surfaces use the colaOrange family. The ghost cursor's pointer body stays dark navy (it reads as a recognizable cursor shape on either palette); only its halo, trail, and core accents move to colaOrange. Reference cyan/blue accents map to colaOrange tones; error state stays system red.

## Goals

- Add a ghost-cursor overlay that animates over the app window when a spatial tool fires, then triggers the underlying state change.
- Add a transcript panel below the capsule that streams user and assistant lines while voice mode is active.
- Replace the static dot inside `VoiceCapsuleView` with a colaOrange waveform driven by mic audio level.
- Keep the existing capsule, tool registry, realtime session, action pill, and confirm flow intact.

## Non-Goals

- No React, npm, or WKWebView voice runtime.
- No persisting voice transcript beyond the live session.
- No ghost-cursor coverage of non-spatial tools (memory recall, appearance toggle, get-state).
- No multi-window support; voice runs on the front window only.
- No accessibility-tree auto-discovery of ghost-cursor targets — only views explicitly tagged with `.ghostCursorTarget(id:)` are reachable.
- No anchor.md edits.
- No new model providers or API routing changes.

## Architecture Overview

The existing voice stack is the spine. Three SwiftUI surfaces and one published audio-level signal are net-new.

```
Existing (unchanged):
  RealtimeVoiceSession  ──┐
                          ├── VoiceCommandController ──── VoiceActionRegistry
  VoiceAudioCapture     ──┘                          \
                                                       ── VoiceActionPill (confirm flow)

Net-new:
  VoiceAudioCapture.audioLevel  ──── VoiceWaveformBars  (inside VoiceCapsuleView)
  VoiceCommandController.transcript  ──── VoiceTranscriptPanel
  VoiceCommandController.ghostCursorIntent  ──── GhostCursorOverlay
  GhostCursorRegistry (EnvironmentObject)  ──── views tagged with .ghostCursorTarget(id:)
```

`ghostCursorIntent` is published before a spatial tool's side-effect. The overlay animates from the capsule's center to the registered target frame, then signals back; the controller then runs the tool. Non-spatial tools skip the overlay and execute immediately.

## Components & Contracts

### `VoiceAudioCapture` extension

Adds one published value:

```swift
@Published private(set) var audioLevel: Float  // 0.0...1.0
```

Computation: rolling RMS over a ~60ms window from the existing `AVAudioEngine` tap, with an exponential smoothing pass (`smoothed = 0.8 * prev + 0.2 * current`) applied at ~30 Hz. Mic permission revocation drives the level to zero. (The reference does not expose audio level for display; this is Nous-original.)

### `VoiceWaveformBars`

A new SwiftUI view rendered inside `VoiceCapsuleView`, replacing the current static dot. Five vertical bars, 3pt wide, 2pt gap, rounded caps. Each bar's height envelope is center-weighted so middle bars peak higher than edges, giving a "breathing" feel:

```
height(i, t) = clamp(level * (0.6 + 0.4 * sin(i * phase + t)), minH, maxH)
minH = 4, maxH = 22, phase ≈ 0.85, t ticks at 30 Hz
```

State-driven coloring uses Nous's existing `AppColor.colaOrange`:

| State | Bar color | Animation |
|---|---|---|
| Idle (connected, not capturing) | colaOrange dimmed (0.28 alpha) | flat 4pt bars |
| Listening | colaOrange full | level-driven |
| Thinking / processing | colaOrange medium (0.6 alpha) | slow shimmer keyframe |
| Error | system red | flat 4pt bars |

Animation: `.spring(response: 0.18, dampingFraction: 0.7)` for height transitions; `.easeInOut(duration: 0.14)` for color crossfades. Honors `@Environment(\.accessibilityReduceMotion)` by holding bars at flat midline.

### `VoiceTranscriptLine` model + controller publishers

```swift
struct VoiceTranscriptLine: Identifiable {
    let id: UUID
    let role: Role          // .user / .assistant
    var text: String
    var isFinal: Bool
    let createdAt: Date
}
```

`VoiceCommandController` adds:

```swift
@Published private(set) var transcript: [VoiceTranscriptLine] = []
@Published private(set) var ghostCursorIntent: GhostCursorIntent? = nil
```

Stream reducer: incoming `RealtimeVoiceSession` text deltas append to the in-progress line for the current role. A final/done event flips `isFinal = true` and seals the line; the next delta of the other role opens a new line. Barge-in events truncate the in-progress assistant line (text kept; mark `isFinal = true`).

### `VoiceTranscriptPanel`

A SwiftUI view bound to `controller.transcript`. Anchored just under the floating capsule, top-center, max width ~480pt, max height ~50% of window height, scrollable. Slides up + fades in (220ms) when voice mode opens; fades out + clears when it closes.

Bubble layout:

- User bubble — right-aligned, label "You" in 11pt uppercase tracking, body text in primary foreground.
- Assistant bubble — left-aligned, label "Nous" in 11pt uppercase tracking, body text on a translucent colaOrange-tinted background (4% alpha).
- In-progress (non-final) lines render at 70% opacity; final lines 100%.

Auto-scroll behavior: scrolls to bottom on new content unless the user has scrolled up; if the user reaches the bottom again, auto-scroll resumes. (One latched flag.)

### `GhostCursorRegistry`

An `EnvironmentObject` that maps stable string IDs to global frames. Views register via:

```swift
.ghostCursorTarget(id: "tab_galaxy")
```

The modifier uses a `GeometryReader` to publish the view's frame in global coordinates whenever it changes. The registry stores the latest frame per ID. Stale frames are tolerated; missing IDs return nil (overlay then skips animation, controller falls through to immediate execution).

Initial registered IDs:

- `tab_chat`, `tab_notes`, `tab_galaxy`, `tab_settings`
- `sidebar_toggle`
- `scratchpad_toggle`
- `appearance_toggle`

The IDs map to existing tool names plus argument values. Mapping is owned by `VoiceCommandController` (a small switch on `(toolName, args)` → `targetId?`).

### `GhostCursorOverlay`

A top-level overlay placed in `ContentView` body, positioned above all chrome. Subscribes to `controller.ghostCursorIntent`. Visual is composed of four layered SwiftUI shapes that mirror the reference's CSS structure:

- **Pointer** — 18×26pt arrow shape rendered via `Path` (clip-path equivalent). Dark navy fill with a light inner highlight.
- **Core** — 2×10pt soft-edged rectangle inside the pointer, colaOrange-tinted gradient.
- **Halo** — 24×24pt radial gradient circle behind the pointer, blurred ~4pt, colaOrange tones.
- **Trail** — 22×8pt linear gradient sliver behind the cursor during travel, blurred ~3pt, colaOrange tones.

Phases match the reference: `hidden`, `traveling`, `arrived`, `error`. Phase transitions are CSS-inspired and ported directly:

- **Travel duration** — `clamp(320 + distance * 0.18, 320, 560)` ms, where `distance` is the Euclidean point-to-point distance from origin to target.
- **Travel easing** — `.timingCurve(0.22, 0.84, 0.26, 1.0)` (Nous's "smooth" default). An "expressive" alternative `.timingCurve(0.16, 1.18, 0.3, 1.0)` (slight overshoot) is available as an option if a tool wants more punch.
- **Arrival pulse on the target view** — 180ms ease-out, 3pt + 8pt colaOrange box-shadow rings (28% / 12% alpha). Implemented as a transient ring overlay on the target view via the registry's pulse hook.
- **Step hold after arrival** — 260ms before the cursor begins its hide animation.
- **Idle hide** — 5000ms of inactivity hides the cursor.
- **Auto-dismiss** — any user-initiated scroll, wheel, or trackpad pan during travel cancels the cursor immediately. (SwiftUI: subscribe to `NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel])` while a cursor is in flight.)
- **Reduced motion** — when `@Environment(\.accessibilityReduceMotion)` is true, skip travel, jump straight to "arrived" phase, run the operation, fade out.

Origin point: the center of the floating capsule's frame, captured via the registry under id `voice_capsule`.

### `VoiceCommandController` additions

New state:

```swift
@Published private(set) var transcript: [VoiceTranscriptLine] = []
@Published private(set) var ghostCursorIntent: GhostCursorIntent?

private let spatialTools: Set<String> = [
    "navigate_to_tab",
    "set_sidebar_visibility",
    "set_scratchpad_visibility",
    "set_appearance_mode",
]
```

Tool dispatch flow change:

1. Receive validated tool call from registry.
2. If `VoiceActionRegistry.risk(for: name) == .confirmationRequired`: existing confirm flow runs first (unchanged). Only after the user confirms does dispatch proceed to step 3.
3. If `spatialTools.contains(name)`:
   a. Resolve `(name, args) → targetId?`. If nil, fall through to step 4.
   b. Publish `ghostCursorIntent = GhostCursorIntent(targetId:, easing: .smooth, ...)`.
   c. Await any of: `cursorDidArrive` callback from the overlay, `cursorDismissed` event from auto-dismiss (user scrolled), or a 700ms timeout. Whichever fires first releases the gate.
   d. Then execute the tool handler.
4. Else execute the tool handler immediately.

Tool result narration (e.g., "Galaxy is open") is produced by the realtime model in its follow-up response, not synthesized by the controller; it reaches the transcript through the normal transcript-stream reducer. The controller does not write to `transcript` directly except when sealing an in-progress line on barge-in or disconnect.

The 700ms timeout protects against an overlay bug or unregistered target. The `cursorDismissed` short-circuit ensures a user who shifts attention mid-animation does not see the tool stall.

## Data Flow & Timing

Three streams run concurrently while voice mode is active.

**Audio loop** (never gated):
```
AVAudioEngine tap → RMS smoothing → audioLevel @Published @ 30 Hz → VoiceWaveformBars
```

**Transcript stream** (never gated):
```
RealtimeVoiceSession event → controller.transcript reducer → VoiceTranscriptPanel
```

**Tool execution** (gated by ghost cursor for spatial tools):
```
RealtimeVoiceSession → tool_call event
  ↓
controller validates against VoiceActionRegistry
  ↓
[risk == .confirmationRequired] → action pill (existing) → user confirms
  ↓
[spatial?] → publish ghostCursorIntent
           → await { arrive | dismissed | 700ms }
           → execute tool handler
[non-spatial?] → execute tool handler immediately
```

Streams 1 and 2 are independent of 3. Assistant audio + transcript continue streaming while the cursor is in flight; the user sees synchronized "speaking + moving" rather than "speak then move."

## Visual Identity

The reference uses cyan/zinc tones in the default state and warm orange in the error state. Nous flips this:

| Element | Reference (default) | Nous |
|---|---|---|
| Halo | `rgba(127, 233, 255, ...)` | `AppColor.colaOrange` at matching alpha |
| Trail | `rgba(91, 219, 255, ...)` | `AppColor.colaOrange` at matching alpha |
| Core accent | `#97f0ff` family | `AppColor.colaOrange` |
| Target pulse rings | `rgba(61, 221, 255, 0.28 / 0.12)` | colaOrange at the same alphas |
| Pointer body | dark navy `#101827`-ish | unchanged (dark navy reads as cursor on either palette) |
| Error halo | warm orange `rgba(255, 184, 134, ...)` | system red, brighter alpha |
| Waveform bars | n/a (reference has no waveform) | colaOrange family, see `VoiceWaveformBars` table above |

The pointer body stays dark; only the chromatic accents move to colaOrange. This preserves the reference's "tool just landed here" affordance (a recognizable cursor shape) while signaling Nous identity through the highlight.

## Error Handling

- **Mic permission revoked mid-session** — `audioLevel` drops to 0; capsule shows "Voice unavailable"; transcript panel freezes with whatever it had; ghost cursor cancels in-flight intents; existing voice-availability flow disables the entry button until permission is restored.
- **Ghost cursor target missing in registry** — overlay logs once via `os_log`, returns immediately; controller skips travel and runs the tool. Behavior matches reference's "silently no-op on null target."
- **Tool error after ghost cursor arrival** — pointer transitions to `error` phase (red halo) for 320ms before fading, controller writes an error line to transcript ("Couldn't open Galaxy — retry?"), existing controller error handling continues.
- **Network / WebRTC drop mid-tool** — existing `RealtimeVoiceSession` reconnect path runs; in-progress transcript line is sealed with `isFinal = true` and a small "(disconnected)" suffix; pending ghost cursor intent is cancelled.
- **User scrolls during travel** — overlay dismisses ghost cursor immediately (matches reference auto-dismiss). Tool still executes (we don't gate execution on the cursor reaching the target if the user has shifted attention).

## Testing

- **Unit**
  - `VoiceTranscriptLine` reducer: streamed deltas → final transitions across role boundaries; barge-in seals in-progress assistant line.
  - Audio level smoothing: synthetic 30 Hz fixture produces stable, non-clipped 0.0–1.0 output.
  - Ghost cursor target ID resolution: each mapping `(toolName, args) → targetId?` returns expected ID or nil.
  - Travel duration formula: clamp boundaries verified at distance = 0, 1000, 5000.
- **Snapshot (preview-driven)**
  - `VoiceCapsuleView` with each of: idle, listening (level 0.2 / 0.5 / 0.9), thinking, error.
  - `VoiceTranscriptPanel`: empty, mid-stream, multi-turn, very long (scroll), barge-in interrupted.
  - `GhostCursorOverlay`: hidden, traveling at three points along the path, arrived, error.
- **Manual / live**
  - Fresh-conversation live test (per the surgical-edit memory): say "Open Galaxy" — cursor traverses, tab switches, transcript shows both turns, waveform reacts to voice. Repeat for sidebar/scratchpad/appearance toggles.
  - Reduced-motion live test: enable system "Reduce motion," say "Open Galaxy" — cursor jumps to arrived without travel.
  - Mic-revoke live test: revoke microphone permission while listening — capsule shows "Voice unavailable," transcript freezes, no crash.
  - Scroll-during-travel test: trigger a long-distance ghost cursor and scroll the chat area mid-travel — cursor dismisses without orphaning the tool.

## Open Items for Implementation Plan

These are flagged for the writing-plans phase, not decided here.

- Phasing. Per the strict-AI-agent-phased-plan memory, Alex prefers incremental shipping with live tests between phases. Suggested ordering: (1) audio level + waveform replacement in capsule, (2) transcript panel + transcript reducer, (3) ghost cursor registry + overlay + controller wiring. Each ships and live-tests before the next.
- Whether to register Galaxy node frames as ghost-cursor targets (so the cursor can fly to a specific node, not just the Galaxy tab). Out of scope for the first ship; revisit after Phase 3 lands.

## References

- OpenAI realtime-voice-component: https://github.com/openai/realtime-voice-component
- Reference files studied: `src/useGhostCursor.ts`, `src/components/GhostCursorOverlay.tsx`, `src/components/VoiceControlWidget.tsx`, `src/voiceControlController.ts`, `src/styles.css`
- Prior Nous voice spec: `docs/superpowers/specs/2026-04-28-voice-mode-design.md`
- Prior app-wide voice control spec: `docs/superpowers/specs/2026-04-28-app-wide-voice-control-design.md`
- Existing implementation: `Sources/Nous/Services/VoiceCommandController.swift`, `Sources/Nous/Services/RealtimeVoiceSession.swift`, `Sources/Nous/Services/VoiceAudioCapture.swift`, `Sources/Nous/Services/VoiceActionRegistry.swift`, `Sources/Nous/Views/VoiceActionPill.swift`, `Sources/Nous/Views/ChatArea.swift` (`VoiceCapsuleView`)
