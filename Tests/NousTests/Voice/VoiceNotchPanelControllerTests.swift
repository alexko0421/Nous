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

    func testActiveVoiceSessionOffMainWorkspaceRecoversNotchSurface() {
        XCTAssertEqual(
            VoiceCapsuleSurfacePolicy.nextSurface(
                isVoiceActive: true,
                hasPendingAction: false,
                currentSurface: .none,
                isMainWorkspaceActive: false,
                hasNotchScreen: true
            ),
            .notch
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

    func testLeavingMainWorkspaceAfterSpaceSwitchUsesNotchSurfaceWhenNotchExists() {
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

    func testLeavingMainWorkspaceForAnotherWindowUsesNotchSurface() {
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

    func testActiveVoiceSessionKeepsCapsuleVisibleThroughIdleTransition() {
        XCTAssertTrue(
            VoiceCapsuleVisibilityPolicy.shouldShowCapsule(
                isVoiceActive: true,
                status: .idle,
                hasPendingAction: false,
                hasSummaryPreview: false
            )
        )
    }

    func testInactiveIdleVoiceSessionKeepsCapsuleHidden() {
        XCTAssertFalse(
            VoiceCapsuleVisibilityPolicy.shouldShowCapsule(
                isVoiceActive: false,
                status: .idle,
                hasPendingAction: false,
                hasSummaryPreview: false
            )
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

    func testNotchPanelFrameIsBoundedToCapsuleHitArea() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)

        let frame = VoiceNotchPanelController.notchPanelFrame(
            screenFrame: screenFrame,
            safeAreaTop: 74,
            hasSummaryPreview: false
        )

        XCTAssertEqual(frame.midX, screenFrame.midX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, screenFrame.maxY, accuracy: 0.001)
        XCTAssertLessThanOrEqual(frame.width, 420)
        XCTAssertLessThanOrEqual(frame.height, 190)
    }

    func testNotchPanelFrameExpandsForSummaryWithoutUsingFullScreenWidth() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)

        let frame = VoiceNotchPanelController.notchPanelFrame(
            screenFrame: screenFrame,
            safeAreaTop: 74,
            hasSummaryPreview: true
        )

        XCTAssertEqual(frame.midX, screenFrame.midX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, screenFrame.maxY, accuracy: 0.001)
        XCTAssertLessThanOrEqual(frame.width, 640)
        XCTAssertLessThanOrEqual(frame.height, 540)
        XCTAssertLessThan(frame.width, screenFrame.width)
    }
}

final class WelcomeActionMenuHitRegionTests: XCTestCase {
    func testExpandedRegionContainsVisibleActionMenu() {
        XCTAssertGreaterThanOrEqual(
            WelcomeActionMenuHitRegion.expandedHeight,
            WelcomeActionMenuHitRegion.composerHeight
                + WelcomeActionMenuHitRegion.actionMenuGap
                + WelcomeActionMenuHitRegion.actionMenuHeight
        )
    }
}
