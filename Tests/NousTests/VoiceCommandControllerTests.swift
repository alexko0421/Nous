import XCTest
@testable import Nous

@MainActor
final class VoiceCommandControllerTests: XCTestCase {
    func testVoiceModeToggleMissingKeyReportsUnavailableWithoutNavigationIntent() {
        XCTAssertEqual(
            VoiceModeTogglePolicy.action(isActive: false, isVoiceModeAvailable: false, apiKey: ""),
            .unavailable("Add OpenAI API key")
        )
    }

    func testVoiceModeToggleUsesSwitchSemanticsWhenConfigured() {
        XCTAssertEqual(
            VoiceModeTogglePolicy.action(isActive: false, isVoiceModeAvailable: true, apiKey: " sk-test \n"),
            .start(apiKey: " sk-test \n")
        )
        XCTAssertEqual(
            VoiceModeTogglePolicy.action(isActive: true, isVoiceModeAvailable: false, apiKey: ""),
            .stop
        )
    }

    func testVoiceStatusErrorsRemainVisibleWhileInactive() {
        XCTAssertTrue(VoiceModeStatus.error("Add OpenAI API key").shouldDisplayPill)
        XCTAssertFalse(VoiceModeStatus.idle.shouldDisplayPill)
    }

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

    func testRealtimeUserTranscriptStreamsIntoSubtitle() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)

        try await controller.start(apiKey: "sk-test")
        await session.emit(.inputTranscriptDelta("Open"))
        await session.emit(.inputTranscriptDelta(" Galaxy"))
        await session.emit(.inputTranscriptCompleted("Open Galaxy"))

        XCTAssertEqual(controller.subtitleText, "Open Galaxy")
        XCTAssertEqual(controller.status, .thinking)
    }

    func testRealtimeAssistantTranscriptStreamsIntoSubtitle() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)

        try await controller.start(apiKey: "sk-test")
        await session.emit(.outputTranscriptDelta("Opening"))
        await session.emit(.outputTranscriptDelta(" Galaxy"))
        await session.emit(.outputTranscriptCompleted("Opening Galaxy"))

        XCTAssertEqual(controller.subtitleText, "Opening Galaxy")
    }

    func testStopClearsRealtimeSubtitle() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)

        try await controller.start(apiKey: "sk-test")
        await session.emit(.inputTranscriptCompleted("Open Galaxy"))
        controller.stop()

        XCTAssertEqual(controller.subtitleText, "")
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.status, .idle)
    }

    func testToolOutputIncludesFreshAppStateWhenConfigured() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)
        controller.configure(
            VoiceActionHandlers(
                navigate: { _ in },
                setSidebarVisible: { _ in },
                setScratchPadVisible: { _ in },
                setComposerText: { _ in },
                appendComposerText: { _ in },
                clearComposer: {},
                startNewChat: {},
                createNote: { _, _ in },
                appSnapshot: {
                    VoiceAppSnapshot(
                        currentTab: .galaxy,
                        settingsSection: nil,
                        composerText: "",
                        selectedProjectName: "New York",
                        sidebarVisible: true,
                        scratchpadVisible: false,
                        activeConversationTitle: "Voice mode"
                    )
                }
            )
        )

        try await controller.start(apiKey: "sk-test")
        await session.emit(.toolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"galaxy"}"#), callId: "call-state-sync"))

        let output = try XCTUnwrap(session.functionOutputs.first?.output)
        XCTAssertTrue(output.contains("Opening Galaxy"))
        XCTAssertTrue(output.contains("APP_STATE:"))
        XCTAssertTrue(output.contains(#""current_tab":"galaxy""#))
    }

    func testRealtimeRejectedToolCallSendsRejectedFunctionOutput() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)

        try await controller.start(apiKey: "sk-test")
        await session.emit(.toolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"files"}"#), callId: "call-2"))

        XCTAssertEqual(controller.status, .error("Voice command rejected"))
        XCTAssertEqual(session.functionOutputs, [.init(callId: "call-2", output: "Voice command rejected")])
    }

    func testGetAppStateReturnsSnapshotToolOutput() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)
        controller.configure(
            VoiceActionHandlers(
                navigate: { _ in },
                setSidebarVisible: { _ in },
                setScratchPadVisible: { _ in },
                setComposerText: { _ in },
                appendComposerText: { _ in },
                clearComposer: {},
                startNewChat: {},
                createNote: { _, _ in },
                appSnapshot: {
                    VoiceAppSnapshot(
                        currentTab: .settings,
                        settingsSection: .models,
                        composerText: "Draft from voice",
                        selectedProjectName: "New York",
                        sidebarVisible: true,
                        scratchpadVisible: false,
                        activeConversationTitle: "Voice mode"
                    )
                }
            )
        )

        try await controller.start(apiKey: "sk-test")
        await session.emit(.toolCall(.init(name: "get_app_state", arguments: #"{}"#), callId: "call-state"))

        let output = try XCTUnwrap(session.functionOutputs.first?.output)
        let data = try XCTUnwrap(output.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(controller.status, .action("Reading app state"))
        XCTAssertEqual(json["current_tab"] as? String, "settings")
        XCTAssertEqual(json["settings_section"] as? String, "models")
        XCTAssertEqual(json["composer_text"] as? String, "Draft from voice")
        XCTAssertEqual(json["selected_project_name"] as? String, "New York")
        XCTAssertEqual(json["sidebar_visible"] as? Bool, true)
        XCTAssertEqual(json["scratchpad_visible"] as? Bool, false)
        XCTAssertEqual(json["active_conversation_title"] as? String, "Voice mode")
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
            .init(name: "propose_note", arguments: #"{"title":"Decision","body":"Ship it."}"#),
            callId: "call-propose"
        ))
        await session.emit(.toolCall(
            .init(name: "search_memory", arguments: #"{"query":"pending"}"#),
            callId: "call-memory-pending"
        ))

        XCTAssertEqual(controller.pendingAction, .createNote(title: "Decision", body: "Ship it."))
        XCTAssertEqual(controller.status, .needsConfirmation("Create note?"))
        XCTAssertEqual(
            session.functionOutputs,
            [
                .init(callId: "call-propose", output: "Create note?"),
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
        await session.emit(.toolCall(.init(name: "propose_note", arguments: #"{"title":"Decision","body":"Ship it."}"#), callId: "call-3"))
        await session.emit(.responseDone)

        XCTAssertEqual(controller.pendingAction, .createNote(title: "Decision", body: "Ship it."))
        XCTAssertEqual(controller.status, .needsConfirmation("Create note?"))
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

    func testRealtimeQuotaErrorShowsActionableStatus() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)

        try await controller.start(apiKey: "sk-test")
        await session.emit(.error("You exceeded your current quota, please check your plan and billing details."))

        XCTAssertEqual(session.stopCallCount, 1)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.status, .error("OpenAI quota exceeded"))
    }

    func testCleanSessionEndHidesVoiceMode() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)

        try await controller.start(apiKey: "sk-test")
        await session.emit(.inputTranscriptCompleted("Open Galaxy"))
        await session.emit(.sessionEnded)

        XCTAssertEqual(session.stopCallCount, 1)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.status, .idle)
        XCTAssertEqual(controller.subtitleText, "")
        XCTAssertEqual(controller.transcript, [])
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
                createNote: { _, _ in }
            )
        )

        try await controller.handleToolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"galaxy"}"#))

        XCTAssertEqual(navigated, .galaxy)
        XCTAssertEqual(controller.status, .action("Opening Galaxy"))
        XCTAssertNil(controller.pendingAction)
    }

    func testSetAppearanceModeToolUpdatesStatusAndCallsHandler() async throws {
        let controller = VoiceCommandController()
        var appearanceMode: VoiceAppearanceMode?
        controller.configure(
            VoiceActionHandlers(
                navigate: { _ in },
                setSidebarVisible: { _ in },
                setScratchPadVisible: { _ in },
                setComposerText: { _ in },
                appendComposerText: { _ in },
                clearComposer: {},
                startNewChat: {},
                createNote: { _, _ in },
                setAppearanceMode: { appearanceMode = $0 }
            )
        )

        try await controller.handleToolCall(.init(name: "set_appearance_mode", arguments: #"{"mode":"dark"}"#))

        XCTAssertEqual(appearanceMode, .dark)
        XCTAssertEqual(controller.status, .action("Dark Mode"))
        XCTAssertNil(controller.pendingAction)
    }

    func testOpenSettingsSectionKeepsActiveSession() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)
        var openedSection: VoiceSettingsSection?
        controller.configure(
            VoiceActionHandlers(
                navigate: { _ in },
                setSidebarVisible: { _ in },
                setScratchPadVisible: { _ in },
                setComposerText: { _ in },
                appendComposerText: { _ in },
                clearComposer: {},
                startNewChat: {},
                createNote: { _, _ in },
                openSettingsSection: { openedSection = $0 }
            )
        )

        try await controller.start(apiKey: "sk-test")
        await session.emit(.toolCall(
            .init(name: "open_settings_section", arguments: #"{"section":"models"}"#),
            callId: "call-settings"
        ))

        XCTAssertEqual(openedSection, .models)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(session.stopCallCount, 0)
        XCTAssertEqual(controller.status, .action("Opening Model Settings"))
        XCTAssertEqual(session.functionOutputs, [.init(callId: "call-settings", output: "Opening Model Settings")])
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

    func testPendingNoteIsNotOverwrittenBySecondProposedNote() async throws {
        let controller = VoiceCommandController()

        try await controller.handleToolCall(.init(name: "propose_note", arguments: #"{"title":"Original","body":"First body."}"#))

        await XCTAssertThrowsErrorAsync(
            try await controller.handleToolCall(.init(name: "propose_note", arguments: #"{"title":"Replacement","body":"Second body."}"#))
        ) { error in
            XCTAssertEqual(error as? VoiceToolError, .pendingActionAlreadyExists)
        }

        XCTAssertEqual(controller.pendingAction, .createNote(title: "Original", body: "First body."))
        XCTAssertEqual(controller.status, .needsConfirmation("Confirm current action first"))
    }

    func testConfirmExecutesPendingActionOnce() async throws {
        let controller = VoiceCommandController()
        var createdNotes: [(String, String)] = []
        controller.configure(
            VoiceActionHandlers(
                navigate: { _ in },
                setSidebarVisible: { _ in },
                setScratchPadVisible: { _ in },
                setComposerText: { _ in },
                appendComposerText: { _ in },
                clearComposer: {},
                startNewChat: {},
                createNote: { title, body in createdNotes.append((title, body)) }
            )
        )

        try await controller.handleToolCall(.init(name: "propose_note", arguments: #"{"title":"Decision","body":"Create once."}"#))
        controller.confirmPendingAction()
        controller.confirmPendingAction()

        XCTAssertEqual(createdNotes.map(\.0), ["Decision"])
        XCTAssertEqual(createdNotes.map(\.1), ["Create once."])
        XCTAssertNil(controller.pendingAction)
        XCTAssertEqual(controller.status, .action("Created note"))
    }

    func testCancelClearsPendingActionWithoutExecuting() async throws {
        let controller = VoiceCommandController()
        var created = false
        controller.configure(
            VoiceActionHandlers(
                navigate: { _ in },
                setSidebarVisible: { _ in },
                setScratchPadVisible: { _ in },
                setComposerText: { _ in },
                appendComposerText: { _ in },
                clearComposer: {},
                startNewChat: {},
                createNote: { _, _ in created = true }
            )
        )

        try await controller.handleToolCall(.init(name: "propose_note", arguments: #"{"title":"Decision","body":"Cancel me."}"#))
        controller.cancelPendingAction()

        XCTAssertFalse(created)
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

    func test_controllerRegistersAudioLevelHandlerInInit() {
        let session = FakeRealtimeVoiceSession()
        _ = VoiceCommandController(session: session)
        XCTAssertNotNil(session.audioLevelHandlerForTest)
    }

    func test_handlerForwardsLevelToControllerOnMainActor() async {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)
        XCTAssertEqual(controller.audioLevel, 0, accuracy: 0.0001)

        session.emitAudioLevel(0.7)
        // The handler hops to @MainActor via Task; yield once so it runs.
        await Task.yield()
        await MainActor.run {}

        XCTAssertEqual(controller.audioLevel, 0.7, accuracy: 0.0001)
    }

    func test_audioLevelClampedForOutOfRangeInputs() async {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)

        session.emitAudioLevel(1.5)
        await Task.yield()
        await MainActor.run {}
        XCTAssertEqual(controller.audioLevel, 1.0, accuracy: 0.0001)

        session.emitAudioLevel(-0.3)
        await Task.yield()
        await MainActor.run {}
        XCTAssertEqual(controller.audioLevel, 0.0, accuracy: 0.0001)
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
