import XCTest
@testable import Nous

final class ClarificationCardParserTests: XCTestCase {

    func testParserExtractsCardAndRemainingText() {
        let response = """
        I need one thing first.

        <clarify>
        <question>Which style do you want?</question>
        <option>Keep it minimal</option>
        <option>Make it bolder</option>
        <option>Match the old version</option>
        <option>Show me both</option>
        </clarify>
        """

        let parsed = ClarificationCardParser.parse(response)

        XCTAssertEqual(parsed.displayText, "I need one thing first.")
        XCTAssertEqual(parsed.card?.question, "Which style do you want?")
        XCTAssertEqual(parsed.card?.options.count, 4)
        XCTAssertEqual(parsed.card?.options.first, "Keep it minimal")
        XCTAssertTrue(parsed.keepsQuickActionMode)
    }

    func testParserRejectsInvalidOptionCount() {
        let response = """
        <clarify>
        <question>Pick one</question>
        <option>Only one option</option>
        </clarify>
        """

        let parsed = ClarificationCardParser.parse(response)

        XCTAssertNil(parsed.card)
        XCTAssertTrue(parsed.displayText.contains("<clarify>"))
        XCTAssertFalse(parsed.keepsQuickActionMode)
    }

    func testParserHidesUnderstandingPhaseMarkerFromDisplayText() {
        let response = """
        <phase>understanding</phase>
        Tell me a bit more about what has been hardest lately.
        """

        let parsed = ClarificationCardParser.parse(response)

        XCTAssertEqual(parsed.displayText, "Tell me a bit more about what has been hardest lately.")
        XCTAssertNil(parsed.card)
        XCTAssertTrue(parsed.keepsQuickActionMode)
    }
}
