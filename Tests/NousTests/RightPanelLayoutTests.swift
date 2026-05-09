import XCTest
@testable import Nous

final class RightPanelLayoutTests: XCTestCase {
    func testDefaultOpenLayoutKeepsChatPrimary() {
        XCTAssertGreaterThan(NousMainWindowController.defaultSize.width, 900)
        XCTAssertEqual(RightPanelLayout.defaultWindowWidth, 950)
        XCTAssertEqual(RightPanelLayout.defaultWindowHeight, 715)
        XCTAssertEqual(NousMainWindowController.defaultSize.width, RightPanelLayout.defaultWindowWidth)
        XCTAssertEqual(NousMainWindowController.defaultSize.height, RightPanelLayout.defaultWindowHeight)
        XCTAssertEqual(RightPanelLayout.preferredWidth, 300)
        XCTAssertLessThan(RightPanelLayout.preferredWidth, 420)

        let chatWidth = RightPanelLayout.estimatedOpenChatWidth(
            windowWidth: NousMainWindowController.defaultSize.width,
            sidebarVisible: true
        )
        let chatShare = RightPanelLayout.estimatedOpenChatShare(
            windowWidth: NousMainWindowController.defaultSize.width,
            sidebarVisible: true
        )
        let panelShare = RightPanelLayout.estimatedOpenPanelShare(
            windowWidth: NousMainWindowController.defaultSize.width,
            sidebarVisible: true
        )

        XCTAssertGreaterThan(chatWidth, RightPanelLayout.preferredWidth)
        XCTAssertEqual(chatShare, 0.60, accuracy: 0.03)
        XCTAssertEqual(panelShare, 0.40, accuracy: 0.03)
    }

    func testMinimumWindowStillKeepsChatAtLeastAsWideAsRightPanel() {
        let chatWidth = RightPanelLayout.estimatedOpenChatWidth(
            windowWidth: NousMainWindowController.minimumSize.width,
            sidebarVisible: true
        )

        XCTAssertGreaterThanOrEqual(chatWidth, RightPanelLayout.preferredWidth)
    }

    func testWindowPaddingIsAccountedForByContentMinimums() throws {
        XCTAssertEqual(RightPanelLayout.windowPadding, 12)
        XCTAssertEqual(
            RightPanelLayout.minimumContentWidth + RightPanelLayout.windowPadding * 2,
            RightPanelLayout.minimumWindowWidth
        )
        XCTAssertEqual(
            RightPanelLayout.minimumContentHeight + RightPanelLayout.windowPadding * 2,
            RightPanelLayout.minimumWindowHeight
        )

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/App/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("minWidth: RightPanelLayout.minimumContentWidth"))
        XCTAssertTrue(source.contains("minHeight: RightPanelLayout.minimumContentHeight"))
        XCTAssertTrue(source.contains(".padding(RightPanelLayout.windowPadding)"))
        XCTAssertFalse(source.contains(".frame(\n                minWidth: NousMainWindowController.minimumSize.width"))
    }

    func testRightPanelsUseSharedSupportingWidth() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let panelFiles = [
            "Sources/Nous/Views/ScratchPadPanel.swift",
            "Sources/Nous/Views/YouTubeLearningPanel.swift"
        ]

        for relativePath in panelFiles {
            let source = try String(
                contentsOf: repoRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains(".frame(width: RightPanelLayout.preferredWidth)"), relativePath)
            XCTAssertFalse(source.contains(".frame(width: 420)"), relativePath)
        }
    }

    func testLeftSidebarClipsGlassToItsRoundedShapeBeforeShadow() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/LeftSidebar.swift"),
            encoding: .utf8
        )

        let frameRange = try XCTUnwrap(source.range(of: ".frame(width: GalaxySidebarLayout.width)"))
        let clippedSource = String(source[frameRange.lowerBound...])
        XCTAssertTrue(clippedSource.contains(".clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))"))
        XCTAssertTrue(clippedSource.contains(".shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 8)"))
    }
}
