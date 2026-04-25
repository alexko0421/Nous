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

    func testParserEmitsUsageMetadataWithoutCandidatePayload() {
        let line = #"data: {"usageMetadata":{"promptTokenCount":2006,"cachedContentTokenCount":1920,"candidatesTokenCount":300,"thoughtsTokenCount":31,"totalTokenCount":2306}}"#

        let (events, _) = parseAll([line])
        let usageEvents = events.compactMap {
            if case .usageMetadata(let usage) = $0 { return usage }
            return nil
        }

        XCTAssertEqual(
            usageEvents,
            [
                GeminiUsageMetadata(
                    promptTokenCount: 2006,
                    cachedContentTokenCount: 1920,
                    candidatesTokenCount: 300,
                    thoughtsTokenCount: 31,
                    totalTokenCount: 2306
                )
            ]
        )
    }
}

@objcMembers
final class ProviderThinkingStreamTests: XCTestCase {

    private func parseClaude(_ lines: [String]) -> [ReasoningStreamEvent] {
        lines.flatMap { ClaudeSSEParser.parseLine($0) }
    }

    private func parseOpenRouter(_ lines: [String]) -> [ReasoningStreamEvent] {
        lines.flatMap { OpenRouterSSEParser.parseLine($0) }
    }

    func testClaudeParserEmitsThinkingAndTextWithoutSignatureNoise() {
        let lines = [
            #"event: content_block_delta"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me reason this through.\n"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc123"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Final answer."}}"#
        ]

        let events = parseClaude(lines)

        XCTAssertEqual(
            events,
            [
                .thinkingDelta("Let me reason this through.\n"),
                .textDelta("Final answer.")
            ]
        )
    }

    func testOpenRouterParserPrefersReasoningDetailsAndDoesNotDuplicateFallbackReasoning() {
        let lines = [
            #"data: {"choices":[{"delta":{"content":"","role":"assistant","reasoning":"p","reasoning_details":[{"type":"reasoning.text","text":"p","format":"anthropic-claude-v1","index":0}]}}]}"#,
            #"data: {"choices":[{"delta":{"content":"","role":"assistant","reasoning_details":[{"type":"reasoning.text","signature":"opaque","format":"anthropic-claude-v1","index":0}]}}]}"#,
            #"data: {"choices":[{"delta":{"content":"pong","role":"assistant"}}]}"#
        ]

        let events = parseOpenRouter(lines)

        XCTAssertEqual(
            events,
            [
                .thinkingDelta("p"),
                .textDelta("pong")
            ]
        )
    }

    func testOpenRouterParserFallsBackToPlainReasoningField() {
        let lines = [
            #"data: {"choices":[{"delta":{"content":"","role":"assistant","reasoning":"thinking..."}}]}"#
        ]

        let events = parseOpenRouter(lines)

        XCTAssertEqual(events, [.thinkingDelta("thinking...")])
    }

    func testClaudeBodyEmitsCacheControlWhenStablePrefixMatches() {
        let stable = "ANCHOR + persisted memory"
        let volatile = "PER-TURN focus block"
        let combined = stable + "\n\n" + volatile

        let body = ClaudeLLMService.buildRequestBody(
            model: "claude-sonnet-4-6",
            messages: [LLMMessage(role: "user", content: "hi")],
            system: combined,
            cacheableSystemPrefix: stable,
            thinkingBudgetTokens: nil
        )

        guard let blocks = body["system"] as? [[String: Any]] else {
            XCTFail("system should be content-block array when cacheableSystemPrefix is set")
            return
        }
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"] as? String, "text")
        XCTAssertEqual(blocks[0]["text"] as? String, stable)
        XCTAssertEqual(blocks[0]["cache_control"] as? [String: String], ["type": "ephemeral"])
        XCTAssertEqual(blocks[1]["type"] as? String, "text")
        XCTAssertEqual(blocks[1]["text"] as? String, volatile)
        XCTAssertNil(blocks[1]["cache_control"])
    }

    func testClaudeBodyFallsBackToStringSystemWhenNoCachePrefix() {
        let body = ClaudeLLMService.buildRequestBody(
            model: "claude-sonnet-4-6",
            messages: [LLMMessage(role: "user", content: "hi")],
            system: "plain system",
            cacheableSystemPrefix: nil,
            thinkingBudgetTokens: nil
        )
        XCTAssertEqual(body["system"] as? String, "plain system")
    }

    func testClaudeBodyFallsBackToStringSystemWhenPrefixDoesNotMatch() {
        // Defensive case: prefix doesn't appear at start of system. Fall back
        // to plain string so we never silently drop part of the prompt.
        let body = ClaudeLLMService.buildRequestBody(
            model: "claude-sonnet-4-6",
            messages: [LLMMessage(role: "user", content: "hi")],
            system: "different prompt entirely",
            cacheableSystemPrefix: "expected stable prefix",
            thinkingBudgetTokens: nil
        )
        XCTAssertEqual(body["system"] as? String, "different prompt entirely")
    }

    func testClaudeBodyEmitsSingleCachedBlockWhenSystemEqualsPrefix() {
        let stable = "JUST ANCHOR"
        let body = ClaudeLLMService.buildRequestBody(
            model: "claude-sonnet-4-6",
            messages: [LLMMessage(role: "user", content: "hi")],
            system: stable,
            cacheableSystemPrefix: stable,
            thinkingBudgetTokens: nil
        )
        guard let blocks = body["system"] as? [[String: Any]] else {
            XCTFail("expected content-block array")
            return
        }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0]["text"] as? String, stable)
        XCTAssertEqual(blocks[0]["cache_control"] as? [String: String], ["type": "ephemeral"])
    }
}
