# Voice Notch Capsule Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface voice mode at the MacBook notch as a Liquid Glass capsule when Nous is unfocused, while keeping the in-window capsule when Nous is focused — using a single shared SwiftUI view and idempotent action handlers to prevent double-fires during focus changes.

**Architecture:** Extract `VoiceCapsuleContent` as the shared SwiftUI body. `VoiceCapsuleView` (in-window) and `VoiceNotchPanelController` (notch `NSPanel` host) both wrap the same content. `VoiceCommandController` gains a `visibleSurface` enum and a `pendingActionToken` UUID; both wrappers gate their body on `visibleSurface == self.expectedSurface`, and confirm/cancel handlers no-op if the issued token is stale. Phase 0 spikes verify five high-risk behaviors (panel z-order, top-clipping technique, notch detection, focus signal, idempotency) before the build phases proceed.

**Tech Stack:** SwiftUI + AppKit (`NSPanel`, `NSVisualEffectView`, `NSScreen`), Swift Observation framework (`@Observable`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-04-29-voice-notch-capsule-design.md`

---

## File Structure

**New files:**
- `Sources/Nous/Views/Voice/VoiceCapsuleContent.swift` — shared SwiftUI body (waveform + status + subtitle + Confirm/Cancel + optional Stop). Pure rendering, no state ownership.
- `Sources/Nous/Views/Voice/VoiceNotchPanelController.swift` — AppKit `NSPanel` host. Owns the panel lifecycle, frame positioning, and focus observation.
- `Sources/Nous/Views/Voice/VoiceMainWindowFocusObserver.swift` — small helper that publishes "Nous main window is the user's active workspace" as a `@Published Bool` to the controller. Implementation chosen by Spike D.
- `Sources/Nous/Views/Voice/NotchScreenDetection.swift` — `currentNotchScreen() -> NSScreen?` helper. Implementation chosen by Spike C.
- `Tests/NousTests/VoiceCommandControllerIdempotencyTests.swift` — token-gated confirm/cancel tests (Spike E + Phase 2).
- `docs/superpowers/spikes/2026-04-29-spike-{a,b,c,d,e}-*.md` — five spike findings reports.

**Modified files:**
- `Sources/Nous/Views/VoiceActionPill.swift` — `VoiceCapsuleView` becomes a thin wrapper around `VoiceCapsuleContent` with the in-window `NativeGlassPanel` chrome. `VoiceModeButton` unchanged.
- `Sources/Nous/Services/VoiceCommandController.swift` — adds `visibleSurface: Surface`, `pendingActionToken: UUID?`, token-checked `confirmPendingAction()` / `cancelPendingAction()`, and a focus subscription wired to `NotchScreenDetection` + `VoiceMainWindowFocusObserver`.
- `Sources/Nous/Models/Voice/VoiceModeModels.swift` — adds `enum VoiceCapsuleSurface { case none, inWindow, notch }`.
- `Sources/Nous/Views/ChatArea.swift` — gates `VoiceCapsuleView` mount on `voiceController.visibleSurface == .inWindow`. Notch panel mount/unmount is driven by `VoiceNotchPanelController` listening to the same surface signal; not directly visible in `ChatArea`.
- `Sources/Nous/App/NousApp.swift` (or whichever file owns `VoiceCommandController` lifecycle) — instantiates `VoiceNotchPanelController` and starts the focus observer.

**Cleanup:** Spike scratch code in `Sources/Nous/Views/Voice/Spikes/` is deleted at the end of Phase 1 (Task 1.5).

---

## Phase 0 — Spikes

**Each spike is a 1-3 hour exploration.** Each produces a markdown report under `docs/superpowers/spikes/`. If a spike fails, it must be resolved (redesign or alternate approach) before its dependent build phase begins. Spike code lives temporarily in `Sources/Nous/Views/Voice/Spikes/` and is removed in Task 1.5.

### Task 0.A — Spike A: Panel level + z-order

**Files:**
- Create: `Sources/Nous/Views/Voice/Spikes/PanelLevelSpike.swift`
- Create: `docs/superpowers/spikes/2026-04-29-spike-a-panel-level.md`

- [ ] **Step 1: Build a minimal sample panel**

```swift
// Sources/Nous/Views/Voice/Spikes/PanelLevelSpike.swift
import AppKit
import SwiftUI

@MainActor
final class PanelLevelSpike {
    private var panel: NSPanel?

    func show(level: NSWindow.Level, label: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = NSColor(white: 0, alpha: 0.85)
        panel.hasShadow = false

        let host = NSHostingView(rootView:
            Text(label)
                .foregroundColor(.white)
                .padding()
        )
        panel.contentView = host

        if let screen = NSScreen.main {
            let frame = NSRect(
                x: screen.frame.midX - 160,
                y: screen.frame.maxY - 100,
                width: 320,
                height: 80
            )
            panel.setFrame(frame, display: true)
        }
        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
```

- [ ] **Step 2: Wire into a temporary debug menu**

Add a `#if DEBUG` toggle in `Sources/Nous/App/NousApp.swift` that instantiates `PanelLevelSpike` and shows it on a developer menu item. (Exact wiring depends on app structure — match existing debug toggles if any.)

- [ ] **Step 3: Test each level against macOS UI**

Run the app. For each of these levels, show the panel and tick off the matrix:

| Level | Above app windows? | Below Spotlight? | Below Control Center? | Doesn't block fullscreen menu reveal? | Behaves in Mission Control? |
|---|---|---|---|---|---|
| `.normal` | ☐ | ☐ | ☐ | ☐ | ☐ |
| `.floating` | ☐ | ☐ | ☐ | ☐ | ☐ |
| `.statusBar` | ☐ | ☐ | ☐ | ☐ | ☐ |
| `.popUpMenu` | ☐ | ☐ | ☐ | ☐ | ☐ |
| `.modalPanel` | ☐ | ☐ | ☐ | ☐ | ☐ |

Test cases:
1. Panel visible. Open Spotlight (⌘Space). Spotlight should be **on top of** our panel.
2. Click menu bar to open Control Center. Control Center should be on top.
3. Open Safari fullscreen. Move cursor to top edge — macOS reveals menu bar. Our panel should not block menu bar interaction.
4. Trigger Mission Control (F3). Panel should not be stuck on top of the Mission Control view.
5. Open a system modal (e.g., Save dialog from any app). Modal should be on top.

- [ ] **Step 4: Write findings report**

```markdown
# Spike A — Panel Level + Z-Order

**Date:** 2026-04-29
**Status:** [PASS / FAIL / DEGRADED]
**Decision:** Use `NSWindow.Level.<chosen>` for the notch panel.

## Test matrix
[paste the filled-in matrix]

## Edge cases discovered
[bullet list]

## Decision rationale
[1-2 paragraphs]
```

Save to `docs/superpowers/spikes/2026-04-29-spike-a-panel-level.md`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/Voice/Spikes/PanelLevelSpike.swift docs/superpowers/spikes/2026-04-29-spike-a-panel-level.md
git commit -m "spike(voice): panel level + z-order findings"
```

---

### Task 0.B — Spike B: Top-clipping technique

**Files:**
- Modify: `Sources/Nous/Views/Voice/Spikes/PanelLevelSpike.swift` (extend with shape + position variants)
- Create: `docs/superpowers/spikes/2026-04-29-spike-b-top-clipping.md`

- [ ] **Step 1: Implement option (a) — position panel above visible area**

Extend `PanelLevelSpike` with a method that draws a 360pt-wide capsule (24pt bottom radius, sharp top corners) and positions the panel so its top edge is **36pt above** the visible safe area. The hardware notch should mask the top.

```swift
func showOptionA() {
    // ... existing setup ...
    if let screen = NSScreen.main {
        // Position so top 36pt is in the bezel area (above safe area)
        let safeTopY = screen.frame.maxY - screen.safeAreaInsets.top
        let frame = NSRect(
            x: screen.frame.midX - 180,
            y: safeTopY - 64, // capsule body 100pt; 36pt sits above safe area
            width: 360,
            height: 100
        )
        panel.setFrame(frame, display: true)
    }
}
```

- [ ] **Step 2: Implement option (b) — fit within safe area, rely on bezel mask**

Position the panel entirely within visible area but anchored under the notch using `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` to compute notch bounds.

```swift
func showOptionB() {
    // ... existing setup ...
    if let screen = NSScreen.main, let aux = screen.auxiliaryTopLeftArea {
        // The notch is between auxiliaryTopLeftArea.maxX and auxiliaryTopRightArea.minX
        // Capsule body fits below the bezel
        let safeTopY = screen.frame.maxY - screen.safeAreaInsets.top
        let frame = NSRect(
            x: screen.frame.midX - 180,
            y: safeTopY - 100,
            width: 360,
            height: 100
        )
        panel.setFrame(frame, display: true)
    }
}
```

- [ ] **Step 3: Test both options across configs**

For each config, render with both options and visually inspect:

Configs:
1. Built-in MBP display only.
2. Built-in + external mirror (System Settings > Displays > Mirror).
3. Built-in + external extended (different positions for external — to left, right, above).
4. Stage Manager on / off.
5. Dock auto-hide on / off.
6. macOS 14 (Sonoma) and 15 (Sequoia) if both available.
7. Display scaling — Retina vs. 1x mode.

For each: does the top portion mask cleanly? Are there gaps? Cursor / hit-test edge cases?

- [ ] **Step 4: Write findings report**

```markdown
# Spike B — Top Clipping Technique

**Date:** 2026-04-29
**Status:** [PASS / FAIL / DEGRADED]
**Decision:** Use option [(a) / (b)] for top clipping.

## Test matrix
[per-config results for both options]

## Failure modes
[bullet list]

## Implementation notes for Phase 4
[1-2 paragraphs of guidance for the panel positioning code]
```

Save to `docs/superpowers/spikes/2026-04-29-spike-b-top-clipping.md`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/Voice/Spikes/PanelLevelSpike.swift docs/superpowers/spikes/2026-04-29-spike-b-top-clipping.md
git commit -m "spike(voice): top-clipping technique findings"
```

---

### Task 0.C — Spike C: Notch detection + screen selection

**Files:**
- Create: `Sources/Nous/Views/Voice/Spikes/NotchDetectionSpike.swift`
- Create: `docs/superpowers/spikes/2026-04-29-spike-c-notch-detection.md`

- [ ] **Step 1: Implement detection function**

```swift
// Sources/Nous/Views/Voice/Spikes/NotchDetectionSpike.swift
import AppKit
import CoreGraphics

@MainActor
enum NotchDetectionSpike {
    /// Returns the built-in notch display, or nil if there isn't one.
    static func currentNotchScreen() -> NSScreen? {
        for screen in NSScreen.screens {
            // Signal 1: safe area inset > 0 indicates notch on macOS 12+
            let hasNotchSafeArea = screen.safeAreaInsets.top > 0

            // Signal 2: localized name contains "Built-in"
            let isBuiltInName = screen.localizedName.contains("Built-in")

            // Signal 3: CGDisplayIsBuiltin
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let isBuiltInCG = displayID != 0 && CGDisplayIsBuiltin(displayID) != 0

            if hasNotchSafeArea && (isBuiltInName || isBuiltInCG) {
                return screen
            }
        }
        return nil
    }

    static func logAllScreens() {
        for screen in NSScreen.screens {
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            print("""
            screen: \(screen.localizedName)
              displayID: \(displayID)
              isBuiltIn: \(displayID != 0 && CGDisplayIsBuiltin(displayID) != 0)
              safeAreaTop: \(screen.safeAreaInsets.top)
              frame: \(screen.frame)
            """)
        }
    }
}
```

- [ ] **Step 2: Test on every config**

Run `logAllScreens()` and `currentNotchScreen()` for each:
1. Built-in MBP only.
2. Clamshell + external (lid closed).
3. Built-in + external extended.
4. Lid open / close while running.
5. Plug / unplug external monitor while running.

For 4 and 5, also subscribe to `NSApplication.didChangeScreenParametersNotification` and re-call `currentNotchScreen()`. Verify the result updates correctly.

- [ ] **Step 3: Write findings report**

```markdown
# Spike C — Notch Detection + Screen Selection

**Date:** 2026-04-29
**Status:** [PASS / FAIL / DEGRADED]
**Decision:** Use signal combination [hasNotchSafeArea AND (isBuiltInName OR isBuiltInCG)].

## Per-config results
[table: config → expected screen → actual screen]

## Notification-driven update timing
[ms latency between attach/detach and updated value]

## Implementation notes for Phase 4
[guidance — does the function need a debounce? how to handle nil?]
```

Save to `docs/superpowers/spikes/2026-04-29-spike-c-notch-detection.md`.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Views/Voice/Spikes/NotchDetectionSpike.swift docs/superpowers/spikes/2026-04-29-spike-c-notch-detection.md
git commit -m "spike(voice): notch detection findings"
```

---

### Task 0.D — Spike D: Focus signal

**Files:**
- Create: `Sources/Nous/Views/Voice/Spikes/FocusSignalSpike.swift`
- Create: `docs/superpowers/spikes/2026-04-29-spike-d-focus-signal.md`

- [ ] **Step 1: Implement a focus signal logger**

```swift
// Sources/Nous/Views/Voice/Spikes/FocusSignalSpike.swift
import AppKit

@MainActor
final class FocusSignalSpike {
    func startLogging() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            self.snapshot("didBecomeActive")
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            self.snapshot("didResignActive")
        }
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            self.snapshot("didBecomeKey")
        }
        nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { _ in
            self.snapshot("didResignKey")
        }
        nc.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { _ in
            self.snapshot("didHide")
        }
        nc.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { _ in
            self.snapshot("didUnhide")
        }
    }

    private func snapshot(_ trigger: String) {
        let appActive = NSApp.isActive
        let mainWindow = NSApp.mainWindow
        let mainKey = mainWindow?.isKeyWindow ?? false
        let mainMiniaturized = mainWindow?.isMiniaturized ?? false
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        print("""
        [\(trigger)] appActive=\(appActive) mainKey=\(mainKey) miniaturized=\(mainMiniaturized) frontmost=\(frontmost)
        """)
    }
}
```

- [ ] **Step 2: Run through every product test case**

For each test case in spec § Spike D, trigger the action and capture the log:

1. Nous main window key & active → expect: appActive=true, mainKey=true.
2. Nous main window key + Settings sheet on top → expect: appActive=true, mainKey=true (Settings is not main).
3. Nous in background, ⌘H → expect: appActive=false.
4. Nous main window minimized to Dock → expect: appActive=true (Nous still has menu bar) but mainKey=false, miniaturized=true.
5. Nous main window in fullscreen Space, switch Space → expect: appActive=false momentarily.
6. Cmd-Tab through apps for 5s → expect: rapid alternation; need debounce decision.

- [ ] **Step 3: Pick the signal**

Document which combination of signals matches "Nous main window is the user's active workspace":
- Likely: `mainWindow?.isKeyWindow == true && !mainWindow.isMiniaturized && NSApp.isActive`.
- Decide debounce window (probably 100-150ms during Cmd-Tab) to avoid surface flicker.

- [ ] **Step 4: Write findings report**

```markdown
# Spike D — Focus Signal

