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

    func test_beginTurn_setsTaskAndClearsBuffers() {
        let session = ConversationStreamingSession(conversationId: UUID())
        session.currentResponse = "leftover"
        session.currentThinking = "leftover"
        session.currentAgentTrace = [
            AgentTraceRecord(kind: .toolCall, title: "leftover", detail: "leftover")
        ]
        session.didHitBudgetExhaustion = true

        let turnId = UUID()
        let task = Task<Void, Never> { }
        session.beginTurn(turnId: turnId, task: task)

        XCTAssertEqual(session.inFlightTurnId, turnId)
        XCTAssertNotNil(session.inFlightTask)
        XCTAssertEqual(session.currentResponse, "")
        XCTAssertEqual(session.currentThinking, "")
        XCTAssertTrue(session.currentAgentTrace.isEmpty)
        XCTAssertTrue(session.isGenerating)
        XCTAssertFalse(session.didHitBudgetExhaustion)
        XCTAssertNotNil(session.currentThinkingStartedAt)
    }

    func test_finishTurn_whenViewing_doesNotSetUnseen() {
        let session = ConversationStreamingSession(conversationId: UUID())
        session.beginTurn(turnId: UUID(), task: Task<Void, Never> { })

        session.finishTurn(viewingNow: true)

        XCTAssertFalse(session.isGenerating)
        XCTAssertNil(session.inFlightTask)
        XCTAssertNil(session.inFlightTurnId)
        XCTAssertFalse(session.hasUnseenCompletion)
    }

    func test_finishTurn_whenNotViewing_setsUnseen() {
        let session = ConversationStreamingSession(conversationId: UUID())
        session.beginTurn(turnId: UUID(), task: Task<Void, Never> { })

        session.finishTurn(viewingNow: false)

        XCTAssertTrue(session.hasUnseenCompletion)
    }

    func test_failTurn_recordsErrorAndUnseen() {
        struct E: Error, Equatable {}
        let session = ConversationStreamingSession(conversationId: UUID())
        session.beginTurn(turnId: UUID(), task: Task<Void, Never> { })

        session.failTurn(E(), viewingNow: false)

        XCTAssertTrue(session.hasUnseenCompletion)
        XCTAssertTrue(session.lastError is E)
    }

    func test_markViewed_clearsUnseenAndReturnsError() {
        struct E: Error, Equatable {}
        let session = ConversationStreamingSession(conversationId: UUID())
        session.hasUnseenCompletion = true
        session.lastError = E()

        let surfaced = session.markViewed()

        XCTAssertFalse(session.hasUnseenCompletion)
        XCTAssertNil(session.lastError)
        XCTAssertNotNil(surfaced)
        XCTAssertTrue(surfaced is E)
    }

    func test_cancel_cancelsTask() async {
        let session = ConversationStreamingSession(conversationId: UUID())
        let started = expectation(description: "task started")
        let observedCancelled = expectation(description: "task observed cancel")
        let task = Task<Void, Never> {
            started.fulfill()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            observedCancelled.fulfill()
        }
        session.beginTurn(turnId: UUID(), task: task)
        await fulfillment(of: [started], timeout: 1.0)

        session.cancel()

        await fulfillment(of: [observedCancelled], timeout: 1.0)
        XCTAssertNil(session.inFlightTask)
        XCTAssertNil(session.inFlightTurnId)
    }
}
