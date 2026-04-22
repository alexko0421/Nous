import XCTest
@testable import Nous

final class FilenameSlugTests: XCTestCase {

    // 2024-04-20 12:00:00 UTC — noon UTC so every timezone from UTC-12 to UTC+11 resolves
    // to 2024-04-20 local. UTC+12..+14 (rare, e.g. Line Islands/Kiribati) would see 2024-04-21;
    // fallbackDateString is derived from the same fixture so the assertions are always correct.
    private let fallbackDate = Date(timeIntervalSince1970: 1_713_614_400)

    // Compute the expected date string using the same formatter as filenameSlug, so the
    // assertions are correct regardless of the runner's local timezone.
    private var fallbackDateString: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: fallbackDate)
    }

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
        XCTAssertEqual(filenameSlug(fromMarkdown: md, fallbackDate: fallbackDate), "Nous-Summary-\(fallbackDateString).md")
    }

    func testFallsBackWhenH1Empty() {
        let md = "#   \n\nbody"
        XCTAssertEqual(filenameSlug(fromMarkdown: md, fallbackDate: fallbackDate), "Nous-Summary-\(fallbackDateString).md")
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
