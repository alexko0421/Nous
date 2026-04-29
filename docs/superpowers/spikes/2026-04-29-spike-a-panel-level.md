# Spike A+B+C Combined — Panel Level, Top Clipping, Notch Detection

**Date:** 2026-04-29
**Status:** [PASS / FAIL / DEGRADED — fill after running]
**Decision:** Use `NSWindow.Level.<chosen>` for the notch panel.

This spike was originally three separate explorations (A: panel level, B: top-clipping technique, C: notch detection). They were merged because the visual fidelity of A's test panel matters: a panel that doesn't position correctly under the notch gives no useful information about z-order behavior in the real product. The combined spike validates all three concerns in one visually-correct test harness.

## Visual fidelity check (Spike B + C)

- [ ] Panel appears on the **MacBook built-in display** (not external monitor), centered horizontally under the notch.
- [ ] Top 36pt of the panel is masked by the hardware notch — no visible black "shoulder" or gap.
- [ ] Panel renders as Liquid Glass (米白 tint, blur visible against wallpaper).
- [ ] Listening label and `.<level>` subtitle are readable at 12-14pt.
- [ ] No visual border on top edge; 24pt rounded bottom corners.

If any visual fidelity check fails, note the failure and which screen the panel appeared on.

## Z-order matrix (Spike A)

| Level | Above app windows? | Below Spotlight? | Below Control Center? | Doesn't block fullscreen menu reveal? | Behaves in Mission Control? |
|---|---|---|---|---|---|
| `.normal` | ☐ | ☐ | ☐ | ☐ | ☐ |
| `.floating` | ☐ | ☐ | ☐ | ☐ | ☐ |
| `.statusBar` | ☐ | ☐ | ☐ | ☐ | ☐ |
| `.popUpMenu` | ☐ | ☐ | ☐ | ☐ | ☐ |
| `.modalPanel` | ☐ | ☐ | ☐ | ☐ | ☐ |

## Test cases run

1. Panel visible. Open Spotlight (⌘Space). Result: ___
2. Click menu bar to open Control Center. Result: ___
3. Open Safari fullscreen. Move cursor to top edge. Result: ___
4. Trigger Mission Control (F3). Result: ___
5. Open a system modal (Save dialog from any app). Result: ___

## Edge cases discovered

- _

## Decision rationale

_
