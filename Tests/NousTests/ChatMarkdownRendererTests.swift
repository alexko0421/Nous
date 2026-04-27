import XCTest
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
}
