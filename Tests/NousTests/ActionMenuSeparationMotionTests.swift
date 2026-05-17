import XCTest
@testable import Nous

final class ActionMenuSeparationMotionTests: XCTestCase {
    func testCollapsedCapsuleUsesGroundedGlassStartingPose() {
        let motion = ActionMenuSeparationMotion()

        XCTAssertEqual(motion.capsuleOffset(isExpanded: false).width, 0)
        XCTAssertEqual(motion.capsuleOffset(isExpanded: false).height, 7)
        XCTAssertEqual(motion.capsuleScale(isExpanded: false).width, 0.97)
        XCTAssertEqual(motion.capsuleScale(isExpanded: false).height, 0.97)
        XCTAssertEqual(motion.capsuleScale(isExpanded: true).width, 1)
        XCTAssertEqual(motion.capsuleScale(isExpanded: true).height, 1)
    }

    func testCollapsedItemsStayInsideSharedCapsule() {
        let motion = ActionMenuSeparationMotion()

        XCTAssertEqual(motion.itemOffset(for: 0, isExpanded: false), .zero)
        XCTAssertEqual(motion.itemOffset(for: 1, isExpanded: false), .zero)
        XCTAssertEqual(motion.itemOffset(for: 2, isExpanded: false), .zero)
    }

    func testOpeningDelaysUseSoftStaggerCadenceInsideCapsule() {
        let motion = ActionMenuSeparationMotion()

        XCTAssertLessThan(motion.delay(for: 0, isExpanded: true), motion.delay(for: 1, isExpanded: true))
        XCTAssertLessThan(motion.delay(for: 1, isExpanded: true), motion.delay(for: 2, isExpanded: true))
        XCTAssertEqual(
            motion.delay(for: 1, isExpanded: true) - motion.delay(for: 0, isExpanded: true),
            0.024,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            motion.delay(for: 1, isExpanded: true) - motion.delay(for: 0, isExpanded: true),
            motion.delay(for: 0, isExpanded: false) - motion.delay(for: 1, isExpanded: false),
            accuracy: 0.0001
        )
    }

    func testClosingDelaysReverseBackTowardSource() {
        let motion = ActionMenuSeparationMotion()

        XCTAssertGreaterThan(motion.delay(for: 0, isExpanded: false), motion.delay(for: 1, isExpanded: false))
        XCTAssertGreaterThan(motion.delay(for: 1, isExpanded: false), motion.delay(for: 2, isExpanded: false))
    }

    func testCollapsedCapsuleDoesNotUseBlurTrail() {
        let motion = ActionMenuSeparationMotion()

        XCTAssertEqual(motion.capsuleBlur(isExpanded: false), 0)
        XCTAssertEqual(motion.capsuleBlur(isExpanded: true), 0)
    }

    func testComposerPrimaryActionStaysJoinedWhenIdle() {
        XCTAssertFalse(ComposerSeparationPolicy.shouldSeparate(
            inputText: "",
            hasAttachments: false,
            isGenerating: false
        ))
        XCTAssertFalse(ComposerSeparationPolicy.shouldSeparate(
            inputText: "   \n",
            hasAttachments: false,
            isGenerating: false
        ))
    }

    func testComposerPrimaryActionSeparatesForTypingAttachmentsOrGeneration() {
        XCTAssertTrue(ComposerSeparationPolicy.shouldSeparate(
            inputText: "What changed today?",
            hasAttachments: false,
            isGenerating: false
        ))
        XCTAssertTrue(ComposerSeparationPolicy.shouldSeparate(
            inputText: "",
            hasAttachments: true,
            isGenerating: false
        ))
        XCTAssertTrue(ComposerSeparationPolicy.shouldSeparate(
            inputText: "",
            hasAttachments: false,
            isGenerating: true
        ))
    }

    func testComposerPrimaryActionLooksAbsorbedWhenIdle() {
        let motion = ComposerPrimaryActionMotion()

        XCTAssertEqual(motion.tintAlpha(isSeparated: false, canAct: false), 0)
        XCTAssertEqual(motion.fillOpacity(isSeparated: false, canAct: false), 0)
        XCTAssertEqual(motion.glowOpacity(isSeparated: false, canAct: false), 0)
        XCTAssertEqual(motion.iconOpacity(isSeparated: false), 0)
    }

    func testComposerPrimaryActionSeparatesWithoutTransientAccentWhenActivated() {
        let motion = ComposerPrimaryActionMotion()

        XCTAssertGreaterThan(motion.tintAlpha(isSeparated: true, canAct: true), 0.8)
        XCTAssertGreaterThan(motion.fillOpacity(isSeparated: true, canAct: true), 0.75)
        XCTAssertLessThan(motion.fillOpacity(isSeparated: true, canAct: false), 0.25)
        XCTAssertLessThan(motion.glowOpacity(isSeparated: true, canAct: true), 0.16)
        XCTAssertEqual(motion.iconOpacity(isSeparated: true), 1)
    }

