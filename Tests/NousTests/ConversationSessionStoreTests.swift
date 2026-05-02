import XCTest
@testable import Nous

final class ConversationSessionStoreTests: XCTestCase {
    private var store: NodeStore!
    private var sessionStore: ConversationSessionStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try NodeStore(path: ":memory:")
        sessionStore = ConversationSessionStore(nodeStore: store)
    }

    override func tearDownWithError() throws {
        sessionStore = nil
        store = nil
        try super.tearDownWithError()
    }

    func testPrepareUserTurnCreatesConversationWhenCurrentNodeMissing() throws {
        let project = Project(title: "Nous")
        try store.insertProject(project)

        let prepared = try sessionStore.prepareUserTurn(
            currentNode: nil,
            currentMessages: [],
            defaultProjectId: project.id,
            userMessageContent: "How should I sequence the refactor?"
        )

        XCTAssertEqual(prepared.node.projectId, project.id)
        XCTAssertEqual(prepared.userMessage.role, .user)
        XCTAssertEqual(prepared.messagesAfterUserAppend.map(\.id), [prepared.userMessage.id])

        let storedNode = try XCTUnwrap(store.fetchNode(id: prepared.node.id))
        XCTAssertEqual(
            storedNode.content,
            "Alex: How should I sequence the refactor?"
        )
        let storedMessages = try store.fetchMessages(nodeId: prepared.node.id)
        XCTAssertEqual(storedMessages.count, 1)
        XCTAssertEqual(storedMessages.first?.content, "How should I sequence the refactor?")
    }

    func testPrepareUserTurnRecoversRestoredConversationWhenCurrentNodeMissingFromStore() throws {
        let missingNode = NousNode(
            type: .conversation,
            title: "手滑打错字"
        )
        let restoredUser = Message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000601")!,
            nodeId: missingNode.id,
            role: .user,
            content: "，，。？",
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let restoredAssistant = Message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000602")!,
            nodeId: missingNode.id,
            role: .assistant,
            content: "哈，手滑咗？",
            timestamp: Date(timeIntervalSince1970: 101)
        )

        let prepared = try sessionStore.prepareUserTurn(
            currentNode: missingNode,
            currentMessages: [restoredUser, restoredAssistant],
            defaultProjectId: nil,
            userMessageContent: "I was on the bus listening to an old song."
        )

        XCTAssertNotEqual(prepared.node.id, missingNode.id)
        XCTAssertEqual(prepared.node.title, "手滑打错字")
        XCTAssertEqual(
            prepared.messagesAfterUserAppend.map(\.content),
            ["，，。？", "哈，手滑咗？", "I was on the bus listening to an old song."]
        )
        XCTAssertTrue(prepared.messagesAfterUserAppend.allSatisfy { $0.nodeId == prepared.node.id })

        let storedNode = try XCTUnwrap(store.fetchNode(id: prepared.node.id))
        XCTAssertEqual(storedNode.title, "手滑打错字")
        XCTAssertEqual(
            storedNode.content,
            """
            Alex: ，，。？

            Nous: 哈，手滑咗？

            Alex: I was on the bus listening to an old song.
            """
        )

        let storedMessages = try store.fetchMessages(nodeId: prepared.node.id)
        XCTAssertEqual(storedMessages.map(\.content), prepared.messagesAfterUserAppend.map(\.content))
    }

    func testPrepareUserTurnRecordsRecoveryTelemetryWhenCurrentNodeMissingFromStore() throws {
        let telemetry = RecordingConversationRecoveryTelemetry()
        sessionStore = ConversationSessionStore(nodeStore: store, telemetry: telemetry)
        let missingNode = NousNode(type: .conversation, title: "Restored")
        let restoredUser = Message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!,
            nodeId: missingNode.id,
            role: .user,
            content: "Old visible turn"
        )

        let prepared = try sessionStore.prepareUserTurn(
            currentNode: missingNode,
            currentMessages: [restoredUser],
            defaultProjectId: nil,
            userMessageContent: "Continue from here."
        )

        XCTAssertEqual(telemetry.events.count, 1)
        let event = try XCTUnwrap(telemetry.events.first)
        XCTAssertEqual(event.reason, .missingCurrentNode)
        XCTAssertEqual(event.originalNodeId, missingNode.id)
        XCTAssertEqual(event.recoveredNodeId, prepared.node.id)
        XCTAssertEqual(event.rebasedMessageCount, 1)
    }

    func testPrepareUserTurnDoesNotRecordRecoveryTelemetryWhenCurrentNodeStillExists() throws {
        let telemetry = RecordingConversationRecoveryTelemetry()
        sessionStore = ConversationSessionStore(nodeStore: store, telemetry: telemetry)
        let node = try sessionStore.startConversation(title: "Existing")

        _ = try sessionStore.prepareUserTurn(
            currentNode: node,
            currentMessages: [],
            defaultProjectId: nil,
            userMessageContent: "Normal turn."
        )

        XCTAssertTrue(telemetry.events.isEmpty)
    }

    func testCommitAssistantTurnRenamesPlaceholderTitleAndPatchesJudgeEvent() throws {
        let node = try sessionStore.startConversation(projectId: nil)
        let userMessage = Message(nodeId: node.id, role: .user, content: "Should I move to New York or Austin?")
        try store.insertMessage(userMessage)
        let event = JudgeEvent(
            id: UUID(),
            ts: Date(),
            nodeId: node.id,
            messageId: nil,
            chatMode: .companion,
            provider: .gemini,
            verdictJSON: "{}",
            fallbackReason: .ok,
            userFeedback: nil,
            feedbackTs: nil
        )
        try store.appendJudgeEvent(event)

        let committed = try sessionStore.commitAssistantTurn(
            nodeId: node.id,
            currentMessages: [userMessage],
            assistantContent: "Let me compare both cities from your actual constraints.",
            conversationTitle: "move to New York or Austin",
            judgeEventId: event.id
        )

        XCTAssertEqual(committed.node.title, "move to New York or Austin")
        XCTAssertEqual(committed.messagesAfterAssistantAppend.count, 2)
        XCTAssertEqual(committed.assistantMessage.content, "Let me compare both cities from your actual constraints.")

        let storedNode = try XCTUnwrap(store.fetchNode(id: node.id))
        XCTAssertEqual(storedNode.title, "move to New York or Austin")
        XCTAssertTrue(storedNode.content.contains("Nous: Let me compare both cities from your actual constraints."))

        let storedEvent = try XCTUnwrap(store.fetchJudgeEvent(id: event.id))
        XCTAssertEqual(storedEvent.messageId, committed.assistantMessage.id)
    }

    func testCommitAssistantTurnKeepsCuratedTitle() throws {
        let node = try sessionStore.startConversation(title: "Future of Parenting")
        let userMessage = Message(nodeId: node.id, role: .user, content: "AI时代仲要唔要生细路？")
        try store.insertMessage(userMessage)

        let committed = try sessionStore.commitAssistantTurn(
            nodeId: node.id,
            currentMessages: [userMessage],
            assistantContent: "我会由几个角度拆。",
            conversationTitle: "AI 时代仲要唔要生细路"
        )

        XCTAssertEqual(committed.node.title, "Future of Parenting")
        let storedNode = try XCTUnwrap(store.fetchNode(id: node.id))
        XCTAssertEqual(storedNode.title, "Future of Parenting")
    }

    func testCommitAssistantTurnPersistsAgentTraceJson() throws {
        let node = try sessionStore.startConversation()
        let trace = try XCTUnwrap(AgentTraceCodec.encode([
            AgentTraceRecord(kind: .toolResult, toolName: AgentToolNames.searchMemory, title: "Memory results", detail: "Matched")
        ]))

        let committed = try sessionStore.commitAssistantTurn(
            nodeId: node.id,
            currentMessages: [],
            assistantContent: "Done",
            agentTraceJson: trace
        )

        XCTAssertEqual(committed.assistantMessage.agentTraceJson, trace)
        let storedMessage = try XCTUnwrap(try store.fetchMessages(nodeId: node.id).first)
        XCTAssertEqual(storedMessage.agentTraceJson, trace)
        XCTAssertEqual(storedMessage.decodedAgentTraceRecords.first?.detail, "Matched")
    }
}

private final class RecordingConversationRecoveryTelemetry: ConversationRecoveryTelemetryRecording {
    private(set) var events: [ConversationRecoveryTelemetryEvent] = []

    func recordConversationRecovery(_ event: ConversationRecoveryTelemetryEvent) {
        events.append(event)
    }
}
