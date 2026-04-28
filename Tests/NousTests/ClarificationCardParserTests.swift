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

    func testParserStripsSignatureMomentsBlock() {
        let response = """
        你讲得好——品味需要时间堆积。
        <signature_moments>
        - source: user
          text: "睇过一千幅画，试过一百种咖啡，失败过十次"
        </signature_moments>
        """

        let parsed = ClarificationCardParser.parse(response)

        XCTAssertFalse(parsed.displayText.contains("<signature_moments>"))
        XCTAssertFalse(parsed.displayText.contains("</signature_moments>"))
        XCTAssertFalse(parsed.displayText.contains("睇过一千幅画"))
        XCTAssertEqual(parsed.displayText, "你讲得好——品味需要时间堆积。")
    }

    func testParserStripsUnclosedSignatureMomentsDuringStreaming() {
        let response = "你讲得好。 <signature_moments>\n- source: user\n  text: \"睇过一"

        let parsed = ClarificationCardParser.parse(response)

        XCTAssertFalse(parsed.displayText.contains("<signature_moments>"))
        XCTAssertFalse(parsed.displayText.contains("source:"))
        XCTAssertEqual(parsed.displayText, "你讲得好。")
    }

    func testParserStripsSignatureMomentsAlongsideThinkingAndChatTitle() {
        let response = """
        <thinking>judging</thinking>
        呢个 observation 好准。
        <signature_moments>
        - source: nous
          text: "硬限制系精神上嘅奢侈品"
        </signature_moments>
        <chat_title>品味的形成</chat_title>
        """

        let parsed = ClarificationCardParser.parse(response)

        XCTAssertEqual(parsed.displayText, "呢个 observation 好准。")
        XCTAssertFalse(parsed.displayText.contains("硬限制"))
        XCTAssertFalse(parsed.displayText.contains("品味的形成"))
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

    func testParseStripsOpenSummaryTagEvenWhenNotYetClosed() {
        // During streaming, the model may emit <summary> and partial body before the
        // </summary> arrives. `extractSummary` must return nil (no valid summary yet),
        // but `parse(_:)` should still strip the lone <summary> marker from displayText
        // so users don't see raw tag markup during streaming.
        let raw = """
        整好了。
        <summary>
        # Hello
        (still streaming…
        """

        XCTAssertNil(ClarificationCardParser.extractSummary(from: raw))

        let parsed = ClarificationCardParser.parse(raw)
        XCTAssertFalse(parsed.displayText.contains("<summary>"))
        XCTAssertTrue(parsed.displayText.contains("# Hello"))
        XCTAssertTrue(parsed.displayText.contains("整好了"))
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

    func testExtractChatTitleReturnsInnerTextWhenWellFormed() {
        let raw = """
        呢个问题要拆开睇。

        <chat_title>AI 时代仲要唔要生细路</chat_title>
        """

        XCTAssertEqual(
            ClarificationCardParser.extractChatTitle(from: raw),
            "AI 时代仲要唔要生细路"
        )
    }

    func testStripChatTitleRemovesHiddenTitleBlockFromPersistedText() {
        let raw = """
        我会由成本、时间同后悔风险三边睇。

        <chat_title>创业应该搬去边</chat_title>
        """

        let stripped = ClarificationCardParser.stripChatTitle(from: raw)
        XCTAssertFalse(stripped.contains("<chat_title>"))
        XCTAssertFalse(stripped.contains("创业应该搬去边"))
        XCTAssertTrue(stripped.contains("我会由成本"))
    }

    func testParseStripsUnclosedChatTitleDuringStreaming() {
        let raw = """
        我会直接答你。
        <chat_title>AI 时代仲要
        """

        let parsed = ClarificationCardParser.parse(raw)
        XCTAssertEqual(parsed.displayText, "我会直接答你。")
    }

    func testSummaryWithInnerMarkdownPreservesStructure() {
        let input = """
        Here is the summary:

        <summary>
        # Title

        - bullet 1
        - bullet 2

        | col | col |
        |---|---|
        | 1 | 2 |
        </summary>

        More text after.
        """
        let parsed = ClarificationCardParser.parse(input)
        let display = parsed.displayText

        // Markdown structure inside <summary> must survive parsing intact.
        XCTAssertTrue(display.contains("# Title"), "heading preserved")
        XCTAssertTrue(display.contains("- bullet 1"), "bullets preserved")
        XCTAssertTrue(display.contains("| col | col |"), "table header preserved")
        XCTAssertTrue(display.contains("|---|---|"), "table separator preserved")

        // Tag markers must be stripped.
        XCTAssertFalse(display.contains("<summary>"), "<summary> tag stripped")
        XCTAssertFalse(display.contains("</summary>"), "</summary> tag stripped")
    }
}
