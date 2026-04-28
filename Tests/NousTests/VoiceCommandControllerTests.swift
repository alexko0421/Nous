import XCTest
@testable import Nous

@MainActor
final class VoiceCommandControllerTests: XCTestCase {
    func testStartRejectsWhitespaceAPIKey() async {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)

        await XCTAssertThrowsErrorAsync(
            try await controller.start(apiKey: " \n\t ")
        ) { error in
            XCTAssertEqual(error as? VoiceSessionError, .missingOpenAIKey)
        }

        XCTAssertEqual(session.startedAPIKeys, [])
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.status, .error("Add OpenAI API key"))
    }

    func testMissingAPIKeyStopsExistingActiveSession() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)

        try await controller.start(apiKey: "sk-test")

        await XCTAssertThrowsErrorAsync(
            try await controller.start(apiKey: " ")
        ) { error in
            XCTAssertEqual(error as? VoiceSessionError, .missingOpenAIKey)
        }

        XCTAssertEqual(session.stopCallCount, 1)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.status, .error("Add OpenAI API key"))
    }

    func testInFlightStartFailureAfterStopDoesNotMutateIdleState() async throws {
        let session = FakeRealtimeVoiceSession()
        let startGate = StartGate()
        session.startGates = [startGate]
        let controller = VoiceCommandController(session: session)

        let startTask = Task {
            try await controller.start(apiKey: "sk-test")
        }

        await startGate.waitUntilInFlight()
        controller.stop()
        let stopCallCountAfterExplicitStop = session.stopCallCount
        await startGate.release(error: RealtimeVoiceSocketError.notConnected)
        await XCTAssertThrowsErrorAsync(
            try await startTask.value
        ) { error in
            XCTAssertEqual(error as? RealtimeVoiceSocketError, .notConnected)
        }

        XCTAssertEqual(stopCallCountAfterExplicitStop, 1)
        XCTAssertEqual(session.stopCallCount, 1)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.status, .idle)
    }

    func testInFlightStartFailureAfterRestartDoesNotStopNewSession() async throws {
        let session = FakeRealtimeVoiceSession()
        let startGate = StartGate()
        session.startGates = [startGate]
        let controller = VoiceCommandController(session: session)

        let startTask = Task {
            try await controller.start(apiKey: "sk-old")
        }

        await startGate.waitUntilInFlight()
        controller.stop()
        try await controller.start(apiKey: "sk-new")
        let stopCallCountBeforeStaleFailure = session.stopCallCount
        await startGate.release(error: RealtimeVoiceSocketError.notConnected)
        await XCTAssertThrowsErrorAsync(
            try await startTask.value
        ) { error in
            XCTAssertEqual(error as? RealtimeVoiceSocketError, .notConnected)
        }

        XCTAssertEqual(session.startedAPIKeys, ["sk-old", "sk-new"])
        XCTAssertEqual(stopCallCountBeforeStaleFailure, 1)
        XCTAssertEqual(session.stopCallCount, 1)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.status, .listening)
    }

    func testRealtimeToolCallRunsThroughControllerAndSendsFunctionOutput() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)
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

        try await controller.start(apiKey: " sk-test \n")
        await session.emit(.toolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"galaxy"}"#), callId: "call-1"))

        XCTAssertEqual(session.startedAPIKeys, ["sk-test"])
        XCTAssertEqual(navigated, .galaxy)
        XCTAssertEqual(controller.status, .action("Opening Galaxy"))
        XCTAssertEqual(session.functionOutputs, [.init(callId: "call-1", output: "Opening Galaxy")])
    }

    func testRealtimeRejectedToolCallSendsRejectedFunctionOutput() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)

        try await controller.start(apiKey: "sk-test")
        await session.emit(.toolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"files"}"#), callId: "call-2"))

        XCTAssertEqual(controller.status, .error("Voice command rejected"))
        XCTAssertEqual(session.functionOutputs, [.init(callId: "call-2", output: "Voice command rejected")])
    }

    func testSearchMemoryToolReturnsFacadeOutput() async throws {
        let session = FakeRealtimeVoiceSession()
        let memory = FakeVoiceMemory(output: "- decision: Keep voice memory read-only.")
        let conversationId = UUID()
        let projectId = UUID()
        let controller = VoiceCommandController(session: session, memory: memory)
        controller.setMemoryContextProvider {
            VoiceMemoryContext(projectId: projectId, conversationId: conversationId)
        }

        try await controller.start(apiKey: "sk-test")
        await session.emit(.toolCall(
            .init(name: "search_memory", arguments: #"{"query":"voice memory","limit":4.0}"#),
            callId: "call-memory"
        ))

        XCTAssertEqual(controller.status, .action("Searching memory"))
        XCTAssertEqual(
            memory.searchRequests,
            [.init(query: "voice memory", limit: 4, context: VoiceMemoryContext(projectId: projectId, conversationId: conversationId))]
        )
        XCTAssertEqual(
            session.functionOutputs,
            [.init(callId: "call-memory", output: "- decision: Keep voice memory read-only.")]
        )
        XCTAssertNil(controller.pendingAction)
    }

    func testSearchMemoryRejectsFractionalLimitWithoutCallingFacade() async throws {
        let session = FakeRealtimeVoiceSession()
        let memory = FakeVoiceMemory(output: "should not be called")
        let conversationId = UUID()
        let controller = VoiceCommandController(session: session, memory: memory)
        controller.setMemoryContextProvider {
            VoiceMemoryContext(projectId: nil, conversationId: conversationId)
        }

        try await controller.start(apiKey: "sk-test")
        await session.emit(.toolCall(
            .init(name: "search_memory", arguments: #"{"query":"voice","limit":1.9}"#),
            callId: "call-fraction"
        ))

        XCTAssertTrue(memory.searchRequests.isEmpty)
        XCTAssertEqual(session.functionOutputs, [.init(callId: "call-fraction", output: "Voice command rejected")])
    }

    func testSearchMemoryClampsHugeLimitWithoutTrapping() async throws {
        let session = FakeRealtimeVoiceSession()
        let memory = FakeVoiceMemory(output: "- decision: Huge limit clamped.")
        let conversationId = UUID()
        let controller = VoiceCommandController(session: session, memory: memory)
        controller.setMemoryContextProvider {
            VoiceMemoryContext(projectId: nil, conversationId: conversationId)
        }

        try await controller.start(apiKey: "sk-test")
        await session.emit(.toolCall(
            .init(name: "search_memory", arguments: #"{"query":"voice","limit":1e100}"#),
            callId: "call-huge"
        ))

        XCTAssertEqual(memory.searchRequests.map(\.limit), [5])
        XCTAssertEqual(session.functionOutputs, [.init(callId: "call-huge", output: "- decision: Huge limit clamped.")])
    }

    func testSearchMemoryRestoresPendingConfirmationStatusAfterOutput() async throws {
        let session = FakeRealtimeVoiceSession()
        let memory = FakeVoiceMemory(output: "- decision: Pending action still visible.")
        let conversationId = UUID()
        let controller = VoiceCommandController(session: session, memory: memory)
        controller.setMemoryContextProvider {
            VoiceMemoryContext(projectId: nil, conversationId: conversationId)
        }

        try await controller.start(apiKey: "sk-test")
        await session.emit(.toolCall(
            .init(name: "propose_send_message", arguments: #"{"text":"Ship it."}"#),
            callId: "call-propose"
        ))
        await session.emit(.toolCall(
            .init(name: "search_memory", arguments: #"{"query":"pending"}"#),
            callId: "call-memory-pending"
        ))

        XCTAssertEqual(controller.pendingAction, .sendMessage(text: "Ship it."))
        XCTAssertEqual(controller.status, .needsConfirmation("Confirm send?"))
        XCTAssertEqual(
            session.functionOutputs,
            [
                .init(callId: "call-propose", output: "Confirm send?"),
                .init(callId: "call-memory-pending", output: "- decision: Pending action still visible.")
            ]
        )
    }

    func testMemoryReadFailureReturnsMemoryUnavailableWithoutStoppingVoice() async throws {
        let session = FakeRealtimeVoiceSession()
        let memory = FakeVoiceMemory(output: "unused")
        memory.searchError = FakeVoiceMemory.Error.readFailed
        let conversationId = UUID()
        let controller = VoiceCommandController(session: session, memory: memory)
        controller.setMemoryContextProvider {
            VoiceMemoryContext(projectId: nil, conversationId: conversationId)
        }

        try await controller.start(apiKey: "sk-test")
        await session.emit(.toolCall(
            .init(name: "search_memory", arguments: #"{"query":"voice"}"#),
            callId: "call-memory-error"
        ))

        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.status, .error("Memory unavailable"))
        XCTAssertEqual(session.stopCallCount, 0)
        XCTAssertEqual(session.functionOutputs, [.init(callId: "call-memory-error", output: "Memory unavailable.")])
    }

    func testRecallRecentConversationsWithoutContextReturnsFriendlyOutput() async throws {
        let session = FakeRealtimeVoiceSession()
        let memory = FakeVoiceMemory(output: "should not be called")
        let controller = VoiceCommandController(session: session, memory: memory)

        try await controller.start(apiKey: "sk-test")
        await session.emit(.toolCall(
            .init(name: "recall_recent_conversations", arguments: #"{"limit":2}"#),
            callId: "call-recent"
        ))

        XCTAssertEqual(controller.status, .action("Recalling recent chats"))
        XCTAssertTrue(memory.recallRequests.isEmpty)
        XCTAssertEqual(
            session.functionOutputs,
            [.init(callId: "call-recent", output: "No active conversation memory context.")]
        )
        XCTAssertNil(controller.pendingAction)
    }

    func testMemoryToolOutputDoesNotLeakIntoLaterRejectedToolCall() async throws {
        let session = FakeRealtimeVoiceSession()
        let memory = FakeVoiceMemory(output: "- decision: Prior memory.")
        let conversationId = UUID()
        let controller = VoiceCommandController(session: session, memory: memory)
        controller.setMemoryContextProvider {
            VoiceMemoryContext(projectId: nil, conversationId: conversationId)
        }

        try await controller.start(apiKey: "sk-test")
        await session.emit(.toolCall(
            .init(name: "search_memory", arguments: #"{"query":"prior"}"#),
            callId: "call-memory"
        ))
        await session.emit(.toolCall(
            .init(name: "navigate_to_tab", arguments: #"{"tab":"files"}"#),
            callId: "call-rejected"
        ))

        XCTAssertEqual(
            session.functionOutputs,
            [
                .init(callId: "call-memory", output: "- decision: Prior memory."),
                .init(callId: "call-rejected", output: "Voice command rejected")
            ]
        )
    }

    func testResponseDoneKeepsPendingConfirmationStatus() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)

        try await controller.start(apiKey: "sk-test")
        await session.emit(.toolCall(.init(name: "propose_send_message", arguments: #"{"text":"Ship it."}"#), callId: "call-3"))
        await session.emit(.responseDone)

        XCTAssertEqual(controller.pendingAction, .sendMessage(text: "Ship it."))
        XCTAssertEqual(controller.status, .needsConfirmation("Confirm send?"))
    }

    func testRejectedToolCallKeepsPendingConfirmationVisible() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)

        try await controller.start(apiKey: "sk-test")
        await session.emit(.toolCall(.init(name: "propose_note", arguments: #"{"title":"Decision","body":"Keep it small."}"#), callId: "call-4"))
        await session.emit(.toolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"files"}"#), callId: "call-5"))

        XCTAssertEqual(controller.pendingAction, .createNote(title: "Decision", body: "Keep it small."))
        XCTAssertEqual(controller.status, .needsConfirmation("Create note?"))
        XCTAssertEqual(
            session.functionOutputs,
            [
                .init(callId: "call-4", output: "Create note?"),
                .init(callId: "call-5", output: "Voice command rejected")
            ]
        )
    }

    func testRealtimeErrorMarksVoiceUnavailableAndInactive() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)

        try await controller.start(apiKey: "sk-test")
        await session.emit(.error("socket closed"))

        XCTAssertEqual(session.stopCallCount, 1)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.status, .error("Voice unavailable"))
    }

    func testSendFunctionOutputFailureStopsVoiceMode() async throws {
        let session = FakeRealtimeVoiceSession()
        session.sendFunctionOutputError = RealtimeVoiceSocketError.notConnected
        let controller = VoiceCommandController(session: session)

        try await controller.start(apiKey: "sk-test")
        await session.emit(.toolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"galaxy"}"#), callId: "call-6"))

        XCTAssertEqual(session.stopCallCount, 1)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.status, .error("Voice unavailable"))
    }

    func testInFlightSendFailureAfterStopDoesNotMutateIdleState() async throws {
        let session = FakeRealtimeVoiceSession()
        let sendGate = SendFunctionOutputGate()
        session.sendFunctionOutputGate = sendGate
        let controller = VoiceCommandController(session: session)

        try await controller.start(apiKey: "sk-test")
        let eventTask = Task {
            await session.emit(.toolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"galaxy"}"#), callId: "call-8"))
        }

        await sendGate.waitUntilInFlight()
        controller.stop()
        let stopCallCountAfterExplicitStop = session.stopCallCount
        await sendGate.release(error: RealtimeVoiceSocketError.notConnected)
        await eventTask.value

        XCTAssertEqual(stopCallCountAfterExplicitStop, 1)
        XCTAssertEqual(session.stopCallCount, 1)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.status, .idle)
    }

    func testInFlightSendFailureAfterRestartDoesNotStopNewSession() async throws {
        let session = FakeRealtimeVoiceSession()
        let sendGate = SendFunctionOutputGate()
        session.sendFunctionOutputGate = sendGate
        let controller = VoiceCommandController(session: session)

        try await controller.start(apiKey: "sk-old")
        let eventTask = Task {
            await session.emit(.toolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"galaxy"}"#), callId: "call-9"))
        }

        await sendGate.waitUntilInFlight()
        controller.stop()
        try await controller.start(apiKey: "sk-new")
        let stopCallCountBeforeStaleFailure = session.stopCallCount
        await sendGate.release(error: RealtimeVoiceSocketError.notConnected)
        await eventTask.value

        XCTAssertEqual(session.startedAPIKeys, ["sk-old", "sk-new"])
        XCTAssertEqual(stopCallCountBeforeStaleFailure, 1)
        XCTAssertEqual(session.stopCallCount, 1)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.status, .listening)
    }

    func testStaleEventAfterStopIsIgnored() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)
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

        try await controller.start(apiKey: "sk-test")
        controller.stop()
        await session.emit(.toolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"galaxy"}"#), callId: "call-7"))

        XCTAssertNil(navigated)
        XCTAssertEqual(session.functionOutputs, [])
        XCTAssertEqual(controller.status, .idle)
    }

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

private final class FakeRealtimeVoiceSession: RealtimeVoiceSessioning {
    struct FunctionOutput: Equatable {
        let callId: String
        let output: String
    }

    var startedAPIKeys: [String] = []
    var functionOutputs: [FunctionOutput] = []
    var stopCallCount = 0
    var sendFunctionOutputError: Error?
    var sendFunctionOutputGate: SendFunctionOutputGate?
    var startGates: [StartGate] = []

    private var onEvent: (@MainActor (RealtimeVoiceEvent) async -> Void)?

    func start(
        apiKey: String,
        onEvent: @escaping @MainActor (RealtimeVoiceEvent) async -> Void
    ) async throws {
        startedAPIKeys.append(apiKey)
        self.onEvent = onEvent
        if !startGates.isEmpty {
            let startGate = startGates.removeFirst()
            try await startGate.suspendUntilReleased()
        }
    }

    func sendFunctionOutput(callId: String, output: String) async throws {
        if let sendFunctionOutputGate {
            try await sendFunctionOutputGate.suspendUntilReleased()
        }
        if let sendFunctionOutputError {
            throw sendFunctionOutputError
        }
        functionOutputs.append(.init(callId: callId, output: output))
    }

    func stop() {
        stopCallCount += 1
    }

    func emit(_ event: RealtimeVoiceEvent) async {
        await onEvent?(event)
    }
}

private final class FakeVoiceMemory: VoiceMemorySearching {
    enum Error: Swift.Error {
        case readFailed
    }

    struct SearchRequest: Equatable {
        let query: String
        let limit: Int
        let context: VoiceMemoryContext
    }

    struct RecallRequest: Equatable {
        let limit: Int
        let context: VoiceMemoryContext
    }

    let output: String
    var searchRequests: [SearchRequest] = []
    var recallRequests: [RecallRequest] = []
    var searchError: Error?
    var recallError: Error?

    init(output: String) {
        self.output = output
    }

    func searchMemory(query: String, limit: Int, context: VoiceMemoryContext) throws -> String {
        searchRequests.append(.init(query: query, limit: limit, context: context))
        if let searchError {
            throw searchError
        }
        return output
    }

    func recallRecentConversations(limit: Int, context: VoiceMemoryContext) throws -> String {
        recallRequests.append(.init(limit: limit, context: context))
        if let recallError {
            throw recallError
        }
        return output
    }
}

private actor StartGate {
    private var isInFlight = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseError: Error?

    func waitUntilInFlight() async {
        guard !isInFlight else { return }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func suspendUntilReleased() async throws {
        isInFlight = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }

        if let releaseError {
            throw releaseError
        }
    }

    func release(error: Error?) {
        releaseError = error
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor SendFunctionOutputGate {
    private var isInFlight = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseError: Error?

    func waitUntilInFlight() async {
        guard !isInFlight else { return }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func suspendUntilReleased() async throws {
        isInFlight = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }

        if let releaseError {
            throw releaseError
        }
    }

    func release(error: Error?) {
        releaseError = error
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
