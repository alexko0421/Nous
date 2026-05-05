import XCTest
@testable import Nous

final class TemporaryBranchUILayoutTests: XCTestCase {
    func testFocusStyleBlursWholeChatWithoutSourceOutline() {
        XCTAssertEqual(TemporaryBranchFocusStyle.backgroundBlurRadius, 22)
        XCTAssertEqual(TemporaryBranchFocusStyle.backgroundDimOpacity, 0.58)
        XCTAssertFalse(TemporaryBranchFocusStyle.drawsSourceMessageOutline)
    }

    func testTemporaryBranchUsesFocusMembraneInsteadOfModalPanel() throws {
        XCTAssertFalse(TemporaryBranchMembraneStyle.drawsFramedPanel)
        XCTAssertLessThanOrEqual(TemporaryBranchMembraneStyle.inlineComposerMaxWidth, 540)
        XCTAssertLessThanOrEqual(TemporaryBranchMembraneStyle.primaryComposerMinHeight, 54)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/TemporaryBranchOverlay.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("focusMembrane"))
        XCTAssertTrue(source.contains("primaryBranchComposer"))
        XCTAssertTrue(source.contains("TemporaryBranchSourceQuote"))
        XCTAssertTrue(source.contains("TemporaryBranchRecordMarker"))
        XCTAssertFalse(source.contains("private var branchPanel"))
        XCTAssertFalse(source.contains("foregroundMaxWidth"))
        XCTAssertFalse(source.contains("Text(\"SIDE THOUGHT\")"))
    }

    func testTemporaryBranchComposerMatchesMainInputMetrics() throws {
        XCTAssertEqual(
            TemporaryBranchMembraneStyle.primaryComposerMinHeight,
            ComposerTextInputMetrics.minimumControlHeight
        )
        XCTAssertEqual(TemporaryBranchMembraneStyle.primaryComposerCornerRadius, 18)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/TemporaryBranchOverlay.swift"),
            encoding: .utf8
        )
        let textFieldSnippet = try XCTUnwrap(source.range(of: "private var branchTextField"))
            .lowerBound
        let primaryActionSnippet = try XCTUnwrap(source.range(of: "private var branchPrimaryActionButton"))
            .lowerBound
        let branchTextFieldSource = String(source[textFieldSnippet..<primaryActionSnippet])
        let inlineComposerEnd = try XCTUnwrap(source.range(of: "struct TemporaryBranchSourceQuote"))
            .lowerBound
        let inlineComposerSource = String(source[textFieldSnippet..<inlineComposerEnd])

        XCTAssertTrue(branchTextFieldSource.contains(".font(.system(size: 13, weight: .medium, design: .rounded))"))
        XCTAssertTrue(branchTextFieldSource.contains(".lineLimit(1...ComposerTextInputMetrics.maxVisibleLines)"))
        XCTAssertTrue(branchTextFieldSource.contains(".frame(maxWidth: .infinity, minHeight: ComposerTextInputMetrics.minimumTextHeight, alignment: .topLeading)"))
        XCTAssertTrue(branchTextFieldSource.contains(".padding(.vertical, ComposerTextInputMetrics.verticalPadding)"))
        XCTAssertTrue(branchTextFieldSource.contains("NativeGlassPanel("))
        XCTAssertTrue(branchTextFieldSource.contains("cornerRadius: TemporaryBranchMembraneStyle.primaryComposerCornerRadius"))
        XCTAssertTrue(source.contains(".frame(width: 36, height: 36)"))
        XCTAssertFalse(branchTextFieldSource.contains(".lineLimit(1...4)"))
        XCTAssertFalse(branchTextFieldSource.contains(".font(.system(size: 14, weight: .medium, design: .rounded))"))
        XCTAssertFalse(inlineComposerSource.contains("subtleSourceAnchor"))
        XCTAssertFalse(inlineComposerSource.contains("Side thought"))
        XCTAssertFalse(inlineComposerSource.contains("branch.sourceExcerpt"))
    }

    func testTemporaryBranchComposerKeepsSourceQuoteAboveInput() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/TemporaryBranchOverlay.swift"),
            encoding: .utf8
        )
        let composerStackStart = try XCTUnwrap(source.range(of: "private var composerStack"))
            .lowerBound
        let textFieldStart = try XCTUnwrap(source.range(of: "private var branchTextField"))
            .lowerBound
        let composerStackSource = String(source[composerStackStart..<textFieldStart])

        XCTAssertTrue(composerStackSource.contains("TemporaryBranchSourceQuote("))
        XCTAssertTrue(composerStackSource.contains("primaryBranchComposer"))
        XCTAssertLessThan(
            try XCTUnwrap(composerStackSource.range(of: "TemporaryBranchSourceQuote(")).lowerBound,
            try XCTUnwrap(composerStackSource.range(of: "primaryBranchComposer")).lowerBound
        )
    }

    func testBranchSourceQuoteUsesFixedHeightMarker() throws {
        XCTAssertEqual(TemporaryBranchMembraneStyle.sourceQuoteMarkerHeight, 32)
        XCTAssertEqual(TemporaryBranchMembraneStyle.recordMarkerHeight, 64)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/TemporaryBranchOverlay.swift"),
            encoding: .utf8
        )
        let quoteStart = try XCTUnwrap(source.range(of: "struct TemporaryBranchSourceQuote"))
            .lowerBound
        let transcriptStart = try XCTUnwrap(source.range(of: "struct TemporaryBranchTranscript"))
            .lowerBound
        let quoteSource = String(source[quoteStart..<transcriptStart])
        let recordStart = try XCTUnwrap(source.range(of: "struct TemporaryBranchRecordMarker"))
            .lowerBound
        let bubbleStart = try XCTUnwrap(source.range(of: "private struct TemporaryBranchBubble"))
            .lowerBound
        let recordSource = String(source[recordStart..<bubbleStart])

        XCTAssertTrue(quoteSource.contains(".frame(width: 3, height: TemporaryBranchMembraneStyle.sourceQuoteMarkerHeight)"))
        XCTAssertTrue(quoteSource.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(quoteSource.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertFalse(quoteSource.contains("if isUserSource"))
        XCTAssertTrue(recordSource.contains(".frame(width: 3, height: TemporaryBranchMembraneStyle.recordMarkerHeight)"))
        XCTAssertTrue(recordSource.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertFalse(recordSource.contains("if isUserSource"))
    }

    func testBranchComposerDoesNotShiftSourceRailToUserSide() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/TemporaryBranchOverlay.swift"),
            encoding: .utf8
        )
        let composerStart = try XCTUnwrap(source.range(of: "struct TemporaryBranchInlineComposer"))
            .lowerBound
        let quoteStart = try XCTUnwrap(source.range(of: "struct TemporaryBranchSourceQuote"))
            .lowerBound
        let composerSource = String(source[composerStart..<quoteStart])

        XCTAssertTrue(composerSource.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertFalse(composerSource.contains("alignment: isUserSource ? .trailing : .leading"))
        XCTAssertFalse(composerSource.contains("TemporaryBranchSourceQuote(branch: branch, isUserSource: isUserSource)"))
    }

    func testBranchTranscriptUsesRegularChatBubbleSizing() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/TemporaryBranchOverlay.swift"),
            encoding: .utf8
        )
        let bubbleStart = try XCTUnwrap(source.range(of: "private struct TemporaryBranchBubble"))
            .lowerBound
        let triggerStart = try XCTUnwrap(source.range(of: "struct TemporaryBranchTriggerButton"))
            .lowerBound
        let bubbleSource = String(source[bubbleStart..<triggerStart])

        XCTAssertTrue(bubbleSource.contains("private let bubbleMaxWidth: CGFloat = 520"))
        XCTAssertTrue(bubbleSource.contains(".font(.system(size: 14, weight: .regular))"))
        XCTAssertTrue(bubbleSource.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(bubbleSource.contains("Text(text)\n                .font(.system(size: 14, weight: .regular))\n                .lineSpacing(6)\n                .foregroundStyle(isUser ? Color.white : AppColor.colaDarkText)\n                .padding(.horizontal, 16)\n                .padding(.vertical, 12)\n                .frame(maxWidth: bubbleMaxWidth"))
        XCTAssertFalse(bubbleSource.contains(".font(.system(size: 15, weight: .medium, design: .rounded))"))
        XCTAssertFalse(bubbleSource.contains("Spacer(minLength: 70)"))
    }

    func testBranchTranscriptUsesNormalChatAlignmentAndThinkingIndicator() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/TemporaryBranchOverlay.swift"),
            encoding: .utf8
        )
        let transcriptStart = try XCTUnwrap(source.range(of: "struct TemporaryBranchTranscript"))
            .lowerBound
        let recordStart = try XCTUnwrap(source.range(of: "struct TemporaryBranchRecordMarker"))
            .lowerBound
        let transcriptSource = String(source[transcriptStart..<recordStart])

        XCTAssertFalse(transcriptSource.contains("let isUserSource"))
        XCTAssertFalse(transcriptSource.contains("if isUserSource"))
        XCTAssertTrue(transcriptSource.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertTrue(transcriptSource.contains("TemporaryBranchPendingThinking("))
        XCTAssertTrue(transcriptSource.contains("branch.isGenerating"))
        XCTAssertTrue(transcriptSource.contains("ThinkingAccordion("))
    }

    func testBranchAssistantRepliesUseNormalAssistantTextAndActionRow() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/TemporaryBranchOverlay.swift"),
            encoding: .utf8
        )
        let bubbleStart = try XCTUnwrap(source.range(of: "private struct TemporaryBranchBubble"))
            .lowerBound
        let closeButtonStart = try XCTUnwrap(source.range(of: "struct TemporaryBranchCloseButton"))
            .lowerBound
        let bubbleSource = String(source[bubbleStart..<closeButtonStart])

        XCTAssertTrue(bubbleSource.contains("AssistantBubbleContent(displayText: text)"))
        XCTAssertTrue(bubbleSource.contains("TemporaryBranchAssistantActions("))
        XCTAssertTrue(bubbleSource.contains("CopyButton(text: text)"))
        XCTAssertTrue(bubbleSource.contains("arrow.clockwise"))
        XCTAssertFalse(bubbleSource.contains(".background(isUser ? AppColor.colaOrange.opacity(0.86) : AppColor.colaBubble)"))
    }

    func testBranchTriggerUsesMessageLongPressAndStableHoverHitTarget() throws {
        XCTAssertEqual(TemporaryBranchTriggerHitTarget.longPressDuration, 0.35)
        XCTAssertGreaterThanOrEqual(TemporaryBranchTriggerHitTarget.hoverBridgePadding, 10)
        XCTAssertGreaterThanOrEqual(TemporaryBranchTriggerHitTarget.userButtonOutsideOffset, 44)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/ChatArea.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".onLongPressGesture(minimumDuration: TemporaryBranchTriggerHitTarget.longPressDuration)"))
        XCTAssertTrue(source.contains("TemporaryBranchTriggerHitTarget.hoverBridgePadding"))
        XCTAssertTrue(source.contains("width: -TemporaryBranchTriggerHitTarget.userButtonOutsideOffset"))
        XCTAssertFalse(source.contains(".offset(x: isUser ? -32 : 32, y: 2)"))
    }

    func testBranchTriggerUsesCalmBranchSymbolInsteadOfChatBubbleIcon() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/TemporaryBranchOverlay.swift"),
            encoding: .utf8
        )
        let triggerStart = try XCTUnwrap(source.range(of: "struct TemporaryBranchTriggerButton"))
            .lowerBound
        let triggerSource = String(source[triggerStart...])

        XCTAssertTrue(triggerSource.contains("Image(systemName: \"arrow.triangle.branch\")"))
        XCTAssertTrue(triggerSource.contains("AppColor.colaOrange"))
        XCTAssertFalse(triggerSource.contains("bubble.left.and.bubble.right"))
    }

    func testChatAreaHostsTemporaryBranchAtBottomRail() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/ChatArea.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("temporaryBranchBottomRail"))
        XCTAssertTrue(source.contains("TemporaryBranchInlineComposer("))
        XCTAssertTrue(source.contains("branchFocusBlurRadius(for: msg)"))
        XCTAssertTrue(source.contains("isTemporaryBranchSource(msg)"))
        XCTAssertTrue(source.contains("TemporaryBranchRecordMarker("))
        XCTAssertTrue(source.contains("record(for: msg.id)"))
        XCTAssertTrue(source.contains("persistTemporaryBranchRecord(record)"))
        XCTAssertTrue(source.contains("temporaryBranch.reset(records: vm.loadTemporaryBranchRecords())"))
        XCTAssertTrue(source.contains("TemporaryBranchCloseButton("))
        XCTAssertFalse(source.contains("TemporaryBranchSourceQuote("))
        XCTAssertFalse(source.contains("TemporaryBranchFocusPill("))
        XCTAssertFalse(source.contains(".blur(radius: branchBackgroundBlurRadius)\n                    .opacity(branchBackgroundOpacity)\n                    .allowsHitTesting(!temporaryBranch.isPresented)"))
        XCTAssertFalse(source.contains("TemporaryBranchOverlay("))
        XCTAssertFalse(source.contains(".scaleEffect(temporaryBranch.isPresented ? 1.012 : 1)"))
    }

    func testBranchMarkerSurfacesMemoryCandidateActions() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/TemporaryBranchOverlay.swift"),
            encoding: .utf8
        )
        let recordStart = try XCTUnwrap(source.range(of: "struct TemporaryBranchRecordMarker"))
            .lowerBound
        let bubbleStart = try XCTUnwrap(source.range(of: "private struct TemporaryBranchBubble"))
            .lowerBound
        let recordSource = String(source[recordStart..<bubbleStart])

        XCTAssertTrue(recordSource.contains("Worth remembering"))
        XCTAssertTrue(recordSource.contains("Save to Project"))
        XCTAssertTrue(recordSource.contains("Save to Memory"))
        XCTAssertTrue(recordSource.contains("Ignore"))
        XCTAssertTrue(recordSource.contains("Saved to Project Memory"))
        XCTAssertTrue(recordSource.contains("Saved to Long-term Memory"))
        XCTAssertTrue(recordSource.contains("onMemoryCandidateAction"))
        XCTAssertTrue(recordSource.contains("ForEach(visibleMemoryCandidates)"))
        XCTAssertTrue(recordSource.contains("Save to Thread"))
        XCTAssertTrue(recordSource.contains("$0.scope != .ignore"))
        XCTAssertFalse(recordSource.contains("record.memoryCandidates.first"))
    }
}
