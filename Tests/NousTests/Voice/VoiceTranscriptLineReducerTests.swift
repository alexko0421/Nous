import XCTest
@testable import Nous

final class VoiceTranscriptLineReducerTests: XCTestCase {
    func test_appendingDelta_updatesLatestLine() {
        var lines: [VoiceTranscriptLine] = []
        VoiceTranscriptLine.appendDelta("Hello", role: .user, into: &lines, now: Date(timeIntervalSince1970: 0))
        VoiceTranscriptLine.appendDelta(" world", role: .user, into: &lines, now: Date(timeIntervalSince1970: 0.1))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Hello world")
        XCTAssertEqual(lines[0].role, .user)
        XCTAssertFalse(lines[0].isFinal)
    }

    func test_finalizingThenSwitchingRole_opensNewLine() {
        var lines: [VoiceTranscriptLine] = []
        VoiceTranscriptLine.appendDelta("Hi", role: .user, into: &lines, now: Date(timeIntervalSince1970: 0))
        VoiceTranscriptLine.finalize(text: "Hi.", role: .user, into: &lines)
        VoiceTranscriptLine.appendDelta("Hey", role: .assistant, into: &lines, now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].isFinal)
        XCTAssertEqual(lines[0].text, "Hi.")
        XCTAssertFalse(lines[1].isFinal)
        XCTAssertEqual(lines[1].role, .assistant)
        XCTAssertEqual(lines[1].text, "Hey")
    }

    func test_bargeInSealsAssistantLineKeepingText() {
        var lines: [VoiceTranscriptLine] = []
        VoiceTranscriptLine.appendDelta("Opening Gala", role: .assistant, into: &lines, now: Date(timeIntervalSince1970: 0))
        VoiceTranscriptLine.bargeInSealsLatestAssistant(into: &lines)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].isFinal)
        XCTAssertEqual(lines[0].text, "Opening Gala")
    }
}
