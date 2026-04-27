import XCTest
@testable import Nous

final class TurnStewardTests: XCTestCase {
    private let steward = TurnSteward()

    func testActiveQuickActionWins() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "brainstorm something else"),
            request: request(input: "brainstorm something else", activeQuickActionMode: .plan)
        )

        XCTAssertEqual(decision.route, .plan)
        XCTAssertEqual(decision.memoryPolicy, .full)
        XCTAssertEqual(decision.responseShape, .producePlan)
        XCTAssertEqual(decision.trace.reason, "active quick action mode")
    }

    func testExplicitBrainstormRoutesLean() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "brainstorm a few ideas"),
            request: request(input: "brainstorm a few ideas")
        )

        XCTAssertEqual(decision.route, .brainstorm)
        XCTAssertEqual(decision.memoryPolicy, .lean)
        XCTAssertEqual(decision.challengeStance, .useSilently)
        XCTAssertEqual(decision.responseShape, .listDirections)
    }

    func testExplicitPlanRoutesFullAndProducePlan() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "help me plan this week"),
            request: request(input: "help me plan this week")
        )

        XCTAssertEqual(decision.route, .plan)
        XCTAssertEqual(decision.memoryPolicy, .full)
        XCTAssertEqual(decision.challengeStance, .surfaceTension)
        XCTAssertEqual(decision.responseShape, .producePlan)
    }

    func testExplicitDirectionRoutesFullAndNarrowNextStep() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "what is my next step"),
            request: request(input: "what is my next step")
        )

        XCTAssertEqual(decision.route, .direction)
        XCTAssertEqual(decision.memoryPolicy, .full)
        XCTAssertEqual(decision.challengeStance, .surfaceTension)
        XCTAssertEqual(decision.responseShape, .narrowNextStep)
    }

    func testEmotionalDistressSupportFirst() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "我好攰，感觉顶唔顺"),
            request: request(input: "我好攰，感觉顶唔顺")
        )

        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.memoryPolicy, .conversationOnly)
        XCTAssertEqual(decision.challengeStance, .supportFirst)
        XCTAssertEqual(decision.responseShape, .answerNow)
    }

    func testMemoryOptOutForFreshBrainstorm() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "brainstorm from scratch, don't use memory"),
            request: request(input: "brainstorm from scratch, don't use memory")
        )

        XCTAssertEqual(decision.route, .brainstorm)
        XCTAssertEqual(decision.memoryPolicy, .lean)
        XCTAssertEqual(decision.trace.reason, "explicit brainstorm with memory opt-out")
    }

    func testMemoryOptOutForOrdinaryChat() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "don't use memory, think from first principles"),
            request: request(input: "don't use memory, think from first principles")
        )

        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.memoryPolicy, .lean)
        XCTAssertEqual(decision.challengeStance, .useSilently)
    }

    func testOrdinaryChatDefaultForAmbiguousText() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "just thinking out loud"),
            request: request(input: "just thinking out loud")
        )

        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.memoryPolicy, .full)
        XCTAssertEqual(decision.challengeStance, .useSilently)
        XCTAssertEqual(decision.responseShape, .answerNow)
    }

    func testNoIdeaDoesNotRouteToBrainstorm() {
        let decision = steward.steer(
            prepared: preparedTurn(userText: "I have no idea what to do"),
            request: request(input: "I have no idea what to do")
        )

        XCTAssertEqual(decision.route, .ordinaryChat)
        XCTAssertEqual(decision.memoryPolicy, .full)
    }

    private func preparedTurn(userText: String) -> PreparedTurnSession {
        let node = NousNode(type: .conversation, title: "test")
        let message = Message(nodeId: node.id, role: .user, content: userText)
        return PreparedConversationTurn(
            node: node,
            userMessage: message,
            messagesAfterUserAppend: [message]
        )
    }

    private func request(
        input: String,
        activeQuickActionMode: QuickActionMode? = nil
    ) -> TurnRequest {
        TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: nil,
                messages: [],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: activeQuickActionMode
            ),
            inputText: input,
            attachments: [],
            now: Date()
        )
    }
}
