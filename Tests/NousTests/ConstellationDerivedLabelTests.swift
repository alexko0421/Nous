import XCTest
@testable import Nous

final class ConstellationDerivedLabelTests: XCTestCase {
    func test_extractsFirstQuotedPhraseInCornerBrackets() {
        let label = Constellation.derivedShortLabel(
            from: "Across four conversations, Alex returns to 「驚被睇穿不夠好」，always under launch pressure"
        )
        XCTAssertEqual(label, "驚被睇穿不夠好")
    }

    func test_extractsFirstStraightQuotedPhrase() {
        let label = Constellation.derivedShortLabel(
            from: "Alex circles around \"fear of inadequacy\" again."
        )
        XCTAssertEqual(label, "fear of inadequacy")
    }

    func test_quotedPhraseTooLongFallsThrough() {
        // 「」 phrase >22 chars — Pattern A skips it; Pattern B finds the
        // post-colon phrase "short" and uses it.
        let label = Constellation.derivedShortLabel(
            from: "「呢個短語太長太長太長太長太長太長太長太長太長太長太長太長」: short"
        )
        XCTAssertEqual(label, "short")
    }

    func test_extractsAfterFullWidthColon() {
        let label = Constellation.derivedShortLabel(
            from: "深層 motif：對父親的期待，反覆出現"
        )
        XCTAssertEqual(label, "對父親的期待")
    }

    func test_extractsAfterEmDash() {
        let label = Constellation.derivedShortLabel(
            from: "What recurs across launches — fear of being seen as inadequate."
        )
        XCTAssertEqual(label, "fear of being seen as inadequate")
    }

    func test_truncatesAfter22Chars() {
        let label = Constellation.derivedShortLabel(
            from: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
        // 22 chars + ellipsis = 23 chars total; final char is "…"
        XCTAssertEqual(label.count, 23)
        XCTAssertTrue(label.hasSuffix("…"))
    }

    func test_emptyClaimReturnsEmptyString() {
        XCTAssertEqual(Constellation.derivedShortLabel(from: ""), "")
    }
}
