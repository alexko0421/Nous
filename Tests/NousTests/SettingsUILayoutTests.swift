import XCTest

final class SettingsUILayoutTests: XCTestCase {
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
}
