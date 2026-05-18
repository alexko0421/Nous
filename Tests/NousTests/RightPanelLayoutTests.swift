import XCTest
import UniformTypeIdentifiers
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

    func testRightPanelVisibilityIsScopedToTheCurrentChatSurface() {
        let currentConversationId = UUID()
        let nextConversationId = UUID()

        XCTAssertEqual(
            RightPanelSurfaceScope.modeAfterConversationChange(
                currentMode: .source,
                oldConversationId: currentConversationId,
                newConversationId: currentConversationId
            ),
            .source
        )
        XCTAssertNil(
            RightPanelSurfaceScope.modeAfterConversationChange(
                currentMode: .source,
                oldConversationId: currentConversationId,
                newConversationId: nextConversationId
            )
        )
        XCTAssertNil(
            RightPanelSurfaceScope.modeAfterConversationChange(
                currentMode: .markdown,
                oldConversationId: currentConversationId,
                newConversationId: nil
            )
        )
        XCTAssertEqual(
            RightPanelSurfaceScope.modeAfterConversationChange(
                currentMode: .source,
                oldConversationId: nil,
                newConversationId: nextConversationId,
                isDraftBootstrap: true
            ),
            .source
        )
        XCTAssertNil(
            RightPanelSurfaceScope.modeAfterConversationChange(
                currentMode: .source,
                oldConversationId: nil,
                newConversationId: nextConversationId,
                isDraftBootstrap: false
            )
        )
        XCTAssertEqual(
            RightPanelSurfaceScope.modeAfterTabChange(
                currentMode: .markdown,
                selectedTabIsChat: true
            ),
            .markdown
        )
        XCTAssertNil(
            RightPanelSurfaceScope.modeAfterTabChange(
                currentMode: .markdown,
                selectedTabIsChat: false
            )
        )
        XCTAssertNil(
            RightPanelSurfaceScope.modeAfterNewBlankConversation(
                currentMode: .source
            )
        )
    }

    func testURLSourceReaderReplacesVisibleYouTubePanelMode() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rightPanelModeSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Models/RightPanelMode.swift"),
            encoding: .utf8
        )
        let contentViewSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/App/ContentView.swift"),
            encoding: .utf8
        )
        let chatAreaSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/ChatArea.swift"),
            encoding: .utf8
        )
        let panelSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/YouTubeLearningPanel.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(rightPanelModeSource.contains("case source"))
        XCTAssertFalse(rightPanelModeSource.contains("case youtube"))
        XCTAssertTrue(contentViewSource.contains("case .source"))
        XCTAssertFalse(contentViewSource.contains("case .youtube:"))
        XCTAssertTrue(chatAreaSource.contains("rightPanelMode = .source"))
        XCTAssertFalse(chatAreaSource.contains("mode: .youtube"))
        XCTAssertFalse(panelSource.contains("Text(\"YouTube\")"))
        XCTAssertFalse(panelSource.contains("TextField(\"YouTube URL\""))
        XCTAssertFalse(panelSource.contains(".help(\"Analyze video\")"))
        XCTAssertFalse(panelSource.contains("Text(\"Reading video\")"))
        XCTAssertTrue(panelSource.contains("Text(\"URL\")"))
        XCTAssertTrue(panelSource.contains("TextField(\"URL or document\""))
        XCTAssertTrue(panelSource.contains("Text(\"Reading source\")"))
        XCTAssertTrue(panelSource.contains(".fileImporter("))
        XCTAssertTrue(panelSource.contains("loadDocumentAttachments"))
    }

    func testURLSourceReaderUsesDocumentOnlyImporterTypes() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let panelSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/YouTubeLearningPanel.swift"),
            encoding: .utf8
        )
        let extractorSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Services/AttachmentExtractor.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(extractorSource.contains("sourceReaderContentTypes"))
        XCTAssertTrue(panelSource.contains("allowedContentTypes: AttachmentDropSupport.sourceReaderContentTypes"))
        XCTAssertFalse(panelSource.contains("allowedContentTypes: AttachmentDropSupport.fileImporterContentTypes"))
        XCTAssertTrue(AttachmentDropSupport.sourceReaderContentTypes.contains { $0.conforms(to: .pdf) })
        XCTAssertFalse(AttachmentDropSupport.sourceReaderContentTypes.contains { $0.conforms(to: .image) })
        XCTAssertTrue(AttachmentDropSupport.fileImporterContentTypes.contains { $0.conforms(to: .image) })
    }

    func testRightPanelScopePolicyIsAppliedOnNavigationChanges() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contentViewSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/App/ContentView.swift"),
            encoding: .utf8
        )
        let chatAreaSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/ChatArea.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(contentViewSource.contains("RightPanelSurfaceScope.modeAfterTabChange"))
        XCTAssertTrue(contentViewSource.contains("RightPanelSurfaceScope.modeAfterNewBlankConversation"))
        XCTAssertTrue(chatAreaSource.contains("RightPanelSurfaceScope.modeAfterConversationChange"))
    }

    func testChatHeaderTitleTruncatesBeforeRightPanelControls() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chatAreaSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/ChatArea.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(chatAreaSource.contains("private let headerTrailingControlReserve: CGFloat = 24"))
        XCTAssertTrue(chatAreaSource.contains(".truncationMode(.tail)"))
        XCTAssertTrue(chatAreaSource.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertTrue(chatAreaSource.contains(".padding(.trailing, headerTrailingControlReserve)"))
        XCTAssertFalse(chatAreaSource.contains("rightPanelToggleCapsule"))
        XCTAssertFalse(chatAreaSource.contains("rightPanelToggleButton"))
        XCTAssertFalse(chatAreaSource.contains("systemImage: \"note.text\""))
    }

    func testSummaryCaptureAutoOpensMarkdownPanelInsteadOfHeaderToggle() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contentViewSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/App/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(contentViewSource.contains(".onChange(of: dependencies.scratchPadStore.latestSummary)"))
        XCTAssertTrue(contentViewSource.contains("rightPanelMode = .markdown"))
        XCTAssertTrue(contentViewSource.contains("scratchPadPanelMode = .preview"))
    }

    func testScratchpadInnerSurfaceUsesVisiblePaperStyling() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let panelSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/ScratchPadPanel.swift"),
            encoding: .utf8
        )
        let themeSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Theme/AppColor.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(themeSource.contains("paperSurface"))
        XCTAssertTrue(themeSource.contains("paperText"))
        XCTAssertTrue(themeSource.contains("paperSecondaryText"))
        XCTAssertTrue(panelSource.contains(".fill(AppColor.paperSurface)"))
        XCTAssertTrue(panelSource.contains(".foregroundColor(AppColor.paperText)"))
        XCTAssertTrue(panelSource.contains(".foregroundColor(AppColor.paperSecondaryText)"))
        XCTAssertFalse(panelSource.contains("NativeGlassPanel(cornerRadius: 12, tintColor: AppColor.surfaceGlassTint)"))
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