    func testComposerLeadingActionPopsOutQuietlyWhenExpanded() {
        let motion = ComposerLeadingActionMotion()

        XCTAssertEqual(motion.scale(isSeparated: false), 1)
        XCTAssertEqual(motion.yOffset(isSeparated: false), 0)
        XCTAssertEqual(motion.fillOpacity(isSeparated: false), 0)
        XCTAssertEqual(motion.glowOpacity(isSeparated: false), 0)
        XCTAssertEqual(motion.tintAlpha(isSeparated: false), 0)

        XCTAssertGreaterThan(motion.scale(isSeparated: true), 1)
        XCTAssertLessThan(motion.scale(isSeparated: true), 1.05)
        XCTAssertLessThan(motion.yOffset(isSeparated: true), 0)
        XCTAssertGreaterThan(motion.yOffset(isSeparated: true), -0.75)
        XCTAssertGreaterThan(motion.fillOpacity(isSeparated: true), 0.3)
        XCTAssertLessThan(motion.fillOpacity(isSeparated: true), 0.38)
        XCTAssertGreaterThan(motion.tintAlpha(isSeparated: true), 0.4)
        XCTAssertLessThan(motion.tintAlpha(isSeparated: true), 0.5)
        XCTAssertGreaterThan(motion.glowOpacity(isSeparated: true), 0.045)
        XCTAssertLessThan(motion.glowOpacity(isSeparated: true), 0.065)
    }

