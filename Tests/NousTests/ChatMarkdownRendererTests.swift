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

    func testHeadingTextTrimsTrailingWhitespace() {
        XCTAssertEqual(
            ChatMarkdownRenderer.parse("# Title   "),
            [.heading(level: 1, text: "Title")]
        )
    }
}