**Date:** 2026-04-29
**Status:** [PASS / FAIL / DEGRADED]
**Decision:** `mainWindowFocus.isKey = <expression>`, with <Xms> debounce.

## Per-test-case logs
[paste the captured logs]

## Chosen signal expression
[exact code]

## Debounce strategy
[debounce window + rationale]
```

Save to `docs/superpowers/spikes/2026-04-29-spike-d-focus-signal.md`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/Voice/Spikes/FocusSignalSpike.swift docs/superpowers/spikes/2026-04-29-spike-d-focus-signal.md
git commit -m "spike(voice): focus signal findings"
```

---

### Task 0.E — Spike E: Confirmation idempotency (TDD)

**Files:**
- Create: `Tests/NousTests/VoiceCommandControllerIdempotencyTests.swift`
- Create: `docs/superpowers/spikes/2026-04-29-spike-e-idempotency.md`

This spike is implemented as failing tests first; the production code lands in Task 2.3.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/NousTests/VoiceCommandControllerIdempotencyTests.swift
import Testing
@testable import Nous

@MainActor
@Suite("VoiceCommandController confirmation idempotency")
struct VoiceCommandControllerIdempotencyTests {

    @Test("Confirm only fires the handler once even if called twice with the same token")
    func confirmFiresOnce() async throws {
        var sendCount = 0
        let controller = VoiceCommandController()
        controller.configure(.empty.with(sendMessage: { _ in sendCount += 1 }))

        controller.pendingAction = .sendMessage(text: "hello")
        controller.status = .needsConfirmation("Send 'hello'?")
        // Phase 2.2 will add: controller.pendingActionToken = UUID()

        controller.confirmPendingAction()
        controller.confirmPendingAction() // second call should no-op

        #expect(sendCount == 1)
    }

