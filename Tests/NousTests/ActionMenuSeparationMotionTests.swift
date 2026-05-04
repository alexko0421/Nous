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

    func testComposerGlassUsesSharedGlassTexture() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let themeSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Theme/AppColor.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(themeSource.contains("composerGlassTint"))

        let composerFiles = [
            "Sources/Nous/Views/ChatArea.swift",
            "Sources/Nous/Views/WelcomeView.swift"
        ]

        for relativePath in composerFiles {
            let fileURL = repoRoot.appendingPathComponent(relativePath)
            let source = try String(contentsOf: fileURL, encoding: .utf8)

            XCTAssertFalse(source.contains("AppColor.composerGlassTint"), relativePath)
            XCTAssertTrue(source.contains("tintColor: AppColor.glassTint"), relativePath)
        }
    }
}
