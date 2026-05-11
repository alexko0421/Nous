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
        XCTAssertFalse(session.isGenerating)
        XCTAssertNil(session.inFlightTask)
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

    func test_captureFinish_matchingTurn_setsUnseenWhenNotViewing() {
        let session = ConversationStreamingSession(conversationId: UUID())
        let turnId = UUID()
        session.beginTurn(turnId: turnId, task: Task<Void, Never> { })

        let surfaced = session.captureFinish(turnId: turnId, viewingNow: false)

        XCTAssertTrue(session.hasUnseenCompletion)
        XCTAssertFalse(session.isGenerating)
        XCTAssertNil(session.inFlightTask)
        XCTAssertNil(session.inFlightTurnId)
        XCTAssertNil(surfaced)
    }

    func test_captureFinish_matchingTurn_viewingNow_doesNotSetUnseen() {
        let session = ConversationStreamingSession(conversationId: UUID())
        let turnId = UUID()
        session.beginTurn(turnId: turnId, task: Task<Void, Never> { })

        _ = session.captureFinish(turnId: turnId, viewingNow: true)

        XCTAssertFalse(session.hasUnseenCompletion)
        XCTAssertFalse(session.isGenerating)
    }

    func test_captureFinish_mismatchedTurn_noOp() {
        let session = ConversationStreamingSession(conversationId: UUID())
        let originalTurnId = UUID()
        session.beginTurn(turnId: originalTurnId, task: Task<Void, Never> { })

        let supersededReturn = session.captureFinish(turnId: UUID(), viewingNow: false)

        XCTAssertNil(supersededReturn)
        XCTAssertTrue(session.isGenerating)
        XCTAssertEqual(session.inFlightTurnId, originalTurnId)
        XCTAssertFalse(session.hasUnseenCompletion)
    }

    func test_captureFinish_withError_recordsErrorAndReturnsIt() {
        struct E: Error, Equatable {}
        let session = ConversationStreamingSession(conversationId: UUID())
        let turnId = UUID()
        session.beginTurn(turnId: turnId, task: Task<Void, Never> { })

        let surfaced = session.captureFinish(turnId: turnId, viewingNow: false, error: E())

        XCTAssertTrue(session.hasUnseenCompletion)
        XCTAssertTrue(session.lastError is E)
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
