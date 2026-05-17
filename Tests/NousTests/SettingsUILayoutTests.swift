import XCTest

final class SettingsUILayoutTests: XCTestCase {
    func testLightModeCalmLayerStaysWarmInsteadOfDarkOverlay() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let themeSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Theme/AppColor.swift"),
            encoding: .utf8
        )
        let contentSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/App/ContentView.swift"),
            encoding: .utf8
        )
        let welcomeSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/WelcomeView.swift"),
            encoding: .utf8
        )
        let chatAreaSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/ChatArea.swift"),
            encoding: .utf8
        )

        let windowTint = try XCTUnwrap(tokenBlock(named: "windowGlassTint", in: themeSource))
        let sidebarTint = try XCTUnwrap(tokenBlock(named: "sidebarGlassTint", in: themeSource))
        let surfaceTint = try XCTUnwrap(tokenBlock(named: "surfaceGlassTint", in: themeSource))
        let controlTint = try XCTUnwrap(tokenBlock(named: "controlGlassTint", in: themeSource))
        let welcomeStart = try XCTUnwrap(tokenBlock(named: "welcomeGradientStart", in: themeSource))
        let welcomeEnd = try XCTUnwrap(tokenBlock(named: "welcomeGradientEnd", in: themeSource))

        XCTAssertTrue(windowTint.contains("light: NSColor(red: 250/255, green: 248/255, blue: 243/255, alpha: 0.66)"))
        XCTAssertTrue(sidebarTint.contains("light: NSColor(red: 253/255, green: 251/255, blue: 247/255, alpha: 0.84)"))
        XCTAssertTrue(surfaceTint.contains("light: NSColor(red: 253/255, green: 251/255, blue: 247/255, alpha: 0.38)"))
        XCTAssertTrue(controlTint.contains("light: NSColor(red: 254/255, green: 253/255, blue: 250/255, alpha: 0.30)"))
        XCTAssertTrue(welcomeStart.contains("light: NSColor(red: 253/255, green: 251/255, blue: 247/255, alpha: 1)"))
        XCTAssertTrue(welcomeEnd.contains("light: NSColor(red: 250/255, green: 248/255, blue: 243/255, alpha: 1)"))
        XCTAssertFalse(welcomeStart.contains("light: NSColor(white: 1, alpha: 1)"))

        XCTAssertTrue(contentSource.contains("@Environment(\\.colorScheme)"))
        XCTAssertTrue(contentSource.contains("return Color(red: 254/255, green: 253/255, blue: 250/255).opacity(0.93)"))
        XCTAssertTrue(chatAreaSource.contains("tintColor: AppColor.surfaceGlassTint"))
        XCTAssertTrue(welcomeSource.contains("colorScheme == .dark ? 0.72 : 1"))
        XCTAssertTrue(welcomeSource.contains("colorScheme == .dark ? 0.74 : 1"))
    }

    func testSettingsUsesStructuredGlassHierarchy() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private func settingsPage<Content: View>"))
        XCTAssertTrue(source.contains("settingsPage(title: \"Profile\""))
        XCTAssertTrue(source.contains("settingsPage(title: \"General\""))
        XCTAssertTrue(source.contains("settingsPage(title: \"Models\""))

        XCTAssertTrue(source.contains("NativeGlassPanel(cornerRadius: 22, tintColor: AppColor.surfaceGlassTint)"))
        XCTAssertTrue(source.contains("NativeGlassPanel(cornerRadius: 16, tintColor: AppColor.controlGlassTint)"))
        XCTAssertTrue(source.contains(".frame(width: 168)"))
        XCTAssertTrue(source.contains(".frame(height: 34)"))

        XCTAssertFalse(source.contains(".frame(width: 200)"))
        XCTAssertFalse(source.contains(".background(AppColor.surfaceSecondary)"))
        XCTAssertFalse(source.contains(".background(AppColor.surfacePrimary)"))
    }

    func testAgentWorkAvoidsNestedWindowGlassInSettings() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/AgentWorkView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("NativeGlassPanel(cornerRadius: 20, tintColor: AppColor.surfaceGlassTint)"))
        XCTAssertTrue(source.contains("NativeGlassPanel(cornerRadius: 18, tintColor: AppColor.surfaceGlassTint)"))
        XCTAssertTrue(source.contains("NativeGlassPanel(cornerRadius: 14, tintColor: AppColor.controlGlassTint)"))

        XCTAssertFalse(source.contains(".clipShape(RoundedRectangle(cornerRadius: 36"))
        XCTAssertFalse(source.contains(".fill(Color.white.opacity(0.42))"))
        XCTAssertFalse(source.contains(".fill(Color.white.opacity(0.38))"))
        XCTAssertFalse(source.contains(".fill(Color.white.opacity(0.36))"))
        XCTAssertFalse(source.contains(".fill(Color.white.opacity(0.34))"))
    }

    func testAgentWorkShowsOutcomeContractReadiness() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/AgentWorkView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Contract ready"))
        XCTAssertTrue(source.contains("Missing"))
        XCTAssertTrue(source.contains("outcomeContract"))
    }

    private func tokenBlock(named tokenName: String, in source: String) -> String? {
        guard let start = source.range(of: "static let \(tokenName)") else {
            return nil
        }
        let remainder = source[start.lowerBound...]
        let nextToken = remainder
            .dropFirst()
            .range(of: "\n    static let ")
            .map { $0.lowerBound }
        let end = nextToken ?? source.endIndex
        return String(source[start.lowerBound..<end])
    }
}
