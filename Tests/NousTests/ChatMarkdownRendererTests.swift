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
}