    @Test("Confirm called after surface switch (token reset) does not fire")
    func staleConfirmDoesNotFire() async throws {
        var sendCount = 0
        let controller = VoiceCommandController()
        controller.configure(.empty.with(sendMessage: { _ in sendCount += 1 }))

        controller.pendingAction = .sendMessage(text: "hello")
        controller.status = .needsConfirmation("Send 'hello'?")
        // Capture stale token
        let staleToken = controller.pendingActionToken

        // Simulate surface flip clearing token
        controller.pendingAction = nil
        controller.pendingActionToken = nil

        // Stale confirm fires (e.g. button on leaving surface mid-animation)
        controller.confirmWithToken(staleToken)

        #expect(sendCount == 0)
    }

    @Test("Cancel only fires once")
    func cancelFiresOnce() async throws {
        var cancelCount = 0
        let controller = VoiceCommandController()
        // VoicePendingAction has no observable cancel handler; instead assert pendingAction transitions
        controller.pendingAction = .sendMessage(text: "hi")
        controller.status = .needsConfirmation("Send 'hi'?")

        controller.cancelPendingAction()
        let firstCancelStatus = controller.status
        controller.cancelPendingAction() // no-op

        #expect(controller.pendingAction == nil)
        #expect(firstCancelStatus == .listening || firstCancelStatus == .idle)
        // Track via additional handler if needed
    }
}

