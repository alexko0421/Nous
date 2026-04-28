import XCTest
@testable import Nous

@MainActor
final class VoiceCommandControllerTests: XCTestCase {
    func testNavigateToolUpdatesStatusAndCallsHandler() async throws {
        let controller = VoiceCommandController()
        var navigated: VoiceNavigationTarget?
        controller.configure(
            VoiceActionHandlers(
                navigate: { navigated = $0 },
                setSidebarVisible: { _ in },
                setScratchPadVisible: { _ in },
                setComposerText: { _ in },
                appendComposerText: { _ in },
                clearComposer: {},
                startNewChat: {},
                sendMessage: { _ in },
                createNote: { _, _ in }
            )
        )

        try await controller.handleToolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"galaxy"}"#))

        XCTAssertEqual(navigated, .galaxy)
        XCTAssertEqual(controller.status, .action("Opening Galaxy"))
        XCTAssertNil(controller.pendingAction)
    }

    func testUnknownToolIsRejectedWithoutMutation() async {
        let controller = VoiceCommandController()
        var didNavigate = false
        controller.configure(
            VoiceActionHandlers(
                navigate: { _ in didNavigate = true },
                setSidebarVisible: { _ in },
                setScratchPadVisible: { _ in },
                setComposerText: { _ in },
                appendComposerText: { _ in },
                clearComposer: {},
                startNewChat: {},
                sendMessage: { _ in },
                createNote: { _, _ in }
            )
        )

        await XCTAssertThrowsErrorAsync(
            try await controller.handleToolCall(.init(name: "click_at_point", arguments: #"{"x":10,"y":10}"#))
        ) { error in
            XCTAssertEqual(error as? VoiceToolError, .unknownTool("click_at_point"))
        }
        XCTAssertFalse(didNavigate)
        XCTAssertEqual(controller.status, .error("Voice command rejected"))
    }

    func testProposeSendCreatesPendingActionWithoutSending() async throws {
        let controller = VoiceCommandController()
        var sent: String?
        controller.configure(
            VoiceActionHandlers(
                navigate: { _ in },
                setSidebarVisible: { _ in },
                setScratchPadVisible: { _ in },
                setComposerText: { _ in },
                appendComposerText: { _ in },
                clearComposer: {},
                startNewChat: {},
                sendMessage: { sent = $0 },
                createNote: { _, _ in }
            )
        )

        try await controller.handleToolCall(.init(name: "propose_send_message", arguments: #"{"text":"Ship the calm version."}"#))

        XCTAssertNil(sent)
        XCTAssertEqual(controller.pendingAction, .sendMessage(text: "Ship the calm version."))
        XCTAssertEqual(controller.status, .needsConfirmation("Confirm send?"))
    }

    func testPendingSendIsNotOverwrittenBySecondProposedSend() async throws {
        let controller = VoiceCommandController()

        try await controller.handleToolCall(.init(name: "propose_send_message", arguments: #"{"text":"Original."}"#))

        await XCTAssertThrowsErrorAsync(
            try await controller.handleToolCall(.init(name: "propose_send_message", arguments: #"{"text":"Replacement."}"#))
        ) { error in
            XCTAssertEqual(error as? VoiceToolError, .pendingActionAlreadyExists)
        }

        XCTAssertEqual(controller.pendingAction, .sendMessage(text: "Original."))
        XCTAssertEqual(controller.status, .needsConfirmation("Confirm current action first"))
    }

    func testPendingSendIsNotOverwrittenByProposedNote() async throws {
        let controller = VoiceCommandController()

        try await controller.handleToolCall(.init(name: "propose_send_message", arguments: #"{"text":"Original."}"#))

        await XCTAssertThrowsErrorAsync(
            try await controller.handleToolCall(.init(name: "propose_note", arguments: #"{"title":"Note","body":"Replacement."}"#))
        ) { error in
            XCTAssertEqual(error as? VoiceToolError, .pendingActionAlreadyExists)
        }

        XCTAssertEqual(controller.pendingAction, .sendMessage(text: "Original."))
        XCTAssertEqual(controller.status, .needsConfirmation("Confirm current action first"))
    }

    func testConfirmExecutesPendingActionOnce() async throws {
        let controller = VoiceCommandController()
        var sentMessages: [String] = []
        controller.configure(
            VoiceActionHandlers(
                navigate: { _ in },
                setSidebarVisible: { _ in },
                setScratchPadVisible: { _ in },
                setComposerText: { _ in },
                appendComposerText: { _ in },
                clearComposer: {},
                startNewChat: {},
                sendMessage: { sentMessages.append($0) },
                createNote: { _, _ in }
            )
        )

        try await controller.handleToolCall(.init(name: "propose_send_message", arguments: #"{"text":"Send once."}"#))
        controller.confirmPendingAction()
        controller.confirmPendingAction()

        XCTAssertEqual(sentMessages, ["Send once."])
        XCTAssertNil(controller.pendingAction)
        XCTAssertEqual(controller.status, .action("Sent"))
    }

    func testCancelClearsPendingActionWithoutExecuting() async throws {
        let controller = VoiceCommandController()
        var sent = false
        controller.configure(
            VoiceActionHandlers(
                navigate: { _ in },
                setSidebarVisible: { _ in },
                setScratchPadVisible: { _ in },
                setComposerText: { _ in },
                appendComposerText: { _ in },
                clearComposer: {},
                startNewChat: {},
                sendMessage: { _ in sent = true },
                createNote: { _, _ in }
            )
        )

        try await controller.handleToolCall(.init(name: "propose_send_message", arguments: #"{"text":"Cancel me."}"#))
        controller.cancelPendingAction()

        XCTAssertFalse(sent)
        XCTAssertNil(controller.pendingAction)
        XCTAssertEqual(controller.status, .action("Cancelled"))
    }

    func testInvalidNavigationArgumentIsRejected() async {
        let controller = VoiceCommandController()

        await XCTAssertThrowsErrorAsync(
            try await controller.handleToolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"files"}"#))
        ) { error in
            XCTAssertEqual(error as? VoiceToolError, .invalidArgument("tab"))
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw.", file: file, line: line)
    } catch {
        handler(error)
    }
}
