import AppKit
import XCTest
@testable import Nous

final class AppMotionTests: XCTestCase {
    func testSidePanelMotionKeepsSidebarSmoothnessAsTheReference() {
        let motion = AppMotion.sidePanelSpring

        XCTAssertEqual(motion.response, 0.4)
        XCTAssertEqual(motion.dampingFraction, 0.8)
        XCTAssertEqual(motion.blendDuration, 0)
    }

    func testSidebarAndMarkdownPanelUseTheSameSidePanelMotion() {
        XCTAssertEqual(AppMotion.sidebarPanelSpring, AppMotion.markdownPanelSpring)
    }

    @MainActor
    func testWindowConfiguratorDoesNotReconfigureTheSameWindowRepeatedly() {
        let coordinator = WindowConfigurationCoordinator()
        let window = NSWindow()

        XCTAssertTrue(coordinator.shouldConfigure(window))
        coordinator.markConfigured(window)

        XCTAssertFalse(coordinator.shouldConfigure(window))
        XCTAssertTrue(coordinator.shouldConfigure(NSWindow()))
    }

    @MainActor
    func testMainWindowControllerCreatesBorderlessNonRestorableWindow() {
        let window = NousMainWindowController.makeWindow()

        XCTAssertTrue(window is NousMainWindow)
        XCTAssertTrue(window.styleMask.contains(.borderless))
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertFalse(window.isRestorable)
        XCTAssertNil(window.restorationClass)
        XCTAssertNil(window.identifier)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.canBecomeMain)
    }

    @MainActor
    func testMainWindowOpensAsCompactFocusedSurface() {
        XCTAssertEqual(NousMainWindowController.defaultSize.width, 790)
        XCTAssertEqual(NousMainWindowController.defaultSize.height, 650)
        XCTAssertEqual(NousMainWindowController.minimumSize.width, 760)
        XCTAssertEqual(NousMainWindowController.minimumSize.height, 600)
    }

    @MainActor
    func testAppDelegateDisablesPersistentWindowRestoration() {
        let delegate = NousAppDelegate()

        XCTAssertFalse(delegate.applicationSupportsSecureRestorableState(NSApplication.shared))
    }

    func testWindowRestorationPolicyIgnoresApplePersistenceAndClearsSwiftUIWindowKeys() {
        let suiteName = "nous.window-restoration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            "345 187 850 661 0 0 1512 949",
            forKey: "NSWindow Frame SwiftUI.ModifiedContent<Nous.ContentView, SwiftUI._BackgroundModifier<Nous.WindowConfigurator>>-1-AppWindow-1"
        )
        defaults.set(
            ["0.000000, 0.000000, 188.000000, 652.000000, NO, NO"],
            forKey: "NSSplitView Subview Frames SwiftUI.ModifiedContent<Nous.ContentView, SwiftUI._BackgroundModifier<Nous.WindowConfigurator>>-1-AppWindow-1, SidebarNavigationSplitView"
        )
        defaults.set("679 267 450 452 0 0 1512 949", forKey: "NSWindow Frame settings-view")
        defaults.set("Alex", forKey: "nous.user.name")

        WindowRestorationPolicy.disablePersistentWindowRestoration(defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: WindowRestorationPolicy.applePersistenceIgnoreStateKey))
        XCTAssertNil(defaults.object(forKey: "NSWindow Frame SwiftUI.ModifiedContent<Nous.ContentView, SwiftUI._BackgroundModifier<Nous.WindowConfigurator>>-1-AppWindow-1"))
        XCTAssertNil(defaults.object(forKey: "NSSplitView Subview Frames SwiftUI.ModifiedContent<Nous.ContentView, SwiftUI._BackgroundModifier<Nous.WindowConfigurator>>-1-AppWindow-1, SidebarNavigationSplitView"))
        XCTAssertEqual(defaults.string(forKey: "NSWindow Frame settings-view"), "679 267 450 452 0 0 1512 949")
        XCTAssertEqual(defaults.string(forKey: "nous.user.name"), "Alex")
    }
}