// Test helper extension. Adapt to the actual VoiceActionHandlers shape.
extension VoiceActionHandlers {
    func with(sendMessage: @escaping (String) -> Void) -> VoiceActionHandlers {
        var copy = self
        copy.sendMessage = sendMessage
        return copy
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter VoiceCommandControllerIdempotencyTests`
Expected: FAIL — `pendingActionToken` and `confirmWithToken` do not exist yet. Compile error is fine; the spike is the *test design*, the implementation lands in Phase 2.

- [ ] **Step 3: Write the spike report**

```markdown
# Spike E — Confirmation Idempotency

**Date:** 2026-04-29
**Status:** Tests authored, currently failing (compile error). Implementation in Phase 2.3.

## Test design
[summary of the three test cases]

## Implementation contract (for Phase 2.3)
- `pendingActionToken: UUID?` on `VoiceCommandController`
- Issue a new token whenever entering `needsConfirmation`
- Reset to `nil` whenever leaving `needsConfirmation` (including via stop())
- `confirmPendingAction()` no-ops if `pendingActionToken == nil`
- `cancelPendingAction()` is similarly idempotent
- Both surfaces' Confirm/Cancel buttons share the same handler path

## Decision
Token-gated approach is the chosen strategy.
```

Save to `docs/superpowers/spikes/2026-04-29-spike-e-idempotency.md`.

- [ ] **Step 4: Commit**

```bash
git add Tests/NousTests/VoiceCommandControllerIdempotencyTests.swift docs/superpowers/spikes/2026-04-29-spike-e-idempotency.md
git commit -m "spike(voice): confirmation idempotency tests + report"
```

---

## Phase 1 — Refactor Foundation

### Task 1.1 — Extract `VoiceCapsuleContent`

**Files:**
- Create: `Sources/Nous/Views/Voice/VoiceCapsuleContent.swift`

- [ ] **Step 1: Write the new shared view**

```swift
// Sources/Nous/Views/Voice/VoiceCapsuleContent.swift
import SwiftUI

/// Shared body of the voice capsule. Used by both `VoiceCapsuleView` (in-window)
/// and `VoiceNotchPanelController` (notch panel). Owns no state; consumers wrap
/// it in chrome and pass behavior in.
struct VoiceCapsuleContent: View {
    let status: VoiceModeStatus
    let subtitleText: String
    let audioLevel: Float
    let hasPendingConfirmation: Bool
    let showsStopButton: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onStop: () -> Void

    private var barState: VoiceWaveformBars.BarState {
        switch status {
        case .listening:                        return .listening
        case .thinking:                         return .thinking
        case .error:                            return .error
        case .idle, .action, .needsConfirmation: return .idle
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            VoiceWaveformBars(level: audioLevel, state: barState)
                .frame(width: 27, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.displayText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppColor.colaDarkText)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
                    .animation(.easeOut(duration: 0.15), value: status.displayText)

                if !subtitleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(subtitleText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(AppColor.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.interpolate)
                        .animation(.easeOut(duration: 0.12), value: subtitleText)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)

            if hasPendingConfirmation {
                HStack(spacing: 8) {
                    Button("Confirm", action: onConfirm)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColor.colaOrange)

                    Button("Cancel", action: onCancel)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColor.secondaryText)
                }
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else if showsStopButton && shouldShowStopForStatus {
                StopButton(onTap: onStop)
                    .padding(.leading, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(maxWidth: 520) // Total capsule width cap (codex finding #14)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: status.displayText)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: subtitleText)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: hasPendingConfirmation)
    }

    private var shouldShowStopForStatus: Bool {
        // Stop covers all active states except needsConfirmation (codex #10)
        switch status {
        case .idle, .listening, .thinking, .action, .error: return true
        case .needsConfirmation: return false
        }
    }
}

private struct StopButton: View {
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(outerColor)
                    .background(.ultraThinMaterial, in: Circle())

                Circle()
                    .stroke(borderColor, lineWidth: 1)

                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color(red: 255/255, green: 225/255, blue: 220/255).opacity(0.95))
                    .frame(width: 13, height: 13)
            }
            .frame(width: 35, height: 35)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Stop voice mode")
        .accessibilityLabel("Stop voice mode")
    }

    private var outerColor: Color {
        let red = isHovering ? 235.0 : 225.0
        let green = isHovering ? 50.0 : 40.0
        let blue = isHovering ? 45.0 : 35.0
        let alpha = isHovering ? 0.82 : 0.72
        return Color(red: red/255, green: green/255, blue: blue/255).opacity(alpha)
    }

    private var borderColor: Color {
        let alpha = isHovering ? 0.65 : 0.55
        let r = isHovering ? 130.0 : 110.0
        let g = isHovering ? 120.0 : 100.0
        return Color(red: 255/255, green: r/255, blue: g/255).opacity(alpha)
    }
}
```

- [ ] **Step 2: Compile to verify it builds**

Run: `swift build`
Expected: clean build (warnings about unused view are acceptable until Task 1.2 wires it in).

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Views/Voice/VoiceCapsuleContent.swift
git commit -m "feat(voice): extract VoiceCapsuleContent shared view"
```

---

### Task 1.2 — Refactor `VoiceCapsuleView` to wrap `VoiceCapsuleContent`

**Files:**
- Modify: `Sources/Nous/Views/VoiceActionPill.swift`

- [ ] **Step 1: Replace `VoiceCapsuleView`'s body with a wrapper**

Replace the entire `VoiceCapsuleView` struct in `Sources/Nous/Views/VoiceActionPill.swift:4-76` with:

```swift
struct VoiceCapsuleView: View {
    let status: VoiceModeStatus
    let subtitleText: String
    let audioLevel: Float
    let hasPendingConfirmation: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VoiceCapsuleContent(
            status: status,
            subtitleText: subtitleText,
            audioLevel: audioLevel,
            hasPendingConfirmation: hasPendingConfirmation,
            showsStopButton: false, // in-window relies on VoiceModeButton for start/stop
            onConfirm: onConfirm,
            onCancel: onCancel,
            onStop: {} // no-op; not shown in-window
        )
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            NativeGlassPanel(cornerRadius: 24, tintColor: AppColor.glassTint) { EmptyView() }
                .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
        )
        .overlay(
            Capsule()
                .stroke(AppColor.panelStroke.opacity(0.6), lineWidth: 1)
        )
    }
}
```

`VoiceModeButton` below it stays unchanged.

- [ ] **Step 2: Build and run the app**

Run: `swift build && open .build/debug/Nous.app` (or use Xcode build → run). Trigger voice mode. Verify:
- Capsule looks identical to before (same NativeGlassPanel, same colaOrange Confirm, same secondary Cancel).
- Waveform animates the same way.
- Subtitle truncates the same way.
- Confirm and Cancel still work.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Views/VoiceActionPill.swift
git commit -m "refactor(voice): VoiceCapsuleView wraps VoiceCapsuleContent"
```

---

### Task 1.3 — Add `VoiceCapsuleSurface` enum

**Files:**
- Modify: `Sources/Nous/Models/Voice/VoiceModeModels.swift`

- [ ] **Step 1: Append the enum**

Add to the bottom of `VoiceModeModels.swift`:

```swift
enum VoiceCapsuleSurface: Equatable {
    case none
    case inWindow
    case notch
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Models/Voice/VoiceModeModels.swift
git commit -m "feat(voice): add VoiceCapsuleSurface enum"
```

---

### Task 1.4 — Manual smoke test of refactor

- [ ] **Step 1: Run the app and verify no regression**

Manual checklist:
- [ ] Voice mode starts via mic button — capsule appears in-window.
- [ ] Capsule shows Listening / Thinking / Action / NeedsConfirmation transitions.
- [ ] Confirm / Cancel still execute.
- [ ] Subtitle live transcript updates and truncates.
- [ ] Waveform animates.
- [ ] Voice mode stops via mic button — capsule disappears.

- [ ] **Step 2: If anything regressed, fix and commit**

If a regression is found, write a regression test in `Tests/NousTests/` reproducing it, fix `VoiceCapsuleContent` or `VoiceCapsuleView`, run all tests until green, and commit:

```bash
git commit -m "fix(voice): <what regressed and how it was fixed>"
```

---

### Task 1.5 — Clean up Phase 0 spike scratch code

**Files:**
- Delete: `Sources/Nous/Views/Voice/Spikes/`

The spike findings live in `docs/superpowers/spikes/`. The scratch Swift code in `Sources/Nous/Views/Voice/Spikes/` is no longer needed — Phase 1+ uses the *findings*, not the spike code. (If a spike produced code worth keeping, copy the relevant snippets into the appropriate Phase 4/5 files first.)

- [ ] **Step 1: Salvage anything reusable**

For each spike Swift file under `Sources/Nous/Views/Voice/Spikes/`, check if any function would be reused verbatim in Phase 4. If yes, copy it into the destination file (e.g., `NotchScreenDetection.swift`). If no, skip.

- [ ] **Step 2: Delete the directory**

Run:
```bash
rm -rf Sources/Nous/Views/Voice/Spikes/
```

Also remove any debug menu wiring added during Spike A (search for `PanelLevelSpike` / `FocusSignalSpike` / `NotchDetectionSpike` references in `Sources/Nous/App/`).

- [ ] **Step 3: Verify build still clean**

Run: `swift build && swift test`
Expected: clean build, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add -u Sources/Nous/
git commit -m "chore(voice): remove Phase 0 spike scratch code"
```

---

## Phase 2 — View-model state for surface switching + idempotency

### Task 2.1 — Add `visibleSurface` to `VoiceCommandController`

**Files:**
- Modify: `Sources/Nous/Services/VoiceCommandController.swift`

- [ ] **Step 1: Add the property**

In `VoiceCommandController.swift`, add a new published property near the top of the class (after `audioLevel`):

```swift
var visibleSurface: VoiceCapsuleSurface = .none
```

- [ ] **Step 2: Reset on stop**

In `func stop()` at line 84, after `isActive = false` add:
```swift
visibleSurface = .none
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Services/VoiceCommandController.swift
git commit -m "feat(voice): add visibleSurface to controller"
```

---

### Task 2.2 — Add `pendingActionToken` to `VoiceCommandController`

**Files:**
- Modify: `Sources/Nous/Services/VoiceCommandController.swift`

- [ ] **Step 1: Add the token property**

After `visibleSurface`:

```swift
var pendingActionToken: UUID?
```

- [ ] **Step 2: Issue a new token whenever entering `needsConfirmation`**

Find the place in `VoiceCommandController` where `pendingAction` is assigned and `status` is set to `.needsConfirmation(...)`. Wrap the assignment in a helper that also sets the token:

```swift
private func setPendingAction(_ action: VoicePendingAction, prompt: String) {
    pendingAction = action
    pendingActionToken = UUID()
    status = .needsConfirmation(prompt)
}
```

Replace existing direct assignments to `pendingAction = ...` + `status = .needsConfirmation(...)` with calls to `setPendingAction`. (Search for `needsConfirmation` in this file to find them.)

- [ ] **Step 3: Reset token on stop and on cancel/confirm exit**

In `func stop()`:
```swift
pendingActionToken = nil
```

In the existing `confirmPendingAction()` and `cancelPendingAction()` methods, after the action completes, set `pendingActionToken = nil`.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/VoiceCommandController.swift
git commit -m "feat(voice): add pendingActionToken for idempotent confirm/cancel"
```

---

### Task 2.3 — Make confirm/cancel token-aware (TDD: makes Spike E tests pass)

**Files:**
- Modify: `Sources/Nous/Services/VoiceCommandController.swift`
- Modify: `Tests/NousTests/VoiceCommandControllerIdempotencyTests.swift` (uncomment/enable)

- [ ] **Step 1: Run Spike E tests to confirm they fail**

Run: `swift test --filter VoiceCommandControllerIdempotencyTests`
Expected: FAIL or compile error.

- [ ] **Step 2: Add token-checked confirm/cancel**

In `VoiceCommandController.swift`, modify `confirmPendingAction()`:

```swift
func confirmPendingAction() {
    confirmWithToken(pendingActionToken)
}

func confirmWithToken(_ token: UUID?) {
    guard let action = pendingAction,
          let current = pendingActionToken,
          token == current else { return }
    pendingActionToken = nil
    pendingAction = nil
    // ... existing dispatch logic to handlers.sendMessage / handlers.createNote ...
    // (preserve the existing body; just guard at the top)
}
```

Same shape for `cancelPendingAction()`:

```swift
func cancelPendingAction() {
    cancelWithToken(pendingActionToken)
}

func cancelWithToken(_ token: UUID?) {
    guard let current = pendingActionToken,
          token == current else { return }
    pendingActionToken = nil
    pendingAction = nil
    // ... existing reset logic, e.g. status = .listening ...
}
```

The existing inner bodies are preserved; only the entry guards are added. Look at lines 279-295 in the original file for the existing logic.

- [ ] **Step 3: Run tests to verify they pass**

Run: `swift test --filter VoiceCommandControllerIdempotencyTests`
Expected: PASS.

- [ ] **Step 4: Run the full test suite to verify no regression**

Run: `swift test`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/VoiceCommandController.swift Tests/NousTests/VoiceCommandControllerIdempotencyTests.swift
git commit -m "feat(voice): token-gated confirm/cancel for idempotency"
```

---

## Phase 3 — Notch panel hosting

### Task 3.1 — Create `NotchScreenDetection`

**Files:**
- Create: `Sources/Nous/Views/Voice/NotchScreenDetection.swift`

Use the algorithm from Spike C findings.

- [ ] **Step 1: Write the helper**

```swift
// Sources/Nous/Views/Voice/NotchScreenDetection.swift
import AppKit
import CoreGraphics

@MainActor
enum NotchScreenDetection {
    /// Returns the Mac's built-in notch display, or nil if none is connected.
    static func currentNotchScreen() -> NSScreen? {
        for screen in NSScreen.screens {
            let hasNotchSafeArea = screen.safeAreaInsets.top > 0
            let isBuiltInName = screen.localizedName.contains("Built-in")

            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let isBuiltInCG = displayID != 0 && CGDisplayIsBuiltin(displayID) != 0

            if hasNotchSafeArea && (isBuiltInName || isBuiltInCG) {
                return screen
            }
        }
        return nil
    }
}
```

If Spike C surfaced a different signal combination, use that instead.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Views/Voice/NotchScreenDetection.swift
git commit -m "feat(voice): notch screen detection helper"
```

---

### Task 3.2 — Create `VoiceMainWindowFocusObserver`

**Files:**
- Create: `Sources/Nous/Views/Voice/VoiceMainWindowFocusObserver.swift`

Use the signal expression from Spike D.

- [ ] **Step 1: Write the observer**

```swift
// Sources/Nous/Views/Voice/VoiceMainWindowFocusObserver.swift
import AppKit
import Combine

@MainActor
final class VoiceMainWindowFocusObserver: ObservableObject {
    @Published private(set) var isMainWindowKey: Bool = false

