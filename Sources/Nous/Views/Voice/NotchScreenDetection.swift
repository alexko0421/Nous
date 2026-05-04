import AppKit
import CoreGraphics

/// Detects the Mac's built-in (notch) display.
///
/// This is permanent infrastructure for the voice notch capsule (Phase 3 Task 3.1).
/// It was promoted out of spike scratch on 2026-04-29 because the panel-level spike
/// needed correct positioning to be a meaningful test, and the production capsule
/// will use the same detection logic.
@MainActor
enum NotchScreenDetection {
    /// Returns the Mac's built-in notch display, or nil if none is connected.
    ///
    /// No single signal is sufficient on its own:
    /// - `safeAreaInsets.top > 0` indicates a notch on macOS 12+
    /// - `localizedName` containing "Built-in" or `CGDisplayIsBuiltin` confirms it's the laptop display
    ///
    /// Both must agree before we treat a screen as the notch screen.
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
