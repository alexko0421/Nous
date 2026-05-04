# Cinematic Voice Capsule Redesign

**Date:** 2026-04-28
**Status:** Design Approved. Implementation pending.

## Context
The current `VoiceActionPill` sits above the input box and feels redundant, cluttering the bottom area. Meanwhile, Voice Mode lacks visual feedback for transcriptions. To enhance the "Liquid Glass" and cinematic aesthetic, we are moving the voice status and introducing live subtitle streaming to the top center of the application.

## Design Philosophy
- **Focus Separation:** Bottom is for input and controls. Top is for status and identity.
- **Cinematic Feel:** Subtitles stream gracefully like movie captions or an AI system (e.g., *Her*), not like a rigid terminal.
- **Liquid Morphing:** The capsule smoothly expands and contracts depending on state and text volume.

## Component: `VoiceCapsuleView`
A new view that anchors to the `Top Center` of `ChatArea`.

### States & Animation
1. **Hidden/Idle:** When voice mode is off, the capsule is completely hidden or removed.
2. **Listening/Thinking (No text):** A small capsule containing just the animated `FrameSpinner` or a breathing dot.
3. **Streaming Text:** The capsule expands horizontally. Text streams in using the same `.easeOut(duration: 0.15)` segment-based animation used by `ChatMarkdownRenderer`.

### Layout & Styling
- **Background:** `NativeGlassPanel` with `AppColor.glassTint`. High frosted glass effect.
- **Stroke:** `AppColor.panelStroke` (1px).
- **Text Style:** `Nunito Variable`, 14pt, slightly increased tracking (letter-spacing), `AppColor.colaDarkText`.
- **Constraint:** Maximum width should leave breathing room from the edges (e.g., max-width 600px).
- **Lines:** 1-2 lines max. If it exceeds, it should smoothly scroll or truncate.

## Code Changes Required
1. **Create `VoiceCapsuleView.swift`:** Implement the new top capsule component. It needs access to the voice transcript/status.
2. **Update `ChatArea.swift`:**
   - Remove the existing `VoiceActionPill` from the floating input `VStack`.
   - Add `VoiceCapsuleView` to the `ZStack` overlay, aligned to `.top`.
   - Add a subtle transition (`.move(edge: .top).combined(with: .opacity)`) when it appears.
3. **Handling 'Voice Unavailable':**
   - If the user tries to toggle voice and it fails, the top capsule briefly slides down showing "Voice mode is currently unavailable", then dismisses after 2 seconds.

## Acceptance Criteria
- [ ] Bottom `VoiceActionPill` is completely removed.
- [ ] Toggling Voice Mode reveals the capsule at the top.
- [ ] Speaking populates the capsule with text that streams smoothly.
- [ ] The component respects the Liquid Glass design language.
