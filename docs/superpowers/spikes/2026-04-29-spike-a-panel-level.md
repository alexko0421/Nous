# Spike A — Panel Level + Z-Order

**Date:** 2026-04-29
**Status:** [PASS / FAIL / DEGRADED — fill after running]
**Decision:** Use `NSWindow.Level.<chosen>` for the notch panel.

## Test matrix

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
