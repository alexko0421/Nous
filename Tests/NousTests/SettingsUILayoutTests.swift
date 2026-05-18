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
        let leftSidebarSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/LeftSidebar.swift"),
            encoding: .utf8
        )

        let windowTint = try XCTUnwrap(tokenBlock(named: "windowGlassTint", in: themeSource))
        let sidebarTint = try XCTUnwrap(tokenBlock(named: "sidebarGlassTint", in: themeSource))
        let sidebarVeil = try XCTUnwrap(tokenBlock(named: "sidebarGlassVeil", in: themeSource))
        let surfaceTint = try XCTUnwrap(tokenBlock(named: "surfaceGlassTint", in: themeSource))
        let controlTint = try XCTUnwrap(tokenBlock(named: "controlGlassTint", in: themeSource))
        let welcomeStart = try XCTUnwrap(tokenBlock(named: "welcomeGradientStart", in: themeSource))
        let welcomeEnd = try XCTUnwrap(tokenBlock(named: "welcomeGradientEnd", in: themeSource))

        XCTAssertTrue(windowTint.contains("light: NSColor(red: 250/255, green: 248/255, blue: 243/255, alpha: 0.66)"))
        XCTAssertTrue(sidebarTint.contains("light: NSColor(white: 1, alpha: 0.58)"))
        XCTAssertTrue(sidebarVeil.contains("light: NSColor(red: 1, green: 253/255, blue: 248/255, alpha: 0.36)"))
        XCTAssertFalse(sidebarTint.contains("static let sidebarGlassTint: NSColor? = nil"))
        XCTAssertFalse(sidebarTint.contains("253/255, green: 251/255, blue: 247/255, alpha: 0.84"))
        XCTAssertTrue(surfaceTint.contains("light: NSColor(red: 253/255, green: 251/255, blue: 247/255, alpha: 0.38)"))
        XCTAssertTrue(controlTint.contains("light: NSColor(red: 254/255, green: 253/255, blue: 250/255, alpha: 0.30)"))
        XCTAssertTrue(welcomeStart.contains("light: NSColor(red: 253/255, green: 251/255, blue: 247/255, alpha: 1)"))
        XCTAssertTrue(welcomeEnd.contains("light: NSColor(red: 250/255, green: 248/255, blue: 243/255, alpha: 1)"))
        XCTAssertFalse(welcomeStart.contains("light: NSColor(white: 1, alpha: 1)"))

        XCTAssertTrue(contentSource.contains("@Environment(\\.colorScheme)"))
        XCTAssertTrue(contentSource.contains("return Color(red: 254/255, green: 253/255, blue: 250/255).opacity(0.93)"))
        let chatBackgroundStart = try XCTUnwrap(chatAreaSource.range(of: ".background(ChatContentBackgroundLayer())"))
        let chatBackgroundEnd = try XCTUnwrap(chatAreaSource.range(of: ".onChange(of: citationNodeIDs)"))
        let chatBackgroundSource = String(chatAreaSource[chatBackgroundStart.lowerBound..<chatBackgroundEnd.lowerBound])
        XCTAssertTrue(chatBackgroundSource.contains("cornerRadius: 36"))
        XCTAssertTrue(chatBackgroundSource.contains("tintColor: AppColor.sidebarGlassTint"))
        XCTAssertTrue(chatBackgroundSource.contains(".clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))"))
        XCTAssertFalse(chatBackgroundSource.contains("tintColor: AppColor.surfaceGlassTint"))
        XCTAssertTrue(leftSidebarSource.contains(".fill(AppColor.sidebarGlassVeil)"))
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

        XCTAssertTrue(source.contains("private func settingsGlassBackground("))
        XCTAssertTrue(source.contains("cornerRadius: SettingsLayout.cardCornerRadius"))
        XCTAssertTrue(source.contains("tintColor: AppColor.surfaceGlassTint"))
        XCTAssertTrue(source.contains("cornerRadius: SettingsLayout.controlCornerRadius"))
        XCTAssertTrue(source.contains("tintColor: AppColor.controlGlassTint"))
        XCTAssertTrue(source.contains("HStack(spacing: SettingsLayout.columnSpacing)"))
        XCTAssertTrue(source.contains("NativeGlassPanel(cornerRadius: SettingsLayout.sidebarCornerRadius, tintColor: AppColor.sidebarGlassTint)"))
        XCTAssertTrue(source.contains("cornerRadius: SettingsLayout.contentCornerRadius"))
        XCTAssertTrue(source.contains("tintColor: AppColor.rightPanelGlassTint"))
        XCTAssertTrue(source.contains(".frame(width: SettingsLayout.sidebarWidth)"))
        XCTAssertTrue(source.contains(".frame(height: 34)"))

        XCTAssertFalse(source.contains("Rectangle()\n                .fill(AppColor.panelStroke.opacity(0.35))"))
        XCTAssertFalse(source.contains(".frame(width: 200)"))
        XCTAssertFalse(source.contains(".frame(width: 176)"))
        XCTAssertFalse(source.contains(".background(AppColor.surfaceSecondary)"))
        XCTAssertFalse(source.contains(".background(AppColor.surfacePrimary)"))
    }

    func testSettingsShellMatchesMainWindowScale() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private enum SettingsLayout"))
        XCTAssertTrue(source.contains("static let shellPadding = RightPanelLayout.windowPadding"))
        XCTAssertTrue(source.contains("static let columnSpacing = RightPanelLayout.windowPadding"))
        XCTAssertTrue(source.contains("static let sidebarWidth = GalaxySidebarLayout.width"))
        XCTAssertTrue(source.contains("static let contentCornerRadius: CGFloat = 36"))
        XCTAssertTrue(source.contains("HStack(spacing: SettingsLayout.columnSpacing)"))
        XCTAssertTrue(source.contains(".padding(SettingsLayout.shellPadding)"))
        XCTAssertTrue(source.contains(".frame(width: SettingsLayout.sidebarWidth)"))
        XCTAssertTrue(source.contains("cornerRadius: SettingsLayout.contentCornerRadius"))
        XCTAssertTrue(source.contains("darkOpacity: SettingsLayout.contentVeilDarkOpacity"))
        XCTAssertTrue(source.contains(".stroke(AppColor.panelStroke.opacity(SettingsLayout.cardStrokeOpacity), lineWidth: 1)"))

        XCTAssertFalse(source.contains("HStack(spacing: 18)"))
        XCTAssertFalse(source.contains(".padding(.horizontal, 22)"))
        XCTAssertFalse(source.contains(".padding(.vertical, 22)"))
        XCTAssertFalse(source.contains(".frame(width: 176)"))
        XCTAssertFalse(source.contains(".stroke(AppColor.panelStroke.opacity(0.88), lineWidth: 1)"))
        XCTAssertFalse(source.contains(".stroke(AppColor.panelStroke.opacity(0.78), lineWidth: 1)"))
    }

    func testSettingsPrimaryPagesMaskSystemBlueGlassInDarkMode() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@Environment(\\.colorScheme) private var colorScheme"))
        XCTAssertTrue(source.contains("static let contentVeilDarkOpacity = 0.88"))
        XCTAssertTrue(source.contains("static let cardVeilDarkOpacity = 0.48"))
        XCTAssertTrue(source.contains("static let controlVeilDarkOpacity = 0.32"))
        XCTAssertTrue(source.contains("private var darkGlassVeilOpacity"))
        XCTAssertTrue(source.contains("colorScheme == .dark ? darkOpacity : lightOpacity"))
        XCTAssertTrue(source.contains(".background(settingsGlassBackground("))
        XCTAssertTrue(source.contains(".fill(AppColor.colaBeige.opacity(veilOpacity))"))

        XCTAssertFalse(source.contains(".background(\n                NativeGlassPanel(cornerRadius: SettingsLayout.contentCornerRadius, tintColor: AppColor.rightPanelGlassTint) { EmptyView() }\n            )"))
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