    private var debounceTask: Task<Void, Never>?
    private let debounceMillis: UInt64 = 120 // from Spike D

    init() {
        recompute()
        let nc = NotificationCenter.default
        let triggers: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification
        ]
        for name in triggers {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRecompute()
            }
        }
    }

    private func scheduleRecompute() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.debounceMillis ?? 120) * 1_000_000)
            await MainActor.run { self?.recompute() }
        }
    }

    private func recompute() {
        let app = NSApp
        let main = app?.mainWindow
        let appActive = app?.isActive ?? false
        let mainKey = main?.isKeyWindow ?? false
        let miniaturized = main?.isMiniaturized ?? false

        // Signal expression chosen by Spike D.
        let isKey = appActive && mainKey && !miniaturized
        if isKey != isMainWindowKey {
            isMainWindowKey = isKey
        }
    }
}
```

If Spike D chose a different expression / debounce, substitute here.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Views/Voice/VoiceMainWindowFocusObserver.swift
git commit -m "feat(voice): main window focus observer"
```

---

### Task 3.3 — Create `VoiceNotchPanelController`

**Files:**
- Create: `Sources/Nous/Views/Voice/VoiceNotchPanelController.swift`

Use panel level from Spike A and clipping technique from Spike B.

- [ ] **Step 1: Write the controller**

