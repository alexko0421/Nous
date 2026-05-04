import AppKit
import XCTest
@testable import Nous

final class WindowAppearanceBridgeTests: XCTestCase {
    @MainActor
    func testDarkModeAppliesDarkAquaToWindow() {
        let window = NSWindow()

        AppAppearanceMode.apply("dark", to: window)

        XCTAssertEqual(window.appearance?.name, .darkAqua)
    }

    @MainActor
    func testLightModeAppliesAquaToWindow() {
        let window = NSWindow()

        AppAppearanceMode.apply("light", to: window)

        XCTAssertEqual(window.appearance?.name, .aqua)
    }

    @MainActor
    func testSystemModeClearsExplicitWindowAppearance() {
        let window = NSWindow()
        AppAppearanceMode.apply("dark", to: window)

        AppAppearanceMode.apply("system", to: window)

        XCTAssertNil(window.appearance)
    }
}
