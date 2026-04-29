import AppKit
import XCTest
@testable import Nous

@MainActor
final class VoiceNotchPanelControllerTests: XCTestCase {
    func testAppForegroundOnDifferentSpaceUsesNotchSurface() {
        // Regression: when Nous is the frontmost app but its main window is
        // on a different Space (focusObserver false), the surface should be
        // .notch, not .inWindow. Previously this returned true via OR with
        // appActive, which incorrectly hid the notch capsule on Space switch.
        XCTAssertFalse(
            VoiceNotchPanelController.isMainWorkspaceActive(
                appActive: true,
                focusObserverActive: false
            )
        )
    }

    func testAppInactiveUsesFocusObserverState() {
        XCTAssertFalse(
            VoiceNotchPanelController.isMainWorkspaceActive(
                appActive: false,
                focusObserverActive: false
            )
        )
    }

    func testFocusObserverActiveImpliesMainWorkspace() {
        XCTAssertTrue(
            VoiceNotchPanelController.isMainWorkspaceActive(
                appActive: true,
                focusObserverActive: true
            )
        )
    }

    func testReturningToMainWorkspaceFromNotchUsesInWindowSurface() {
        XCTAssertEqual(
            VoiceCapsuleSurfacePolicy.nextSurface(
                isVoiceActive: true,
                hasPendingAction: false,
                currentSurface: .notch,
                isMainWorkspaceActive: true,
                hasNotchScreen: true
            ),
            .inWindow
        )
    }

    func testLeavingMainWorkspaceUsesNotchSurfaceWhenNotchExists() {
        XCTAssertEqual(
            VoiceCapsuleSurfacePolicy.nextSurface(
                isVoiceActive: true,
                hasPendingAction: false,
                currentSurface: .inWindow,
                isMainWorkspaceActive: false,
                hasNotchScreen: true
            ),
            .notch
        )
    }

    func testPendingConfirmationFreezesCurrentSurface() {
        XCTAssertEqual(
            VoiceCapsuleSurfacePolicy.nextSurface(
                isVoiceActive: true,
                hasPendingAction: true,
                currentSurface: .notch,
                isMainWorkspaceActive: true,
                hasNotchScreen: true
            ),
            .notch
        )
    }

    func testNotchPanelStaysVisibleWhenAppDeactivates() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        VoiceNotchPanelController.configureForNotchOverlay(panel)

        XCTAssertFalse(panel.hidesOnDeactivate)
    }
}
