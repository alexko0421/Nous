import XCTest
import AppKit
@testable import Nous

final class ChatMarkdownRendererTests: XCTestCase {

    // MARK: - Foundation

    func testEmptyInputReturnsEmptySegments() {
        XCTAssertEqual(ChatMarkdownRenderer.parse("").count, 0)
    }

    // MARK: - Headings

    func testH1Heading() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("# Title"),
            [.heading(level: 1, text: "Title")]
        )
    }

    func testH2Heading() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("## Subtitle"),
            [.heading(level: 2, text: "Subtitle")]
        )
    }

    func testH3PlusFallsToProse() {
        // v1 only supports # and ##; ### should NOT be a heading.
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("### h3"),
            [.prose("### h3")]
        )
    }

    func testHashWithoutSpaceIsNotHeading() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("#NotAHeading"),
            [.prose("#NotAHeading")]
        )
    }

    func testDoubleHashWithoutSpaceIsNotHeading() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("##NotAHeading"),
            [.prose("##NotAHeading")]
        )
    }

    func testHeadingTextTrimsTrailingWhitespace() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("# Title   "),
            [.heading(level: 1, text: "Title")]
        )
    }

    // MARK: - Bullets

    func testSingleBullet() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("- one"),
            [.bulletBlock(["one"])]
        )
    }

    func testConsecutiveBulletsGroupIntoOneBlock() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("- one\n- two\n- three"),
            [.bulletBlock(["one", "two", "three"])]
        )
    }

    func testBulletBlockEndsOnNonBulletLine() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("- one\n- two\nNot a bullet"),
            [.bulletBlock(["one", "two"]), .prose("Not a bullet")]
        )
    }

    func testBulletWithoutSpaceIsProse() {
        // "-foo" without space after - is not a bullet.
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("-foo"),
            [.prose("-foo")]
        )
    }

    func testBulletContentTrimmed() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("-   indented bullet"),
            [.bulletBlock(["indented bullet"])]
        )
    }

    func testHeadingFollowedByBullets() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("# Title\n- one\n- two"),
            [.heading(level: 1, text: "Title"), .bulletBlock(["one", "two"])]
        )
    }

    func testBulletsFollowedByHeading() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("- one\n- two\n# Section"),
            [.bulletBlock(["one", "two"]), .heading(level: 1, text: "Section")]
        )
    }

    // MARK: - Tables

    func testStandardTable() {
        let input = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        XCTAssertEqual(
            ChatMarkdownRenderer.parse(input),
            [.table(headers: ["a", "b"], rows: [["1", "2"]])]
        )
    }

    func testTableTightSeparator() {
        let input = "| a | b |\n|---|---|\n| 1 | 2 |"
        XCTAssertEqual(
            ChatMarkdownRenderer.parse(input),
            [.table(headers: ["a", "b"], rows: [["1", "2"]])]
        )
    }

    func testTableAlignmentMarkersAccepted() {
        // v1 ignores alignment but must parse without rejection.
        let input = "| a | b |\n| :--- | ---: |\n| 1 | 2 |"
        XCTAssertEqual(
            ChatMarkdownRenderer.parse(input),
            [.table(headers: ["a", "b"], rows: [["1", "2"]])]
        )
    }

    func testTableMultipleDataRows() {
        let input = "| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |"
        XCTAssertEqual(
            ChatMarkdownRenderer.parse(input),
            [.table(headers: ["a", "b"], rows: [["1", "2"], ["3", "4"]])]
        )
    }

    func testTableWithoutSeparatorFallsToProse() {
        let input = "| a | b |\n| 1 | 2 |"
        XCTAssertEqual(
            ChatMarkdownRenderer.parse(input),
            [.prose("| a | b |"), .prose("| 1 | 2 |")]
        )
    }

    func testTableRaggedRowsNormalize() {
        // Row missing a cell gets right-padded; row with too many gets truncated.
        let input = "| a | b | c |\n| --- | --- | --- |\n| 1 | 2 |\n| 3 | 4 | 5 | 6 |"
        XCTAssertEqual(
            ChatMarkdownRenderer.parse(input),
            [.table(headers: ["a", "b", "c"], rows: [["1", "2", ""], ["3", "4", "5"]])]
        )
    }

    func testTableEscapedPipeIsLiteral() {
        let input = "| a | b |\n| --- | --- |\n| 1 \\| pipe | 2 |"
        XCTAssertEqual(
            ChatMarkdownRenderer.parse(input),
            [.table(headers: ["a", "b"], rows: [["1 | pipe", "2"]])]
        )
    }

    func testProsePipeDoesNotTriggerTable() {
        // Single prose line containing "|" is not a table candidate (no separator row).
        let input = "use cmd | grep foo"
        XCTAssertEqual(
            ChatMarkdownRenderer.parse(input),
            [.prose("use cmd | grep foo")]
        )
    }

    func testBorderlessGFMFallsToProse() {
        // v1 explicitly out of scope: no leading/trailing pipes.
        let input = "a | b\n--- | ---\n1 | 2"
        XCTAssertEqual(
            ChatMarkdownRenderer.parse(input),
            [.prose("a | b"), .prose("--- | ---"), .prose("1 | 2")]
        )
    }

    func testTableSeparatorRowStaysInTable() {
        let input = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        XCTAssertEqual(
            ChatMarkdownRenderer.parse(input),
            [.table(headers: ["a", "b"], rows: [["1", "2"]])]
        )
    }

    // MARK: - Horizontal rules

    func testStandaloneDashLineProducesHorizontalRule() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("---"),
            [.horizontalRule]
        )
    }

    // MARK: - Code fences

    func testClosedFenceProducesVerbatim() {
        let input = "```\nint *p = `foo`;\n```"
        XCTAssertEqual(
            ChatMarkdownRenderer.parse(input),
            [.verbatim("int *p = `foo`;")]
        )
    }

    func testClosedFenceMultilineContent() {
        let input = "```\nline1\nline2\nline3\n```"
        XCTAssertEqual(
            ChatMarkdownRenderer.parse(input),
            [.verbatim("line1\nline2\nline3")]
        )
    }

    func testFenceContentNotSanitized() {
        // **bold** and *italic* inside fence must survive.
        let input = "```\n**bold**\n*italic*\n```"
        XCTAssertEqual(
            ChatMarkdownRenderer.parse(input),
            [.verbatim("**bold**\n*italic*")]
        )
    }

    func testUnclosedFenceFallsBackToProseAndStructure() {
        // Bare ``` line is prose; captured content re-fed to normal parsing.
        let input = "```\nint *p\n# Header\n- bullet"
        XCTAssertEqual(
            ChatMarkdownRenderer.parse(input),
            [
                .prose("```"),
                .prose("int *p"),
                .heading(level: 1, text: "Header"),
                .bulletBlock(["bullet"])
            ]
        )
    }

    func testFenceWithLanguageTagStillVerbatim() {
        // ```swift opens a fence; language tag is dropped, content captured.
        let input = "```swift\nlet x = 1\n```"
        XCTAssertEqual(
            ChatMarkdownRenderer.parse(input),
            [.verbatim("let x = 1")]
        )
    }

    // MARK: - Sanitization (balanced pairs only, no underscores)

    func testBoldStripped() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("**bold** text"),
            [.prose("bold text")]
        )
    }

    func testItalicAsteriskStripped() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("*italic* text"),
            [.prose("italic text")]
        )
    }

    func testInlineCodeStripped() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("use `cmd` here"),
            [.prose("use cmd here")]
        )
    }

    func testTripleStarBoldItalicStripped() {
        // Guards the bold-before-italic ordering invariant in sanitizeProse.
        // If italic ran before bold, this would leave `*bold-italic*` residue.
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("***bold-italic***"),
            [.prose("bold-italic")]
        )
    }

    func testOrderedListPrefixStripped() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("1. first\n2. second"),
            [.prose("first"), .prose("second")]
        )
    }

    func testQuotePrefixStripped() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("> quoted"),
            [.prose("quoted")]
        )
    }

    // Preservation cases — must NOT be touched

    func testUnbalancedAsteriskPreserved() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("int *p = NULL"),
            [.prose("int *p = NULL")]
        )
    }

    func testWildcardAsteriskPreserved() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("rg '*.swift'"),
            [.prose("rg '*.swift'")]
        )
    }

    func testMultiplicationPreserved() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("3 * 4 = 12"),
            [.prose("3 * 4 = 12")]
        )
    }

    func testMultiplicationWithVariablePreserved() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("2 * x = 4"),
            [.prose("2 * x = 4")]
        )
    }

    func testUnderscoreItalicPreserved() {
        // v1 explicitly does not strip underscores.
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("snake_case_var"),
            [.prose("snake_case_var")]
        )
    }

    func testDoubleUnderscorePreserved() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("__init__ method"),
            [.prose("__init__ method")]
        )
    }

    func testUnbalancedBacktickPreserved() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("the ` symbol alone"),
            [.prose("the ` symbol alone")]
        )
    }

    func testHeadingTextNotSanitized() {
        // Sanitization applies only to prose segments, not heading text.
        // (Heading content rarely needs sanitization in practice; documenting current behavior.)
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("# **bold** title"),
            [.heading(level: 1, text: "**bold** title")]
        )
    }

    func testBulletContentSanitized() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("- **item**"),
            [.bulletBlock(["item"])]
        )
    }

    // MARK: - Visual line splitting

    func testVisualLineBreaksWrapLongProseAtFixedWidth() {
        let text = "This is a calm assistant reply that should wrap into multiple visible lines."
        let lines = VisualLineBreaks.lines(
            for: text,
            width: 150,
            font: .systemFont(ofSize: 14, weight: .regular)
        )

        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertEqual(lines.joined(), text)
    }

    func testVisualLineBreaksKeepsShortProseAsOneLine() {
        let text = "Short reply."
        let lines = VisualLineBreaks.lines(
            for: text,
            width: 520,
            font: .systemFont(ofSize: 14, weight: .regular)
        )

        XCTAssertEqual(lines, [text])
    }

    func testStreamingRevealPolicyHidesTrailingDraftLine() {
        let visualLines = [
            "This is the first complete visual line ",
            "and this is still growing"
        ]

        XCTAssertEqual(
            StreamingVisualLineRevealPolicy.revealableLines(
                visualLines,
                revealTrailingLine: false
            ),
            ["This is the first complete visual line "]
        )
    }

    func testStreamingRevealPolicyShowsTrailingLineForCompletedSegment() {
        let visualLines = [
            "This line is complete because the stream ",
            "has moved to another segment."
        ]

        XCTAssertEqual(
            StreamingVisualLineRevealPolicy.revealableLines(
                visualLines,
                revealTrailingLine: true
            ),
            visualLines
        )
    }

    func testStreamingRevealStateDoesNotMutateVisibleLinesWhenNewTokensArrive() {
        var state = StreamingVisualLineRevealState()

        state.update(revealableTexts: ["This line was already revealed"])
        state.update(revealableTexts: [
            "This line was already revealed plus new token",
            "Next complete line"
        ])

        XCTAssertEqual(
            state.lines.map(\.text),
            [
                "This line was already revealed",
                "Next complete line"
            ]
        )
    }

    func testStreamingRevealStateStaggersLinesAddedInSameBatch() {
        var state = StreamingVisualLineRevealState()

        state.update(revealableTexts: ["First stable line"])
        state.update(revealableTexts: [
            "First stable line with draft growth ignored",
            "Second stable line",
            "Third stable line"
        ])

        XCTAssertEqual(
            state.lines.map(\.text),
            [
                "First stable line",
                "Second stable line",
                "Third stable line"
            ]
        )
        let delays = state.lines.map(\.revealDelay)
        XCTAssertEqual(delays.count, 3)
        XCTAssertEqual(delays[0], 0, accuracy: 0.0001)
        XCTAssertEqual(delays[1], 0, accuracy: 0.0001)
        XCTAssertEqual(delays[2], 0.45, accuracy: 0.0001)
    }

    func testStreamingRevealStateStaggersResetLinesInDisplayOrder() {
        var state = StreamingVisualLineRevealState()

        state.update(
            revealableTexts: [
                "First reset line",
                "Second reset line",
                "Third reset line"
            ],
            resetExisting: true
        )

        let delays = state.lines.map(\.revealDelay)
        XCTAssertEqual(delays.count, 3)
        XCTAssertEqual(delays[0], 0, accuracy: 0.0001)
        XCTAssertEqual(delays[1], 0.45, accuracy: 0.0001)
        XCTAssertEqual(delays[2], 0.9, accuracy: 0.0001)
    }

    func testStreamingRevealStateKeepsExistingLineWhenTrailingLineCompletes() {
        var state = StreamingVisualLineRevealState()

        state.update(
            visualLines: [
                "Already visible line ",
                "trailing draft line"
            ],
            revealTrailingLine: false,
            reason: .textChanged
        )

        let firstLineID = state.lines.first?.id

        state.update(
            visualLines: [
                "Already visible line ",
                "trailing draft line"
            ],
            revealTrailingLine: true,
            reason: .trailingRevealChanged
        )

        XCTAssertEqual(
            state.lines.map(\.text),
            [
                "Already visible line ",
                "trailing draft line"
            ]
        )
        XCTAssertEqual(state.lines.first?.id, firstLineID)
        XCTAssertEqual(state.lines.last?.revealDelay ?? -1, 0, accuracy: 0.0001)
    }
}