```swift
// Sources/Nous/Views/Voice/VoiceNotchPanelController.swift
import AppKit
import SwiftUI
import Combine

@MainActor
final class VoiceNotchPanelController {
    private weak var voiceController: VoiceCommandController?
    private let focusObserver: VoiceMainWindowFocusObserver
    private var panel: NSPanel?
    private var hostingView: NSHostingView<NotchPanelRoot>?
    private var cancellables = Set<AnyCancellable>()
    private var screenChangeObserver: NSObjectProtocol?

    init(
        voiceController: VoiceCommandController,
        focusObserver: VoiceMainWindowFocusObserver
    ) {
        self.voiceController = voiceController
        self.focusObserver = focusObserver
        bind()
    }

    deinit {
        if let obs = screenChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func bind() {
        guard voiceController != nil else { return }

        // `@Observable` types are observed via `withObservationTracking`, not Combine.
        // Re-arm the tracking on every change so we keep observing.
        observeVoiceState()

        // The focus observer is an ObservableObject (Combine), so $isMainWindowKey works.
        focusObserver.$isMainWindowKey
            .sink { [weak self] _ in self?.recomputeFromCurrentState() }
            .store(in: &cancellables)

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.repositionPanel()
        }
    }

    private func observeVoiceState() {
        withObservationTracking {
            // Touch the properties we care about so the tracker registers them.
            _ = voiceController?.isActive
            _ = voiceController?.pendingAction
        } onChange: { [weak self] in
            // onChange fires off the main actor; hop back before mutating UI.
            Task { @MainActor [weak self] in
                self?.recomputeFromCurrentState()
                // Re-arm — withObservationTracking is one-shot.
                self?.observeVoiceState()
            }
        }
    }

    private func recomputeFromCurrentState() {
        guard let voiceController else { return }
        recomputeSurface(
            isActive: voiceController.isActive,
            isKey: focusObserver.isMainWindowKey
        )
    }

    private func recomputeSurface(isActive: Bool, isKey: Bool) {
        guard let voiceController else { return }
        // Frozen surface during pending confirmation (codex finding #6)
        if voiceController.pendingAction != nil { return }

        let next: VoiceCapsuleSurface
        if !isActive {
            next = .none
        } else if isKey {
            next = .inWindow
        } else if NotchScreenDetection.currentNotchScreen() != nil {
            next = .notch
        } else {
            next = .inWindow // notch-less fallback per spec § 6
        }
        if voiceController.visibleSurface != next {
            voiceController.visibleSurface = next
            applySurface(next)
        }
    }

    private func applySurface(_ surface: VoiceCapsuleSurface) {
        switch surface {
        case .none, .inWindow:
            hidePanel()
        case .notch:
            showPanel()
        }
    }

    private func showPanel() {
        guard let voiceController, let screen = NotchScreenDetection.currentNotchScreen() else {
            return
        }
        if panel == nil {
            createPanel(voiceController: voiceController)
        }
        positionPanel(on: screen)
        panel?.orderFront(nil)
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func createPanel(voiceController: VoiceCommandController) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Level chosen by Spike A.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false

        let host = NSHostingView(rootView: NotchPanelRoot(voiceController: voiceController))
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host
        self.hostingView = host
        self.panel = panel
    }

    private func positionPanel(on screen: NSScreen) {
        guard let panel else { return }
        // Technique chosen by Spike B. Default: option (a) — top above safe area.
        let safeTopY = screen.frame.maxY - screen.safeAreaInsets.top
        let width: CGFloat = 360
        let height: CGFloat = 100
        let frame = NSRect(
            x: screen.frame.midX - width/2,
            y: safeTopY - (height - 36),
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
    }

    private func repositionPanel() {
        if let screen = NotchScreenDetection.currentNotchScreen() {
            positionPanel(on: screen)
        } else {
            hidePanel()
        }
    }
}

private struct NotchPanelRoot: View {
    @Bindable var voiceController: VoiceCommandController

    var body: some View {
        VStack(spacing: 0) {
            // Top 36pt sits behind the bezel and is masked by the hardware notch.
            Spacer().frame(height: 36)

            VoiceCapsuleContent(
                status: voiceController.status,
                subtitleText: voiceController.subtitleText,
                audioLevel: voiceController.audioLevel,
                hasPendingConfirmation: voiceController.pendingAction != nil,
                showsStopButton: true,
                onConfirm: voiceController.confirmPendingAction,
                onCancel: voiceController.cancelPendingAction,
                onStop: voiceController.stop
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(NotchCapsuleBackground())
            .allowsHitTesting(voiceController.visibleSurface == .notch)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct NotchCapsuleBackground: View {
    var body: some View {
        ZStack {
            // Liquid Glass material (mapping from spec § 1)
            Rectangle()
                .fill(.ultraThinMaterial)
            Color.white.opacity(0.42)
        }
        .clipShape(NotchCapsuleShape(cornerRadius: 24))
        .overlay(
            NotchCapsuleShape(cornerRadius: 24)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
        .shadow(
            color: Color(red: 120/255, green: 80/255, blue: 40/255).opacity(0.20),
            radius: 18, x: 0, y: 16
        )
    }
}

/// Sharp top corners (the top is masked by the notch), 24pt rounded bottom corners.
private struct NotchCapsuleShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        p.addArc(
            center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        p.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        p.addArc(
            center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        p.closeSubpath()
        return p
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Views/Voice/VoiceNotchPanelController.swift
git commit -m "feat(voice): notch panel controller"
```

