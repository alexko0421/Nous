import XCTest
@testable import Nous

@MainActor
final class VoiceMainWindowFocusObserverTests: XCTestCase {
    func testTrackedMainWindowStaysActiveWhenOverlayPanelStealsKeyStatus() {
        XCTAssertTrue(
            VoiceMainWindowFocusObserver.isTrackedMainWindowActive(
                appActive: true,
                isVisible: true,
                isMiniaturized: false,
                isKeyWindow: false,
                isMainWindow: true
            )
        )
    }

    func testTrackedMainWindowStaysActiveWhenOverlayPanelStealsKeyAndMainStatus() {
        XCTAssertTrue(
            VoiceMainWindowFocusObserver.isTrackedMainWindowActive(
                appActive: true,
                isVisible: true,
                isMiniaturized: false,
                isKeyWindow: false,
                isMainWindow: false
            )
        )
    }

    func testTrackedMainWindowIsInactiveWhenAppIsInactive() {
        XCTAssertFalse(
            VoiceMainWindowFocusObserver.isTrackedMainWindowActive(
                appActive: false,
                isVisible: true,
                isMiniaturized: false,
                isKeyWindow: true,
                isMainWindow: true
            )
        )
    }

    func testTrackedMainWindowIsInactiveWhenMiniaturized() {
        XCTAssertFalse(
            VoiceMainWindowFocusObserver.isTrackedMainWindowActive(
                appActive: true,
                isVisible: true,
                isMiniaturized: true,
                isKeyWindow: true,
                isMainWindow: true
            )
        )
    }
}
