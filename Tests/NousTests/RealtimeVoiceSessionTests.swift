import XCTest
@testable import Nous

final class RealtimeVoiceSessionTests: XCTestCase {
    func testBuildsRealtimeRequestWithBearerTokenAndModel() throws {
        let request = RealtimeVoiceSession.makeRequest(apiKey: "sk-test", model: "gpt-realtime")

        XCTAssertEqual(request.url?.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testSessionUpdateIncludesTextOutputAndTools() throws {
        let data = try RealtimeVoiceSession.makeSessionUpdateEvent()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try XCTUnwrap(json["session"] as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "session.update")
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertEqual(session["model"] as? String, "gpt-realtime")
        XCTAssertEqual(session["output_modalities"] as? [String], ["text"])
        XCTAssertEqual(session["tool_choice"] as? String, "auto")
        XCTAssertFalse((session["tools"] as? [[String: Any]])?.isEmpty ?? true)
    }

    func testParsesFunctionCallArgumentsDone() throws {
        let raw = """
        {
          "type": "response.function_call_arguments.done",
          "name": "navigate_to_tab",
          "call_id": "call_123",
          "arguments": "{\\"tab\\":\\"galaxy\\"}"
        }
        """

        let event = try XCTUnwrap(RealtimeVoiceEventParser.parse(raw))

        XCTAssertEqual(event, .toolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"galaxy"}"#), callId: "call_123"))
    }

    func testParsesResponseDoneAsThinkingComplete() throws {
        let raw = #"{"type":"response.done"}"#

        XCTAssertEqual(RealtimeVoiceEventParser.parse(raw), .responseDone)
    }

    func testParsesCompletedResponseDoneAsResponseDone() throws {
        let raw = #"{"type":"response.done","response":{"status":"completed"}}"#

        XCTAssertEqual(RealtimeVoiceEventParser.parse(raw), .responseDone)
    }

    func testParsesFailedResponseDoneAsError() throws {
        let raw = """
        {
          "type": "response.done",
          "response": {
            "status": "failed",
            "status_details": {
              "error": {
                "message": "Model request failed"
              }
            }
          }
        }
        """

        guard case .error(let message) = RealtimeVoiceEventParser.parse(raw) else {
            return XCTFail("Expected response.done with failed status to parse as an error.")
        }

        XCTAssertTrue(message.contains("failed"))
        XCTAssertTrue(message.contains("Model request failed"))
    }

    func testUnknownEventsAreIgnored() throws {
        XCTAssertNil(RealtimeVoiceEventParser.parse(#"{"type":"rate_limits.updated"}"#))
    }

    func testAudioAppendEventShape() throws {
        let data = try RealtimeVoiceSession.makeAudioAppendEvent(base64Audio: "abc123")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(json["audio"] as? String, "abc123")
    }

    func testFunctionOutputEventShape() throws {
        let data = try RealtimeVoiceSession.makeFunctionOutputEvent(callId: "call_123", output: "Opened Galaxy")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let item = try XCTUnwrap(json["item"] as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "conversation.item.create")
        XCTAssertEqual(item["type"] as? String, "function_call_output")
        XCTAssertEqual(item["call_id"] as? String, "call_123")
        XCTAssertEqual(item["output"] as? String, "Opened Galaxy")
    }

    func testResponseCreateEventShape() throws {
        let data = try RealtimeVoiceSession.makeResponseCreateEvent()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let response = try XCTUnwrap(json["response"] as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "response.create")
        XCTAssertEqual(response["output_modalities"] as? [String], ["text"])
    }
}