---

### Task 3.4 — Wire `VoiceNotchPanelController` into the app lifecycle

**Files:**
- Modify: `Sources/Nous/App/NousApp.swift` (or whichever file owns `VoiceCommandController` lifecycle)

- [ ] **Step 1: Find where `VoiceCommandController` is instantiated**

Run:
```bash
grep -rn "VoiceCommandController(" Sources/Nous/ | grep -v Tests
```

Pick the file that creates the singleton `VoiceCommandController` (likely `NousApp.swift` or a top-level container).

- [ ] **Step 2: Instantiate and retain the panel controller alongside**

Add fields:

```swift
@State private var voiceController = VoiceCommandController(...)
@State private var voiceFocusObserver = VoiceMainWindowFocusObserver()
@State private var voiceNotchPanelController: VoiceNotchPanelController?
```

In the same view's `.onAppear` (or app `init`), wire up:

```swift
.onAppear {
    voiceNotchPanelController = VoiceNotchPanelController(
        voiceController: voiceController,
        focusObserver: voiceFocusObserver
    )
}
```

- [ ] **Step 3: Build and run**

Run: `swift build`. Launch the app. Start voice mode. Click anywhere outside Nous (or ⌘H Nous). Verify the notch panel appears (it will look unstyled until later tasks polish; minimum: a glass capsule under the notch).

