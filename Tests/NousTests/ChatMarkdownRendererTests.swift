import XCTest
@testable import Nous

final class ChatMarkdownRendererTests: XCTestCase {

    // MARK: - Foundation

    func testEmptyInputReturnsEmptySegments() {
        XCTAssertEqual(ChatMarkdownRenderer.parse("").count, 0)
    }
}
