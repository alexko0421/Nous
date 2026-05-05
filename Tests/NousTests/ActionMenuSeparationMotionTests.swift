import XCTest
@testable import Nous

final class ActionMenuSeparationMotionTests: XCTestCase {
    func testCollapsedCapsuleStaysConnectedAtPlusSource() {
        let motion = ActionMenuSeparationMotion(
            sourceYOffset: 46,
            collapsedScale: CGSize(width: 0.24, height: 0.68)
        )

        XCTAssertEqual(motion.capsuleOffset(isExpanded: false).width, 0)
        XCTAssertEqual(motion.capsuleOffset(isExpanded: false).height, 46)
        XCTAssertEqual(motion.capsuleScale(isExpanded: false).width, 0.24)
        XCTAssertEqual(motion.capsuleScale(isExpanded: false).height, 0.68)
        XCTAssertEqual(motion.capsuleScale(isExpanded: true).width, 1)
        XCTAssertEqual(motion.capsuleScale(isExpanded: true).height, 1)
    }

    func testCollapsedItemsStayInsideSharedCapsule() {
        let motion = ActionMenuSeparationMotion()

        XCTAssertEqual(motion.itemOffset(for: 0, isExpanded: false), .zero)
        XCTAssertEqual(motion.itemOffset(for: 1, isExpanded: false), .zero)
        XCTAssertEqual(motion.itemOffset(for: 2, isExpanded: false), .zero)
    }

    func testOpeningDelaysUseClosingCadenceInsideCapsule() {
        let motion = ActionMenuSeparationMotion()

        XCTAssertLessThan(motion.delay(for: 0, isExpanded: true), motion.delay(for: 1, isExpanded: true))
        XCTAssertLessThan(motion.delay(for: 1, isExpanded: true), motion.delay(for: 2, isExpanded: true))
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
        XCTAssertGreaterThan(motion.yOffset(isSeparated: true), -1.25)
        XCTAssertGreaterThan(motion.fillOpacity(isSeparated: true), 0.2)
        XCTAssertLessThan(motion.fillOpacity(isSeparated: true), 0.36)
        XCTAssertGreaterThan(motion.tintAlpha(isSeparated: true), 0.3)
        XCTAssertLessThan(motion.tintAlpha(isSeparated: true), 0.46)
        XCTAssertGreaterThan(motion.glowOpacity(isSeparated: true), 0.03)
        XCTAssertLessThan(motion.glowOpacity(isSeparated: true), 0.09)
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

        let leadingButtonRange = try XCTUnwrap(chatSource.range(of: "struct ComposerLeadingActionButton"))
        let leadingButtonSource = String(chatSource[leadingButtonRange.lowerBound...])
        XCTAssertTrue(leadingButtonSource.contains(".foregroundColor(iconColor)"))
        XCTAssertFalse(leadingButtonSource.contains(".foregroundColor(isSeparated ? .white : AppColor.secondaryText)"))
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

        let surfaceFiles = [
            "Sources/Nous/Views/LeftSidebar.swift",
            "Sources/Nous/Views/ScratchPadPanel.swift",
            "Sources/Nous/Views/GalaxyView.swift"
        ]

        for relativePath in surfaceFiles {
            let fileURL = repoRoot.appendingPathComponent(relativePath)
            let source = try String(contentsOf: fileURL, encoding: .utf8)

            XCTAssertTrue(source.contains("tintColor: AppColor.surfaceGlassTint"), relativePath)
        }
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