- [ ] **Step 4: Commit**

```bash
git add -u Sources/Nous/App/
git commit -m "feat(voice): wire VoiceNotchPanelController into app lifecycle"
```

---

## Phase 4 — Surface gating in `ChatArea`

### Task 4.1 — Gate `VoiceCapsuleView` mount on `visibleSurface == .inWindow`

**Files:**
- Modify: `Sources/Nous/Views/ChatArea.swift`

- [ ] **Step 1: Update the mount condition**

In `ChatArea.swift:258`, change:

```swift
if voiceController.isActive || voiceController.status.shouldDisplayPill || voiceController.pendingAction != nil {
```

to:

```swift
if voiceController.visibleSurface == .inWindow &&
   (voiceController.isActive || voiceController.status.shouldDisplayPill || voiceController.pendingAction != nil) {
```

- [ ] **Step 2: Disable hit-testing during transition**

Wrap the `VoiceCapsuleView(...)` block (lines 259-266) with:

```swift
VoiceCapsuleView(...)
    .padding(.top, 16)
    .transition(.move(edge: .top).combined(with: .opacity))
    .allowsHitTesting(voiceController.visibleSurface == .inWindow)
```

- [ ] **Step 3: Run the app**

Run the app. Voice mode active + Nous focused: in-window capsule. ⌘H Nous: in-window capsule disappears (notch capsule should appear via Phase 3 wiring). Bring Nous back: in-window capsule reappears.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Views/ChatArea.swift
git commit -m "feat(voice): gate in-window capsule on visibleSurface"
```

---

## Phase 5 — Click behavior

### Task 5.1 — Body click brings Nous to front

**Files:**
- Modify: `Sources/Nous/Views/Voice/VoiceNotchPanelController.swift`

- [ ] **Step 1: Add an explicit body-click gesture**

In `NotchPanelRoot.body`, wrap the `VoiceCapsuleContent(...)` call with a tap gesture that activates Nous:

```swift
VoiceCapsuleContent(...)
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(NotchCapsuleBackground())
    .contentShape(NotchCapsuleShape(cornerRadius: 24))
    .onTapGesture { activateNousMainWindow() }
    .allowsHitTesting(voiceController.visibleSurface == .notch)
```

Add helper:

```swift
private func activateNousMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.mainWindow?.makeKeyAndOrderFront(nil)
}
```

The Stop / Confirm / Cancel buttons inside `VoiceCapsuleContent` use `Button { }` and consume the tap before it reaches the body's `onTapGesture`, so they don't activate Nous (verified by Spike A).

- [ ] **Step 2: Test**

Run the app. Voice mode active, Nous unfocused, notch capsule visible:
- Click capsule body → Nous comes to front.
- Click Stop → voice ends, Nous does NOT come to front.
- Trigger `needsConfirmation`, click Confirm → action dispatches, Nous does NOT come to front.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Views/Voice/VoiceNotchPanelController.swift
git commit -m "feat(voice): notch body click brings Nous to front"
```

---

## Phase 6 — Manual QA pass

### Task 6.1 — Run all 24 manual QA cases

**Files:**
- Create: `docs/superpowers/spikes/2026-04-29-qa-results.md`

Run each test from spec § Manual QA Test Plan and record results.

- [ ] **Step 1: Surface switching tests (5 cases)**
- [ ] **Step 2: Confirmation idempotency tests (3 cases)**
- [ ] **Step 3: Hardware / display tests (4 cases)**
- [ ] **Step 4: macOS UI z-order tests (4 cases)**
- [ ] **Step 5: Stop button coverage tests (3 cases)**
- [ ] **Step 6: Visual polish tests (4 cases)**

For each case, record `[PASS]` / `[FAIL]` / `[BLOCKED]` with a one-line note. Save to `docs/superpowers/spikes/2026-04-29-qa-results.md`.

- [ ] **Step 7: Commit results doc**

```bash
git add docs/superpowers/spikes/2026-04-29-qa-results.md
git commit -m "test(voice): manual QA results for notch capsule"
```

---

### Task 6.2 — Fix any QA failures

For each `[FAIL]` from Task 6.1:

- [ ] **Step 1: Reproduce locally and isolate the cause**
- [ ] **Step 2: Write a unit / integration test that captures the failure (where applicable)**
- [ ] **Step 3: Fix the code in the smallest possible change**
- [ ] **Step 4: Verify the test now passes**
- [ ] **Step 5: Re-run the QA case to confirm**
- [ ] **Step 6: Commit**

```bash
git add -u .
git commit -m "fix(voice): <one-line description of the failure>"
```

Repeat per failure. After all failures resolved, update `docs/superpowers/spikes/2026-04-29-qa-results.md` with the resolution notes and commit:

```bash
git add docs/superpowers/spikes/2026-04-29-qa-results.md
git commit -m "test(voice): all QA cases passing"
```

---

## Done

When Phase 6 ends with all 24 QA cases passing, voice mode shows in-window when Nous is focused and at the notch when it isn't, with one Stop button always reachable and zero double-fires on Confirm/Cancel under rapid focus changes. Phase 2 work (right-click context menu, no-notch fallback, global hotkey, full a11y audit) is queued for a follow-up plan.
