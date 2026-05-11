import XCTest
@testable import Nous

@MainActor
final class ConversationStreamingSessionTests: XCTestCase {

    func test_initialState_isEmpty() {
        let id = UUID()
        let session = ConversationStreamingSession(conversationId: id)

        XCTAssertEqual(session.conversationId, id)
        XCTAssertEqual(session.currentResponse, "")
        XCTAssertEqual(session.currentThinking, "")
        XCTAssertNil(session.currentThinkingStartedAt)
        XCTAssertTrue(session.currentAgentTrace.isEmpty)
        XCTAssertFalse(session.isGenerating)
        XCTAssertFalse(session.didHitBudgetExhaustion)
        XCTAssertNil(session.inFlightTask)
        XCTAssertNil(session.inFlightTurnId)
        XCTAssertNil(session.inFlightAbortReason)
        XCTAssertFalse(session.hasUnseenCompletion)
        XCTAssertNil(session.lastError)
    }
}
