# Composer Action Menu Soft Stagger - Design

**Date:** 2026-05-16
**Status:** Implemented after Alex selected option B.
**Scope:** `Sources/Nous/Views/ChatArea.swift`, `Sources/Nous/Views/WelcomeView.swift`, `Sources/Nous/Models/ActionMenuSeparationMotion.swift`, and focused motion tests.
**Non-scope:** Attachment picking behavior, source ingestion, YouTube panel behavior, voice routing, send-button separation policy, `anchor.md`, and unrelated composer layout changes.

## Problem

The composer leading `+` menu works, but the current motion feels too swirly for Nous. Opening the menu rotates the icon and combines scale, blur, glow, and shadow. In use, that makes the control feel like it spins out with a visible shadow trail.

Alex selected option B from the local visual companion:

`/.superpowers/brainstorm/86865-1778971286/content/composer-menu-motion-options.html`

The desired direction is a calm soft stagger: no icon rotation, lighter shadow, and menu actions appearing with a small sequential reveal.

## Goals

- Use the same composer action menu motion in the Welcome composer and normal chat composer.
- Remove the `+` to `xmark` rotation. The state change can crossfade or replace, but it must not spin.
- Make the menu emerge from below with a soft popover feel: `opacity`, small upward `y` settle, and modest scale.
- Stagger File, Photo, YouTube, and Voice items by a short interval so the menu has a little life without becoming playful.
- Reduce the menu and leading-button shadow/glow so the control stays visually calm on the warm glass surface.
- Preserve all existing actions, hit testing, accessibility hiding, and attachment/photo/YouTube/voice callbacks.

## Non-goals

- No redesign of the composer row.
- No new attachment types.
- No new third-party animation dependency.
- No change to when the action menu opens or closes.
- No change to the primary send button in this slice, except avoiding accidental motion regressions nearby.
- No animation work for the assistant streaming text; that is covered by the separate visual-line streaming fade design.

## Design

### 1. Motion Contract

The approved B motion has these target values:

- Menu starts at `opacity 0`, `y 11px`, `scale 0.94`.
- Menu settles to `opacity 1`, `y 0`, `scale 1`.
- Opening curve reference: `cubic-bezier(.18, .72, .16, 1)` or the closest SwiftUI timing curve.
- Opening duration target: about `240-280ms`.
- Item stagger target: about `35ms` between visible action items.
- Closing should reverse quietly and quickly without a dramatic collapse.
- Menu shadow should be light: closer to `black.opacity(0.035)` with a small radius than the current heavier popout.
- Blur should be removed or kept near zero; the selected visual did not rely on blur.

The menu should feel like it appears from the composer, not like it spins or detaches from it.

Implementation note: the shared motion contract now lives in `ActionMenuSeparationMotion`, while the SwiftUI entry/exit curve is centralized in `ActionMenuSoftStaggerAnimation`. Both Welcome and Chat call the same shared `ActionMenuCapsule` and `ComposerLeadingActionButton`.

### 2. Leading Button Icon

`ComposerLeadingActionButton` remains the shared control for both surfaces. Its open/closed icon state should stop using rotational motion.

Acceptable implementation options:

- Crossfade between SF Symbols `plus` and `xmark`.
- Use a small custom plus/close glyph if a crossfade creates unwanted symbol morphing.

The important rule is behavioral: opening the action menu must not animate through a `90deg` rotation. Voice-active `mic.fill` behavior remains separate and unchanged.

The leading button can still take on a subtle orange tint while expanded, but its scale/glow should be quieter than the current separated treatment.

### 3. Menu Capsule

`ActionMenuCapsule` keeps the same structure:

- File
- Photo
- YouTube
- Voice

The capsule continues to use the existing callbacks and `canPickPhoto` disabling. The visual change is limited to how it enters/exits.

Implementation should prefer refining `ActionMenuSeparationMotion` over adding a parallel motion model. The existing type already centralizes:

- collapsed scale
- source offset
- opening delay step
- closing delay step
- item opacity
- capsule opacity
- capsule blur

For this pass, update those values to match option B and make the tests assert the calmer contract.

### 4. Layout And Hit Testing

The existing reserved top padding can stay. This avoids the menu overlapping the composer row and keeps the current clickable area stable.

When collapsed:

- The capsule remains visually hidden.
- Hit testing stays disabled.
- Accessibility stays hidden.

When expanded:

- The capsule receives hit testing.
- The action buttons are accessible.
- Disabled photo state remains visibly disabled when image attachment slots are full.

### 5. Shared Welcome And Chat Behavior

Both `WelcomeView` and `ChatArea` already use `ComposerLeadingActionButton` and `ActionMenuCapsule`. The implementation should keep that shared path instead of adding two separate versions.

This keeps the first-run Welcome state and the normal chat composer feeling like the same product surface.

## Testing

- Update `ActionMenuSeparationMotionTests` to encode the selected soft-stagger values:
  - default collapsed scale is around `0.94`, not a narrow shelf-style scale;
  - default collapsed offset is around `11`;
  - opening delays increase by about `0.035`;
  - capsule blur is zero or near zero;
  - leading-button glow is lower than the previous separated glow.
- Add or update a source-level regression that `ComposerLeadingActionButton` no longer applies `.rotationEffect` to the menu-expanded state.
- Keep the existing shared-control assertion that both Welcome and Chat composers use `ComposerLeadingActionButton`.
- Run focused `ActionMenuSeparationMotionTests`.
- Run a macOS app build because this changes shared SwiftUI view code.

## Risks

- A pure SF Symbol swap from `plus` to `xmark` may still feel like a jump. If so, use a tiny custom glyph inside `ComposerLeadingActionButton`.
- Over-reducing the shadow can make the capsule feel flat against the composer glass. Keep a minimal shadow or stroke so the surface remains legible.
- The welcome composer has less vertical room than chat history. Keep the existing reserved-height strategy unless visual QA shows a real overlap.
- Too much stagger would slow down repeated file/photo workflows. Keep the stagger short.

## Acceptance Criteria

- Opening the composer action menu no longer rotates the leading button icon.
- The menu opens with the selected B soft-stagger feel: subtle upward settle, modest scale, short item stagger, and light shadow.
- Welcome and normal chat composer use the same motion behavior.
- File, Photo, YouTube, and Voice actions behave as before.
- Focused motion tests pass.
- macOS build passes.
