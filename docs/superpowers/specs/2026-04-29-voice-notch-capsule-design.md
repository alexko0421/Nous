# Voice Notch Capsule Design

**Date:** 2026-04-29 (rev. 2 — incorporates codex review findings)
**Status:** User-approved direction. Five high-risk pre-implementation spikes (§ Spikes) gate the build.
**Branch context:** `alexko0421/quick-action-agents`
**Builds on:** `2026-04-28-app-wide-voice-control-design.md`, `2026-04-28-cinematic-voice-capsule.md`, `2026-04-28-voice-mode-design.md`

## Context

Voice mode is currently shown by `VoiceCapsuleView` (`Sources/Nous/Views/VoiceActionPill.swift`), an in-window Liquid Glass pill that lives inside `ChatArea`. When Alex switches conversations, minimizes, or moves to another app, the voice state disappears from view. Alex wants the capsule to remain visible across context switches by surfacing it from the MacBook notch when Nous is not the focused window — similar in framing to the open-source `vibe-notch` project, but tuned for Nous's voice and identity.

Visual exploration confirmed:

- The notch capsule is the right pattern — across-window persistence outweighs implementation cost.
- The capsule is a continuation of Nous's identity, not a system utility — Liquid Glass, not the black Dynamic Island treatment.

## Product Goal

When voice mode is active and Nous is not the front-most window (and the running Mac has a hardware notch), the same voice state — status, waveform, transcript, pending confirmations — is visible as a Liquid Glass capsule extending from the MacBook notch on the built-in display. When Nous returns to focus, the capsule retracts and the existing in-window placement resumes. **There is exactly one piece of voice state, rendered in one of two locations depending on focus.**

## Non-Goals

- No global hotkey for starting voice mode in Phase 1. Activation remains via the in-app `VoiceModeButton`.
- No fallback rendering on Macs without a hardware notch. Phase 1 targets MacBook Pro (built-in notch display) only. On notch-less screens / setups, behavior is **unchanged from today** (in-window capsule remains the only surface).
- No interactive notch features beyond what voice mode already supports — status, waveform, Confirm / Cancel, Stop. No transcript scroll, no chat-thread switcher, no settings, no Dynamic-Island-style multi-app stacking.
- No menu bar app, no separate process, no daemon. The notch panel is owned by the running Nous app.
- No system-wide voice activation, mouse automation, or AppleScript. Voice scope is unchanged from `app-wide-voice-control-design.md`.

## Refactor Foundation (precedes Phase 1 build)

Codex review surfaced that having `VoiceCapsuleView` and a new mirrored notch view both rendering Confirm / Cancel handlers creates a duplicate-action risk and visual-drift risk. **Before building the notch panel, we extract the shared content.**

```
Sources/Nous/Views/Voice/
├── VoiceCapsuleContent.swift   ← NEW. Pure SwiftUI body: waveform + status + subtitle
│                                  + Confirm/Cancel + Stop. Takes a VoiceCapsuleViewModel.
├── VoiceWaveformBars.swift     ← unchanged
└── VoiceNotchPanelController.swift ← NEW. AppKit NSPanel host.

Sources/Nous/Views/VoiceActionPill.swift
└── VoiceCapsuleView            ← refactored to wrap VoiceCapsuleContent + chrome
└── VoiceModeButton             ← unchanged
```

`VoiceCapsuleContent` is the single source of voice UI. The two surfaces (in-window pill, notch panel) wrap it in chrome only. `VoiceCapsuleView` becomes a thin wrapper that adds the `NativeGlassPanel` background and the corner-radius shape it currently has. The notch surface adds the borderless panel chrome. Action handlers live on the view-model — both wrappers bind to the same instance.

This extraction is **not optional and not deferred**. It is the precondition that makes the rest of the design safe.

## Core Decisions

### 1. Visual: Liquid Glass capsule extending from notch

The capsule's bottom edge is a rounded rectangle (24pt corner radius). The top portion sits behind the hardware notch and is visually masked by the bezel — so the user only sees Liquid Glass extending downward from the bezel boundary. Single material, single tint, no gradient, no black "shoulder", no fake highlight.

#### Native material mapping (CSS terms in mockups → SwiftUI / AppKit)

The visual exploration used CSS for fidelity. Implementation uses native materials. Mapping:

