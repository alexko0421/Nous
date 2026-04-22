import XCTest
@testable import Nous

final class FilenameSlugTests: XCTestCase {

    private let fallbackDate = Date(timeIntervalSince1970: 1_713_657_600)   // 2024-04-20 UTC

    func testUsesFirstH1AsSlug() {
        let md = "# Hello World\n\nBody"
        XCTAssertEqual(filenameSlug(fromMarkdown: md, fallbackDate: fallbackDate), "Hello-World.md")
    }

    func testPreservesCJK() {
        let md = "# 关于 Notion 产品方向\n\n..."
        let result = filenameSlug(fromMarkdown: md, fallbackDate: fallbackDate)
        XCTAssertTrue(result.contains("关于"))
        XCTAssertTrue(result.contains("Notion"))
        XCTAssertTrue(result.hasSuffix(".md"))
    }

    func testStripsDisallowedPathChars() {
        let md = "# bad/name:with*chars?\n"
        let result = filenameSlug(fromMarkdown: md, fallbackDate: fallbackDate)
        XCTAssertFalse(result.contains("/"))
        XCTAssertFalse(result.contains(":"))
        XCTAssertFalse(result.contains("*"))
        XCTAssertFalse(result.contains("?"))
    }

    func testFallsBackToDateWhenNoH1() {
        let md = "no heading here\n\nblah"
        XCTAssertEqual(filenameSlug(fromMarkdown: md, fallbackDate: fallbackDate), "Nous-Summary-2024-04-20.md")
    }

    func testFallsBackWhenH1Empty() {
        let md = "#   \n\nbody"
        XCTAssertEqual(filenameSlug(fromMarkdown: md, fallbackDate: fallbackDate), "Nous-Summary-2024-04-20.md")
    }

    func testTruncatesAtSixtyChars() {
        let longTitle = String(repeating: "a", count: 200)
        let md = "# \(longTitle)\n"
        let result = filenameSlug(fromMarkdown: md, fallbackDate: fallbackDate)
        let stem = result.replacingOccurrences(of: ".md", with: "")
        XCTAssertLessThanOrEqual(stem.count, 60)
    }

    func testCollapsesWhitespaceToDashes() {
        let md = "# the    quick    brown\n"
        XCTAssertEqual(filenameSlug(fromMarkdown: md, fallbackDate: fallbackDate), "the-quick-brown.md")
    }
}
