import XCTest
@testable import Nous

final class MessageCardPayloadTests: XCTestCase {
    func testCardPayloadRoundtripsThroughCodable() throws {
        let payload = CardPayload(
            framing: "你问我呢个背后...",
            options: ["已经决定咗", "Build 卡咗"]
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(CardPayload.self, from: data)
        XCTAssertEqual(decoded.framing, "你问我呢个背后...")
        XCTAssertEqual(decoded.options, ["已经决定咗", "Build 卡咗"])
    }

    func testMessageWithoutCardPayloadIsNil() {
        let msg = Message(nodeId: UUID(), role: .assistant, content: "hello")
        XCTAssertNil(msg.cardPayload)
    }

    func testMessageWithCardPayloadRoundtripsThroughCodable() throws {
        let payload = CardPayload(framing: "f", options: ["a", "b"])
        let msg = Message(
            nodeId: UUID(),
            role: .assistant,
            content: "f",
            cardPayload: payload
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(decoded.cardPayload?.options, ["a", "b"])
    }

    func testMessageDecodingLegacyJsonWithoutCardPayloadSucceeds() throws {
        // Legacy JSON (no cardPayload field) must still decode.
        let legacyJSON = #"""
        {"id":"11111111-1111-1111-1111-111111111111","nodeId":"22222222-2222-2222-2222-222222222222","role":"assistant","content":"hi","timestamp":729876543.0}
        """#
        let data = Data(legacyJSON.utf8)
        let msg = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(msg.content, "hi")
        XCTAssertNil(msg.cardPayload)
    }
}