    func testComposerPlusButtonsUseSharedPopoutControl() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chatSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/ChatArea.swift"),
            encoding: .utf8
        )
        let welcomeSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/WelcomeView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(chatSource.contains("ComposerLeadingActionButton("))
        XCTAssertTrue(welcomeSource.contains("ComposerLeadingActionButton("))
        XCTAssertTrue(chatSource.contains("value: isActionMenuExpanded"))
        XCTAssertTrue(welcomeSource.contains("value: isActionMenuExpanded"))

        let leadingButtonStart = try XCTUnwrap(chatSource.range(of: "struct ComposerLeadingActionButton"))
        let leadingButtonEnd = try XCTUnwrap(chatSource.range(of: "struct ActionMenuCapsule"))
        let leadingButtonSource = String(chatSource[leadingButtonStart.lowerBound..<leadingButtonEnd.lowerBound])
        XCTAssertTrue(leadingButtonSource.contains(".foregroundColor(iconColor)"))
        XCTAssertTrue(leadingButtonSource.contains("isSeparated ? AppColor.colaOrange : AppColor.secondaryText"))
        XCTAssertTrue(leadingButtonSource.contains("private var tintColor: NSColor"))
        XCTAssertTrue(leadingButtonSource.contains("red: 243 / 255"))
        XCTAssertTrue(leadingButtonSource.contains("AppColor.colaOrange.opacity(motion.fillOpacity(isSeparated: isSeparated))"))
        XCTAssertTrue(leadingButtonSource.contains("AppColor.colaOrange.opacity(motion.glowOpacity(isSeparated: isSeparated))"))
        XCTAssertTrue(leadingButtonSource.contains("isSeparated ? AppColor.colaOrange.opacity(0.28) : AppColor.composerInputGlassStroke"))
        XCTAssertTrue(leadingButtonSource.contains("AppColor.composerInputGlassTint"))
        XCTAssertTrue(leadingButtonSource.contains("AppColor.composerInputGlassOverlay"))
        XCTAssertTrue(leadingButtonSource.contains("AppColor.composerInputGlassStroke"))
        XCTAssertFalse(leadingButtonSource.contains(".foregroundColor(isSeparated ? .white : AppColor.secondaryText)"))
        XCTAssertFalse(leadingButtonSource.contains("rotationEffect"))
    }

    func testComposerPrimaryActionHasNoFusionPulseImplementation() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productionFiles = [
            "Sources/Nous/Models/ActionMenuSeparationMotion.swift",
            "Sources/Nous/Views/ChatArea.swift",
            "Sources/Nous/Views/WelcomeView.swift"
        ]

        for relativePath in productionFiles {
            let fileURL = repoRoot.appendingPathComponent(relativePath)
            let source = try String(contentsOf: fileURL, encoding: .utf8)

            XCTAssertFalse(source.contains("FusionPulse"), relativePath)
            XCTAssertFalse(source.contains("fusionPulse"), relativePath)
        }
    }

    func testGlassHierarchyUsesExplicitSurfaceAndControlTiers() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let themeSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Theme/AppColor.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(themeSource.contains("composerGlassTint"))
        XCTAssertTrue(themeSource.contains("surfaceGlassTint"))
        XCTAssertTrue(themeSource.contains("controlGlassTint"))

        let sourceRoot = repoRoot.appendingPathComponent("Sources/Nous")
        let swiftFiles = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        for fileURL in swiftFiles {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertFalse(source.contains("AppColor.glassTint"), fileURL.path)
        }

        let controlFiles = [
            "Sources/Nous/Views/ChatArea.swift",
            "Sources/Nous/Views/WelcomeView.swift"
        ]

        for relativePath in controlFiles {
            let fileURL = repoRoot.appendingPathComponent(relativePath)
            let source = try String(contentsOf: fileURL, encoding: .utf8)

            XCTAssertFalse(source.contains("AppColor.composerGlassTint"), relativePath)
            XCTAssertTrue(source.contains("tintColor: AppColor.controlGlassTint"), relativePath)
        }

        let surfaceTintExpectations = [
            "Sources/Nous/Views/LeftSidebar.swift": "tintColor: AppColor.sidebarGlassTint",
            "Sources/Nous/Views/ScratchPadPanel.swift": "tintColor: AppColor.surfaceGlassTint",
            "Sources/Nous/Views/GalaxyView.swift": "tintColor: AppColor.surfaceGlassTint"
        ]

        for (relativePath, expectedTint) in surfaceTintExpectations {
            let fileURL = repoRoot.appendingPathComponent(relativePath)
            let source = try String(contentsOf: fileURL, encoding: .utf8)

            XCTAssertTrue(source.contains(expectedTint), relativePath)
        }
    }

    func testComposerMenuUsesWeightedSharedGlassSurfaces() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let themeSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Theme/AppColor.swift"),
            encoding: .utf8
        )
        let chatSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/ChatArea.swift"),
            encoding: .utf8
        )
        let welcomeSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/WelcomeView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(themeSource.contains("composerInputGlassTint"))
        XCTAssertTrue(themeSource.contains("composerMenuGlassTint"))
        XCTAssertTrue(themeSource.contains("static let composerInputGlassTint = sidebarGlassTint"))
        XCTAssertTrue(themeSource.contains("static let composerInputGlassOverlay = sidebarGlassVeil"))
        XCTAssertTrue(themeSource.contains("static let composerInputGlassStroke = sidebarGlassStroke"))
        XCTAssertTrue(themeSource.contains("static let composerMenuGlassTint = composerInputGlassTint"))
        XCTAssertTrue(themeSource.contains("static let composerMenuGlassOverlay = composerInputGlassOverlay"))
        XCTAssertTrue(themeSource.contains("static let composerMenuGlassStroke = composerInputGlassStroke"))
        XCTAssertTrue(chatSource.contains("ComposerTextInputGlassBackground(cornerRadius: 18)"))
        XCTAssertTrue(welcomeSource.contains("ComposerTextInputGlassBackground(cornerRadius: 18)"))
        XCTAssertTrue(chatSource.contains("ComposerActionMenuGlassBackground"))
        let menuBackgroundStart = try XCTUnwrap(chatSource.range(of: "struct ComposerActionMenuGlassBackground"))
        let menuBackgroundEnd = try XCTUnwrap(chatSource.range(of: "struct ComposerLeadingActionButton"))
        let menuBackgroundSource = String(chatSource[menuBackgroundStart.lowerBound..<menuBackgroundEnd.lowerBound])
        XCTAssertTrue(menuBackgroundSource.contains("tintColor: AppColor.composerMenuGlassTint"))
        XCTAssertTrue(menuBackgroundSource.contains(".fill(AppColor.composerMenuGlassOverlay)"))
        XCTAssertTrue(menuBackgroundSource.contains(".stroke(AppColor.composerMenuGlassStroke, lineWidth: 1)"))
        XCTAssertFalse(menuBackgroundSource.contains("LinearGradient"))
        XCTAssertFalse(chatSource.contains("ActionMenuAnchorBridge"))
        XCTAssertFalse(chatSource.contains("topHighlightOpacity"))
        XCTAssertFalse(chatSource.contains("midHighlightOpacity"))
        XCTAssertFalse(chatSource.contains("bottomShadeOpacity"))
        XCTAssertFalse(chatSource.contains("overlayColor: AppColor.composerMatteOverlay"))
        XCTAssertFalse(welcomeSource.contains("overlayColor: AppColor.composerMatteOverlay"))
    }

    func testWelcomeQuickActionsUseQuietControlGlassChips() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/WelcomeView.swift"),
            encoding: .utf8
        )
        guard let buttonRange = source.range(of: "struct QuickActionButton") else {
            XCTFail("QuickActionButton should exist in WelcomeView.swift")
            return
        }
        let buttonSource = String(source[buttonRange.lowerBound...])

        XCTAssertTrue(buttonSource.contains("tintColor: AppColor.controlGlassTint"))
        XCTAssertTrue(buttonSource.contains(".font(.system(size: 10.5, weight: .semibold, design: .rounded))"))
        XCTAssertTrue(buttonSource.contains(".padding(.horizontal, 11)"))
        XCTAssertTrue(buttonSource.contains(".padding(.vertical, 6)"))
        XCTAssertTrue(buttonSource.contains(".frame(height: 30)"))
        XCTAssertTrue(buttonSource.contains("AppColor.colaOrange.opacity(0.035)"))
        XCTAssertTrue(buttonSource.contains("AppColor.panelStroke.opacity(0.68)"))
        XCTAssertTrue(buttonSource.contains(".scaleEffect(isHovered ? 1.02 : 1.0)"))
    }
}