| Mockup (CSS) | Native (SwiftUI / AppKit) |
|---|---|
| `backdrop-filter: blur(28px) saturate(1.7)` | `NSVisualEffectView(material: .hudWindow, blendingMode: .behindWindow)` inside the panel, **or** SwiftUI `.background(.ultraThinMaterial)` if hosting in a SwiftUI panel wrapper |
| `background: rgba(255, 255, 255, 0.42)` (capsule body tint) | `Color.white.opacity(0.42)` overlay on top of the material — `.background { ZStack { material; tint } }` |
| `border: 1px solid rgba(255, 255, 255, 0.55)` | `.overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.55), lineWidth: 1))` |
| `border-radius: 0 0 24px 24px` (no top rounding) | Custom `Shape` returning a path with sharp top corners and 24pt bottom corners. Cannot use `RoundedRectangle` directly. |
| `box-shadow: 0 16px 36px rgba(120, 80, 40, 0.20)` | `.shadow(color: Color(red: 120/255, green: 80/255, blue: 40/255).opacity(0.20), radius: 18, x: 0, y: 16)` |
| `inset 0 -1px 0 rgba(255,255,255,0.6)` (bottom highlight) | Inner highlight via second overlay or omit (low value, costly to render natively) |

Status text colors map to existing `AppColor.colaDarkText` / `AppColor.secondaryText` already used in `VoiceCapsuleView`. The 米啡 (warm-brown) tone is already in `AppColor`.

#### Body content (shared `VoiceCapsuleContent`)

- `VoiceWaveformBars` (27×22pt), accessibility-hidden
- Status title (`status.displayText`) — 14pt semibold rounded
- Subtitle (live transcript / hint) — 12pt medium, `.contentTransition(.interpolate)`. **Truncated at `lineLimit(1)`** with `.truncationMode(.tail)` (existing behavior).
- Action region — Confirm / Cancel (during `needsConfirmation`) **or** Stop button (otherwise)

#### Width cap (codex finding #14)

Total capsule width is capped at **520pt**. Subtitle text continues to use the existing 420pt soft cap. This cap applies to both surfaces. Long transcripts are truncated, not allowed to push the panel toward menu extras.

### 2. Stop button (new control)

A 35pt circular button at the right edge of the capsule.

