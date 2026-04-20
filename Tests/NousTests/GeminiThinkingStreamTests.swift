import XCTest
@testable import Nous

final class GeminiThinkingStreamTests: XCTestCase {

    private func parseAll(_ lines: [String]) -> (events: [GeminiSSEEvent], state: GeminiSSEParseState) {
        var state = GeminiSSEParseState()
        var events: [GeminiSSEEvent] = []
        for line in lines {
            events.append(contentsOf: GeminiSSEParser.parseLine(line, state: &state))
        }
        return (events, state)
    }

    func testParserInvokesOnThinkingDeltaBeforeTextYield() {
        let lines = [
            #"data: {"candidates":[{"content":{"parts":[{"text":"**Planning the reply**\n","thought":true}],"role":"model"},"index":0}]}"#,
            #"data: {"candidates":[{"content":{"parts":[{"text":"Hello, "}],"role":"model"},"index":0}]}"#,
            #"data: {"candidates":[{"content":{"parts":[{"text":"world."}],"role":"model"},"finishReason":"STOP","index":0}]}"#
        ]

        let (events, _) = parseAll(lines)

        let thoughtEvents = events.compactMap { if case .thoughtDelta(let t) = $0 { return t } else { return nil } }
        let textEvents = events.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }

        XCTAssertEqual(thoughtEvents, ["**Planning the reply**\n"])
        XCTAssertEqual(textEvents, ["Hello, ", "world."])

        let firstThoughtIdx = events.firstIndex { if case .thoughtDelta = $0 { return true } else { return false } }
        let firstTextIdx = events.firstIndex { if case .textDelta = $0 { return true } else { return false } }
        XCTAssertNotNil(firstThoughtIdx)
        XCTAssertNotNil(firstTextIdx)
        XCTAssertLessThan(firstThoughtIdx!, firstTextIdx!)

        XCTAssertFalse(events.contains { if case .budgetExhausted = $0 { return true } else { return false } })
    }

    func testParserHandlesMultiplePartsPerFrame() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"thinking about it","thought":true},{"text":"the answer is 42"}],"role":"model"},"index":0}]}"#

        let (events, _) = parseAll([line])

        guard events.count == 2 else {
            XCTFail("expected 2 events from multi-part frame, got \(events.count)")
            return
        }
        XCTAssertEqual(events[0], .thoughtDelta("thinking about it"))
        XCTAssertEqual(events[1], .textDelta("the answer is 42"))
    }

    func testParserInvokesOnBudgetExhaustedWhenNoTextEmitted() {
        let lines = [
            #"data: {"candidates":[{"content":{"parts":[{"text":"**Still thinking**","thought":true}],"role":"model"},"index":0}]}"#,
            #"data: {"candidates":[{"content":{"parts":[{"text":"**More thinking**","thought":true}],"role":"model"},"finishReason":"MAX_TOKENS","index":0}]}"#
        ]

        let (events, state) = parseAll(lines)

        XCTAssertTrue(events.contains { if case .budgetExhausted = $0 { return true } else { return false } },
                      "budgetExhausted must fire when MAX_TOKENS hits with zero non-thought text")
        XCTAssertFalse(state.didYieldNonThoughtText)
        XCTAssertTrue(state.didFireBudgetExhausted)

        XCTAssertFalse(events.contains { if case .textDelta = $0 { return true } else { return false } })
    }

    func testParserDoesNotFireBudgetExhaustedWhenTextAlreadyYielded() {
        let lines = [
            #"data: {"candidates":[{"content":{"parts":[{"text":"thinking...","thought":true}],"role":"model"},"index":0}]}"#,
            #"data: {"candidates":[{"content":{"parts":[{"text":"This proof will"}],"role":"model"},"index":0}]}"#,
            #"data: {"candidates":[{"content":{"parts":[{"text":" rigorously demonstrate"}],"role":"model"},"finishReason":"MAX_TOKENS","index":0}]}"#
        ]

        let (events, state) = parseAll(lines)

        XCTAssertFalse(events.contains { if case .budgetExhausted = $0 { return true } else { return false } },
                       "budgetExhausted must NOT fire when MAX_TOKENS hits but text was already yielded — that's a 'reply was cut off' case, not a true budget exhaustion")
        XCTAssertTrue(state.didYieldNonThoughtText)
        XCTAssertFalse(state.didFireBudgetExhausted)

        let textEvents = events.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }
        XCTAssertEqual(textEvents, ["This proof will", " rigorously demonstrate"])
    }

    func testParserIgnoresNonDataLines() {
        let lines = [
            "",
            "event: message",
            ": heartbeat",
            #"data: {"candidates":[{"content":{"parts":[{"text":"hi"}],"role":"model"},"finishReason":"STOP","index":0}]}"#
        ]

        let (events, _) = parseAll(lines)

        let textEvents = events.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }
        XCTAssertEqual(textEvents, ["hi"])
    }

    func testParserSkipsEmptyTextParts() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":""}],"role":"model"},"index":0}]}"#

        let (events, state) = parseAll([line])

        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(state.didYieldNonThoughtText)
    }
}
