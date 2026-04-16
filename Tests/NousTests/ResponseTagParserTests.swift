import XCTest
@testable import Nous

final class ResponseTagParserTests: XCTestCase {
    func testPlainTextReturnsPlainResult() {
        let result = ResponseTagParser.parse("辛苦晒。")
        switch result {
        case .plain(let text): XCTAssertEqual(text, "辛苦晒。")
        default: XCTFail("expected .plain, got \(result)")
        }
    }

    func testDeferTagAloneReturnsDefer() {
        let result = ResponseTagParser.parse("<defer/>")
        if case .defer_ = result {} else { XCTFail("expected .defer_") }
    }

    func testDeferTagWithSurroundingWhitespaceReturnsDefer() {
        let result = ResponseTagParser.parse("  \n<defer/>\n  ")
        if case .defer_ = result {} else { XCTFail("expected .defer_") }
    }

    func testDeferTagWithExtraTextStripsTagReturnsPlain() {
        // Malformed: defer mixed with text. Strip tag, render remaining.
        let result = ResponseTagParser.parse("some text <defer/> more")
        switch result {
        case .plain(let text): XCTAssertEqual(text, "some text  more")
        default: XCTFail("expected .plain, got \(result)")
        }
    }

    func testCardWithTwoOptionsParses() {
        let response = """
        <card>
        <framing>你问我呢个背后...</framing>
        <option>已经决定咗</option>
        <option>Build 卡咗</option>
        </card>
        """
        let result = ResponseTagParser.parse(response)
        switch result {
        case .card(let payload):
            XCTAssertEqual(payload.framing, "你问我呢个背后...")
            XCTAssertEqual(payload.options, ["已经决定咗", "Build 卡咗"])
        default:
            XCTFail("expected .card, got \(result)")
        }
    }

    func testCardWithOneOptionParses() {
        let response = """
        <card><framing>f</framing><option>only</option></card>
        """
        let result = ResponseTagParser.parse(response)
        switch result {
        case .card(let payload):
            XCTAssertEqual(payload.framing, "f")
            XCTAssertEqual(payload.options, ["only"])
        default: XCTFail("expected .card")
        }
    }

    func testCardWithMissingFramingFallsBackToPlain() {
        let response = "<card><option>a</option></card>"
        let result = ResponseTagParser.parse(response)
        switch result {
        case .plain: break  // fallback acceptable
        case .card: break   // empty framing also acceptable as long as we don't crash
        default: XCTFail("unexpected .defer_")
        }
    }

    func testMalformedCardFallsBackToPlainText() {
        let response = "<card><framing>f</framing<option>broken"
        let result = ResponseTagParser.parse(response)
        switch result {
        case .plain(let text):
            XCTAssertTrue(text.contains("broken"))
        default:
            XCTFail("expected fallback to .plain for malformed card, got \(result)")
        }
    }

    func testMoreThanTwoOptionsAreAllParsed() {
        // Parser does not enforce max-2; that is the prompt's job.
        let response = """
        <card><framing>f</framing><option>a</option><option>b</option><option>c</option></card>
        """
        let result = ResponseTagParser.parse(response)
        switch result {
        case .card(let payload):
            XCTAssertEqual(payload.options.count, 3)
        default: XCTFail("expected .card")
        }
    }
}
