import XCTest
@testable import Nous

@MainActor
final class VoiceCommandControllerTranscriptTests: XCTestCase {
    func test_inputDeltaThenComplete_buildsUserLine() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)
        try await controller.start(apiKey: "k")

        await session.emit(.inputTranscriptDelta("Open"))
        await session.emit(.inputTranscriptDelta(" Galaxy"))
        XCTAssertEqual(controller.transcript.count, 1)
        XCTAssertEqual(controller.transcript[0].role, .user)
        XCTAssertEqual(controller.transcript[0].text, "Open Galaxy")
        XCTAssertFalse(controller.transcript[0].isFinal)

        await session.emit(.inputTranscriptCompleted("Open Galaxy."))
        XCTAssertEqual(controller.transcript.count, 1)
        XCTAssertTrue(controller.transcript[0].isFinal)
        XCTAssertEqual(controller.transcript[0].text, "Open Galaxy.")
    }

    func test_assistantAfterUser_opensSecondLine() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)
        try await controller.start(apiKey: "k")

        await session.emit(.inputTranscriptCompleted("Hi."))
        await session.emit(.outputTranscriptDelta("Hey"))
        XCTAssertEqual(controller.transcript.count, 2)
        XCTAssertEqual(controller.transcript[1].role, .assistant)
        XCTAssertEqual(controller.transcript[1].text, "Hey")
        XCTAssertFalse(controller.transcript[1].isFinal)
    }

    func test_stopClearsTranscript() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)
        try await controller.start(apiKey: "k")

        await session.emit(.outputTranscriptCompleted("Done."))
        XCTAssertEqual(controller.transcript.count, 1)

        controller.stop()
        XCTAssertEqual(controller.transcript.count, 0)
    }
}