**Visibility (codex finding #10 fixed):** Stop appears for **`idle` / `listening` / `thinking` / `action` / `error`** — every state except `needsConfirmation`. Stuck states are exactly when the user most needs an escape hatch. During `needsConfirmation`, Confirm and Cancel are the primary actions and Stop is hidden to avoid a third disruptive choice.

Native styling (mapping from mockup):

| Mockup | Native |
|---|---|
| Outer fill `rgba(225, 40, 35, 0.72)` | `Circle().fill(Color(red: 225/255, green: 40/255, blue: 35/255).opacity(0.72))` |
| `backdrop-filter: blur(24px) saturate(1.9)` | A small `NSVisualEffectView(material: .popover)` clipped to a circle inside the SwiftUI hierarchy, **or** `.background(.ultraThinMaterial)` clipped to `Circle()` |
| Border `rgba(255, 110, 100, 0.55)` | `.overlay(Circle().stroke(Color(red: 255/255, green: 110/255, blue: 100/255).opacity(0.55), lineWidth: 1))` |
| Inner square 13×13pt, `rgba(255, 225, 220, 0.95)`, 2.5pt corner | `RoundedRectangle(cornerRadius: 2.5).fill(Color(red: 255/255, green: 225/255, blue: 220/255).opacity(0.95)).frame(width: 13, height: 13)` |
| Hover: outer to `rgba(235, 50, 45, 0.82)` | `.onHover` updates an `@State` color |

**Surface scope:** Stop appears in the notch surface only. The in-window surface continues to use the existing `VoiceModeButton` to start / stop. The shared `VoiceCapsuleContent` view takes a `showsStopButton: Bool` parameter — `true` for notch wrapper, `false` for in-window wrapper.

**Action:** binds to `voiceMode.stop()` — the same exit path as the in-app `VoiceModeButton` toggle.

### 3. Display logic — focus-aware (with idempotent transition)

There is exactly one source of voice state. The shared `VoiceCapsuleContent` is mounted in **at most one** wrapper at any time:

| Voice state | Nous main window state | Mounted surface |
|---|---|---|
| inactive | any | none |
| active | key & active | in-window (`VoiceCapsuleView` in `ChatArea`) |
| active | not key (background, hidden, minimized, fullscreen-other) | notch (`VoiceNotchPanelController`'s panel) |
| active | no notch screen present (clamshell, no MBP) | in-window (no notch fallback Phase 1) |

#### Transition rules (codex finding #6 fixed)

- Surface switch is driven by a `@Published var visibleSurface: Surface { case none, inWindow, notch }` on the view-model. Both wrappers gate their body on `visibleSurface == self.expectedSurface`.
- During the 0.25s out / 0.35s spring-in animation handoff, the leaving wrapper's interactive controls (Confirm / Cancel / Stop) are **disabled** via `.allowsHitTesting(false)`. Only the entering wrapper accepts input.
- Confirmation actions are gated by a `pendingActionToken: UUID?` on the view-model. `confirm()` and `cancel()` no-op if the token they were issued for is no longer current. This means: if a user taps Confirm just as focus changes, only the first dispatch executes. The token is reset on each `needsConfirmation` entry.
- Surface switch only happens when voice state is **not** `needsConfirmation`. If focus changes mid-confirmation, the active surface stays mounted until Confirm / Cancel / Stop resolves the pending action; only then does the surface flip.

This sequence — gated visibility + hit-testing block on the leaving surface + token-based action idempotency + frozen surface during pending confirmation — eliminates the four ways a duplicate fire could happen.

### 4. Click behavior — hybrid

- **Left-click on capsule body** (anywhere outside Stop / Confirm / Cancel) on the notch surface: brings Nous main window to the front (`NSApp.activate(ignoringOtherApps: true)` plus `mainWindow.makeKeyAndOrderFront(nil)`).
- **Left-click on Stop button**: stops voice mode. Capsule retracts. Nous is **not** brought to the front.
- **Left-click on Confirm / Cancel** (during `needsConfirmation`): handlers run via the idempotent token path. Nous is **not** brought to the front.
- **Right-click on capsule body**: deferred to Phase 2 (the inline Stop button covers the primary "stop without returning to Nous" use case).

#### Hit-testing under `.nonactivatingPanel` (codex finding #8)

`.nonactivatingPanel` is set so that mouse-down on Stop / Confirm / Cancel does not steal focus from the user's current app. But left-click on the body **must** activate Nous. This is achieved with explicit `NSEvent.mouseLocation` hit-test in the panel's window subclass, calling `NSApp.activate` only when the click lands outside the action regions. The action regions themselves use SwiftUI `Button { }` — buttons inside `nonactivatingPanel` accept clicks but do not bring the app to front, which is the desired asymmetry. (This requires a Spike — see § Spikes.)

### 5. Voice activation entry — unchanged in Phase 1

Voice mode starts only from the in-app `VoiceModeButton`. No global hotkey. The notch capsule is a *view* of running voice state, not an activation surface. Stop is reachable from anywhere via the notch surface's Stop button.

### 6. Hardware scope — Phase 1 MBP-only

The notch capsule renders only when the running Mac has a built-in display with a hardware notch. On notch-less Macs, no monitors with notches are available, or the laptop is in clamshell mode → notch surface never mounts; in-window surface remains the only voice UI (i.e., behavior unchanged from today).

The exact detection algorithm is a Spike (see § Spikes — `NSScreen.safeAreaInsets` is necessary but the codex review notes it is not sufficient).

### 7. Accessibility (codex finding #9 — explicit trade-off)

Phase 1 carries over `VoiceCapsuleView`'s existing a11y attributes into `VoiceCapsuleContent`. **Trade-off acknowledged:** an `NSPanel` outside the main app window has different VoiceOver behavior than an in-window view. Specifically, VoiceOver users who are not in Nous will not have a natural way to land on the notch surface. For Phase 1 (Alex's private dogfood), this is acceptable. Phase 2 must add: explicit `accessibilityRotorEntries` registration so the notch panel is reachable from anywhere, and a keyboard-only path to Stop / Confirm / Cancel without mouse focus on the panel.

## Spikes (must precede full implementation)

These five questions were originally listed as "open questions for the implementation plan." Codex review correctly flagged that they are **feasibility risks**, not implementation details — answering "wrong" makes the feature not work. Each becomes a small isolated spike (1-3 hours of focused exploration each, in a throwaway branch).

### Spike A — Panel level and z-order against macOS UI

**Question:** What `NSWindow.Level` keeps the capsule above ordinary app windows but below Spotlight, Control Center, system modals, and macOS native menu-bar reveal in fullscreen?

**Plan:** Build a 30-line `NSPanel` with `level = .statusBar`, `.canJoinAllSpaces`, `.fullScreenAuxiliary`. Test against:
- Spotlight (⌘Space) — does our panel sit on top of, beside, or under it?
- Control Center (menu bar click) — z-order check
- Fullscreen Safari + cursor to top edge (menu bar reveals) — does macOS push our panel down or stack it?
- Mission Control / App Exposé — does our panel join the animation or stay frozen?

**Acceptance:** identify the panel level (`.statusBar` / `.popUpMenu` / `.modalPanel` / a custom raw value) that gives "above app windows, below system overlays" without breaking macOS native menu-bar reveal.

### Spike B — Top-clipping technique

**Question:** Does the capsule's top 36pt actually get masked by the hardware notch reliably across:
- macOS 14 (Sonoma) and 15 (Sequoia)
- Built-in display only / built-in + external clones / built-in + external mirrors
- Stage Manager on / off
- Different Dock auto-hide settings
- Display scaling (Retina / `1x` modes)

**Plan:** Try **option (a)** — position panel so top 36pt is above the visible safe area; let macOS clip. Try **option (b)** — fit panel within visible area; rely on bezel hardware to mask the top of the rendered view by computing exact notch bounds via `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`. Compare both visually and for cursor / hit-test edge cases.

**Acceptance:** one of the two techniques is robust on every config above. If neither is, document the failure modes; we may have to redesign the visual to not rely on bezel masking.

### Spike C — Notch detection and screen selection

**Question:** Given the user may have multiple displays, how do we **reliably** identify the built-in notch display and re-target when the user closes the lid (clamshell) or attaches / detaches monitors?

**Plan:** Combine signals — `NSScreen.safeAreaInsets.top > 0`, `NSScreen.localizedName` contains "Built-in", `CGDisplayIsBuiltin(displayID)` via Core Graphics. Subscribe to `NSApplication.didChangeScreenParametersNotification`. Test attach / detach, lid-close, switching between built-in and external as primary.

**Acceptance:** a single `currentNotchScreen() -> NSScreen?` function that returns the correct screen on every configuration tested, and a notification-driven update path for runtime changes.

### Spike D — Focus signal that captures product intent

**Question:** What signal precisely captures "Nous main window is the user's active workspace" vs "Nous is in the background"? Test cases:
- Nous main window key & active → in-window
- Nous main window key but Settings sheet on top → in-window
- Nous in background, hidden via ⌘H → notch
- Nous main window minimized to Dock → notch
- Nous main window in fullscreen Space, user switches Space → notch
- User Cmd-Tab through apps; Nous flashes through key state → no flicker

**Plan:** Compare `NSApp.isActive` vs `mainWindow.isKeyWindow` vs `NSWorkspace.shared.frontmostApplication == .current`. Wire each signal to a logger across the test cases. Pick the signal (or combination) that matches intent without flickering during Cmd-Tab.

**Acceptance:** a documented `mainWindowFocus.isKey: Bool` published value driven by the chosen signal, with a debounce strategy if needed.

### Spike E — Confirmation idempotency under rapid focus change

**Question:** When focus flips rapidly during pending confirmation, does the token-gated `confirm()` / `cancel()` actually prevent double-fire?

**Plan:** Build the view-model + token logic. Write a test that issues `needsConfirmation`, then alternates focus rapidly while a synthetic Confirm tap fires. Assert exactly one dispatch.

**Acceptance:** automated test passes; manual repro confirms no double-send in real Realtime session.

## Phase 1 Scope

In scope (after Spikes pass):

1. Refactor: extract `VoiceCapsuleContent`. `VoiceCapsuleView` becomes wrapper.
2. `VoiceNotchPanelController` (AppKit) hosting the panel anchored under the notch.
3. View-model additions: `visibleSurface`, `pendingActionToken`, focus subscription.
4. Surface-switch animation with hit-testing block on leaving surface.
5. Stop button visible in `idle` / `listening` / `thinking` / `action` / `error`.
6. Notch detection gating; notch-less Macs unchanged.
7. Width cap (520pt total, 420pt subtitle).
8. Manual QA pass (see § Manual QA Test Plan).

Explicitly out of scope (deferred to Phase 2):

- Right-click context menu on the notch surface.
- Notch-less Mac fallback rendering (e.g., a floating-pill variant for external displays).
- Global hotkey for voice activation.
- Multi-monitor "follow active screen" behavior.
- Animation refinements beyond the existing capsule's spring values.
- Full a11y audit (rotor entries, keyboard-only path) — see § 7.

## Manual QA Test Plan (codex finding #15)

Before merging Phase 1, manually verify each of these on the dogfood device:

### Surface switching
- [ ] Voice mode starts in Nous → in-window capsule shows; ⌘H hides Nous → notch capsule appears within 0.5s.
- [ ] Click notch capsule body → Nous comes to front, in-window capsule appears, notch retracts.
- [ ] Cmd-Tab rapidly between Nous and another app for 5 seconds → no flicker, no duplicate capsules, no console errors.
- [ ] Voice mode active, Nous main window minimized to Dock → notch capsule shows.
- [ ] Voice mode active, Nous in fullscreen Space, user switches Space → notch capsule on previous Space's screen, in-window resumes when returning.

### Confirmation idempotency
- [ ] Trigger `needsConfirmation`. Tap Confirm exactly as ⌘H fires → exactly one action dispatched (verify in logs).
- [ ] Trigger `needsConfirmation`. Tap Cancel rapidly 3 times → exactly one cancel.
- [ ] Trigger `needsConfirmation`. Cmd-Tab away during the pending state → in-window stays mounted (frozen surface during pending), capsule still shows Confirm / Cancel.

### Hardware / display
- [ ] Single MBP display (notch) → notch capsule on built-in.
- [ ] MBP closed (clamshell) + external monitor → no notch capsule; in-window capsule persists when Nous unfocused (no fallback).
- [ ] MBP + external monitor as primary → notch capsule on the MBP, regardless of which screen has the cursor.
- [ ] Plug / unplug external monitor while voice mode active → no crash, capsule retargets correctly.

### macOS UI z-order
- [ ] Notch capsule visible. Open Spotlight (⌘Space) → Spotlight on top, our capsule under it (or visible alongside without obscuring).
- [ ] Notch capsule visible. Click menu bar to open Control Center → Control Center on top.
- [ ] Notch capsule visible in Safari fullscreen. Cursor to top edge → macOS reveals menu bar; our capsule does not block menu bar interaction.
- [ ] Notch capsule visible. Trigger Mission Control (F3) → behavior is acceptable (either joins animation or hides, not stuck-on-top).

### Stop button coverage
- [ ] Stop button visible and functional in `idle`, `listening`, `thinking`, `action`, `error`.
- [ ] Stop button hidden in `needsConfirmation` (Confirm / Cancel only).
- [ ] Click Stop → voice mode ends; Nous does not come to front.

### Visual polish
- [ ] Capsule top edge meets bezel cleanly (no visible gap, no double-shadow).
- [ ] Liquid Glass material picks up wallpaper colors visibly.
- [ ] Stop button red is recognizable, not too dim.
- [ ] Long transcript truncates with ellipsis at 420pt, total capsule never exceeds 520pt.

## Success Criteria (codex finding #11 — overclaim removed)

- **On Macs with a hardware notch**, when voice mode is active, the capsule is always visible — either in-window or under the notch.
- The notch capsule looks like a piece of Nous, not a system utility.
- Click on the notch capsule body returns to Nous in one gesture.
- Stop button on the notch capsule ends voice mode without forcing Alex to switch apps.
- On notch-less screens / clamshell / external-only setups, voice behavior is **unchanged from today** — the in-window capsule is the only surface, with the same visibility limitations as today (i.e., not visible when Nous is unfocused). This is the explicit Phase 1 trade-off.
- Confirmation actions execute exactly once even under rapid focus change.

## Codex Review Disposition

This rev addresses the codex review findings as follows:

| # | Finding | Disposition |
|---|---|---|
| 1 | Spec ready while deferring core feasibility | **Fixed** — § Spikes elevates the 5 risks to gated pre-implementation work. |
| 2 | `.statusBar` panel level under-specified | **Spike A** |
| 3 | Top-36pt-behind-bezel trick fragile | **Spike B** |
| 4 | Notch detection naïve | **Spike C** |
| 5 | `VoiceCapsuleView` "unchanged" contradicts focus-aware hide | **Fixed** — § Refactor Foundation extracts shared content; both wrappers gate on `visibleSurface`. |
| 6 | Focus transitions can double-fire confirm | **Fixed** — § 3 transition rules: gated visibility + hit-testing block + token idempotency + frozen surface during pending. **Spike E** verifies. |
| 7 | Focus binary too coarse | **Spike D** |
| 8 | Click behavior conflicts with `nonactivatingPanel` | **Fixed in design** (§ 4 hit-testing) + verified in **Spike A**. |
| 9 | A11y deferred without acknowledgment | **Fixed** — § 7 makes the trade-off explicit; Phase 2 must address. |
| 10 | Stop missing from `thinking` / `action` / `error` | **Fixed** — § 2 visibility now covers all active states except `needsConfirmation`. |
| 11 | Success criterion overclaim | **Fixed** — § Success Criteria scoped to notch screens; explicit unchanged-behavior on notch-less. |
| 12 | CSS terms in native spec | **Fixed** — § 1 native material mapping table. |
| 13 | Two mirrored views invite drift | **Fixed** — § Refactor Foundation extracts `VoiceCapsuleContent`. |
| 14 | Width growth dangerous near notch | **Fixed** — § 1 width cap (520pt total). |
| 15 | No test plan | **Fixed** — § Manual QA Test Plan. |
