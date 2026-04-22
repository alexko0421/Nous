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

    func testParserStripsReflectionPhaseMarker() {
        let response = """
        <phase>reflection</phase>
        Alex, 你问得好。
        """

        let parsed = ClarificationCardParser.parse(response)

        XCTAssertEqual(parsed.displayText, "Alex, 你问得好。")
        XCTAssertFalse(parsed.keepsQuickActionMode)
    }

    func testParserStripsThinkingBlock() {
        let response = """
        <thinking>
        意味着 Alex 提到搬去 Austin。
        我们的问题:
        1. 确认他对"搬去 Austin"的理解。
        </thinking>
        「搬去 Austin」你一念头，系咪真系一个新嘅目标？
        """

        let parsed = ClarificationCardParser.parse(response)

        XCTAssertFalse(parsed.displayText.contains("<thinking>"))
        XCTAssertFalse(parsed.displayText.contains("</thinking>"))
        XCTAssertFalse(parsed.displayText.contains("我们的问题"))
        XCTAssertTrue(parsed.displayText.hasPrefix("「搬去 Austin」"))
    }

    func testParserStripsMultipleInternalMarkersTogether() {
        let response = """
        <phase>reflection</phase>
        <thinking>step 1
        step 2</thinking>
        最终嘅回覆喺呢度。
        """

        let parsed = ClarificationCardParser.parse(response)

        XCTAssertEqual(parsed.displayText, "最终嘅回覆喺呢度。")
    }

    func testParserStripsUnclosedThinkingDuringStreaming() {
        let response = "Hello Alex. <thinking>我首先要确认"

        let parsed = ClarificationCardParser.parse(response)

        XCTAssertEqual(parsed.displayText, "Hello Alex.")
    }

    func testParserStripsUnclosedPhaseDuringStreaming() {
        let response = "之前嘅对话。 <phase>reflec"

        let parsed = ClarificationCardParser.parse(response)

        XCTAssertEqual(parsed.displayText, "之前嘅对话.".replacingOccurrences(of: ".", with: "。"))
    }

    func testExtractSummaryReturnsInnerMarkdownWhenWellFormed() {
        let raw = """
        整好了，睇下右边。
        <summary>
        # 关于 Notion 产品方向

        ## 问题
        Alex 想搞清楚 Notion 该不该加 AI agent。

        ## 思考
        倾咗 retention vs differentiation。

        ## 结论
        暂时唔做。

        ## 下一步
        - 观察 Coda 三个月
        </summary>
        多谢！
        """

        let extracted = ClarificationCardParser.extractSummary(from: raw)
        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted!.hasPrefix("# 关于 Notion 产品方向"))
        XCTAssertTrue(extracted!.contains("## 下一步"))
    }

    func testExtractSummaryReturnsNilWhenNoTag() {
        XCTAssertNil(ClarificationCardParser.extractSummary(from: "No summary here."))
    }

    func testExtractSummaryReturnsNilWhenUnclosed() {
        let raw = "<summary>\n# Title\nSome text without closing tag"
        XCTAssertNil(ClarificationCardParser.extractSummary(from: raw))
    }

    func testExtractSummaryReturnsNilWhenEmptyBody() {
        XCTAssertNil(ClarificationCardParser.extractSummary(from: "before <summary>   </summary> after"))
    }

    func testExtractSummaryPrefersFirstPair() {
        let raw = """
        <summary># First</summary>
        <summary># Second</summary>
        """
        let extracted = ClarificationCardParser.extractSummary(from: raw)
        XCTAssertEqual(extracted, "# First")
    }

    func testParseStripsSummaryTagsButPreservesInnerContentInDisplayText() {
        let raw = """
        整好了。
        <summary>
        # Hello

        世界
        </summary>
        """
        let parsed = ClarificationCardParser.parse(raw)
        XCTAssertFalse(parsed.displayText.contains("<summary>"))
        XCTAssertFalse(parsed.displayText.contains("</summary>"))
        XCTAssertTrue(parsed.displayText.contains("# Hello"))
        XCTAssertTrue(parsed.displayText.contains("世界"))
        XCTAssertTrue(parsed.displayText.contains("整好了"))
    }
}
