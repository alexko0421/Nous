import Foundation

struct PreparedConversationTurn {
    let node: NousNode
    let userMessage: Message
    let messagesAfterUserAppend: [Message]
    let recoveryEvent: ConversationRecoveryTelemetryEvent?

    init(
        node: NousNode,
        userMessage: Message,
        messagesAfterUserAppend: [Message],
        recoveryEvent: ConversationRecoveryTelemetryEvent? = nil
    ) {
        self.node = node
        self.userMessage = userMessage
        self.messagesAfterUserAppend = messagesAfterUserAppend
        self.recoveryEvent = recoveryEvent
    }
}

struct CommittedAssistantTurn {
    let node: NousNode
    let assistantMessage: Message
    let messagesAfterAssistantAppend: [Message]
}

struct CommittedVoiceTurn {
    let node: NousNode
    let userMessage: Message
    let messagesAfterAppend: [Message]
}

enum ConversationSessionStoreError: Error {
    case missingNode(UUID)
    case invalidRegenerationTarget
}

enum ConversationRecoveryReason: String, Codable, Equatable {
    case missingCurrentNode = "missing_current_node"
}

struct ConversationRecoveryTelemetryEvent: Codable, Equatable {
    let reason: ConversationRecoveryReason
    let originalNodeId: UUID
    let recoveredNodeId: UUID
    let rebasedMessageCount: Int
    let recordedAt: Date

    init(
        reason: ConversationRecoveryReason,
        originalNodeId: UUID,
        recoveredNodeId: UUID,
        rebasedMessageCount: Int,
        recordedAt: Date = Date()
    ) {
        self.reason = reason
        self.originalNodeId = originalNodeId
        self.recoveredNodeId = recoveredNodeId
        self.rebasedMessageCount = rebasedMessageCount
        self.recordedAt = recordedAt
    }
}

protocol ConversationRecoveryTelemetryRecording: AnyObject {
    func recordConversationRecovery(_ event: ConversationRecoveryTelemetryEvent)
}

final class ConversationSessionStore {
    private let nodeStore: NodeStore
    private let telemetry: (any ConversationRecoveryTelemetryRecording)?

    init(
        nodeStore: NodeStore,
        telemetry: (any ConversationRecoveryTelemetryRecording)? = nil
    ) {
        self.nodeStore = nodeStore
        self.telemetry = telemetry
    }

    func startConversation(
        title: String = "New Conversation",
        projectId: UUID? = nil
    ) throws -> NousNode {
        let node = NousNode(
            type: .conversation,
            title: title,
            projectId: projectId
        )
        try nodeStore.insertNode(node)
        return node
    }

    func prepareUserTurn(
        currentNode: NousNode?,
        currentMessages: [Message],
        defaultProjectId: UUID?,
        userMessageContent: String,
        newConversationTitle: String = "New Conversation"
    ) throws -> PreparedConversationTurn {
        let recovered = try recoverCurrentConversationIfNeeded(
            currentNode: currentNode,
            currentMessages: currentMessages,
            defaultProjectId: defaultProjectId,
            newConversationTitle: newConversationTitle
        )
        let node = recovered.node
        let rebasedCurrentMessages = recovered.currentMessages

        let userMessage = Message(nodeId: node.id, role: .user, content: userMessageContent)
        try nodeStore.insertMessage(userMessage)

        let messagesAfterUserAppend = rebasedCurrentMessages + [userMessage]
        let updatedNode = try persistTranscript(nodeId: node.id, messages: messagesAfterUserAppend)
        return PreparedConversationTurn(
            node: updatedNode,
            userMessage: userMessage,
            messagesAfterUserAppend: messagesAfterUserAppend,
            recoveryEvent: recovered.recoveryEvent
        )
    }

    func commitAssistantTurn(
        nodeId: UUID,
        currentMessages: [Message],
        assistantContent: String,
        thinkingContent: String? = nil,
        conversationTitle: String? = nil,
        judgeEventId: UUID? = nil,
        agentTraceJson: String? = nil
    ) throws -> CommittedAssistantTurn {
        let assistantMessage = Message(
            nodeId: nodeId,
            role: .assistant,
            content: assistantContent,
            thinkingContent: thinkingContent,
            agentTraceJson: agentTraceJson
        )
        try nodeStore.insertMessage(assistantMessage)

        let messagesAfterAssistantAppend = currentMessages + [assistantMessage]
        if let judgeEventId {
            try nodeStore.updateJudgeEventMessageId(
                eventId: judgeEventId,
                messageId: assistantMessage.id
            )
        }

        let updatedNode = try applyTitleAndPersistTranscript(
            nodeId: nodeId,
            messages: messagesAfterAssistantAppend,
            proposedTitle: conversationTitle
        )
        return CommittedAssistantTurn(
            node: updatedNode,
            assistantMessage: assistantMessage,
            messagesAfterAssistantAppend: messagesAfterAssistantAppend
        )
    }

    func removeAssistantTurn(
        nodeId: UUID,
        assistantMessage: Message,
        retainedMessages: [Message]
    ) throws -> NousNode {
        guard assistantMessage.role == .assistant,
              retainedMessages.allSatisfy({ $0.id != assistantMessage.id })
        else {
            throw ConversationSessionStoreError.invalidRegenerationTarget
        }

        try nodeStore.clearJudgeEventMessageId(messageId: assistantMessage.id)
        try nodeStore.deleteMessage(id: assistantMessage.id)
        return try persistTranscript(nodeId: nodeId, messages: retainedMessages)
    }

    func persistTranscript(nodeId: UUID, messages: [Message]) throws -> NousNode {
        guard let node = try nodeStore.fetchNode(id: nodeId) else {
            throw ConversationSessionStoreError.missingNode(nodeId)
        }
        return try persistTranscript(node: node, messages: messages)
    }

    private func applyTitleAndPersistTranscript(
        nodeId: UUID,
        messages: [Message],
        proposedTitle: String?
    ) throws -> NousNode {
        guard var node = try nodeStore.fetchNode(id: nodeId) else {
            throw ConversationSessionStoreError.missingNode(nodeId)
        }

        if let proposedTitle,
           Self.shouldAutoRenameConversation(currentTitle: node.title, messages: messages),
           node.title != proposedTitle {
            node.title = proposedTitle
        }

        return try persistTranscript(node: node, messages: messages)
    }

    private func persistTranscript(node: NousNode, messages: [Message]) throws -> NousNode {
        var updatedNode = node
        updatedNode.content = transcript(from: messages)
        updatedNode.updatedAt = Date()
        try nodeStore.updateNode(updatedNode)
        return updatedNode
    }

    private func transcript(from messages: [Message]) -> String {
        messages
            .map { message in
                let role = message.role == .user ? "Alex" : "Nous"
                return "\(role): \(message.content)"
            }
            .joined(separator: "\n\n")
    }

    private static func shouldAutoRenameConversation(
        currentTitle: String,
        messages: [Message]
    ) -> Bool {
        let trimmed = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        if ["new conversation", "new chat", "untitled"].contains(trimmed.lowercased()) {
            return true
        }

        if QuickActionMode.isPlaceholderConversationTitle(trimmed) {
            return true
        }

        guard let legacySeed = legacyConversationSeedTitle(from: messages) else { return false }
        return trimmed == legacySeed
    }

    private static func legacyConversationSeedTitle(from messages: [Message]) -> String? {
        guard let firstUser = messages.first(where: { $0.role == .user })?.content else {
            return nil
        }

        let queryOnly = firstUser
            .components(separatedBy: "\n\nFiles:")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? firstUser
        guard !queryOnly.isEmpty else { return nil }
        return String(queryOnly.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recoverCurrentConversationIfNeeded(
        currentNode: NousNode?,
        currentMessages: [Message],
        defaultProjectId: UUID?,
        newConversationTitle: String
    ) throws -> (node: NousNode, currentMessages: [Message], recoveryEvent: ConversationRecoveryTelemetryEvent?) {
        guard let currentNode else {
            let node = try startConversation(title: newConversationTitle, projectId: defaultProjectId)
            return (node, [], nil)
        }

        if let storedNode = try nodeStore.fetchNode(id: currentNode.id) {
            return (storedNode, currentMessages, nil)
        }

        let recoveredTitle = currentNode.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? newConversationTitle
            : currentNode.title
        let recoveredNode = try startConversation(
            title: recoveredTitle,
            projectId: try recoverableProjectId(currentNode.projectId ?? defaultProjectId)
        )
        let recoveredMessages = currentMessages.map { message in
            Message(
                id: message.id,
                nodeId: recoveredNode.id,
                role: message.role,
                content: message.content,
                timestamp: message.timestamp,
                thinkingContent: message.thinkingContent,
                agentTraceJson: message.agentTraceJson,
                source: message.source
            )
        }

        for message in recoveredMessages {
            try nodeStore.insertMessage(message)
        }

        let recoveryEvent = ConversationRecoveryTelemetryEvent(
            reason: .missingCurrentNode,
            originalNodeId: currentNode.id,
            recoveredNodeId: recoveredNode.id,
            rebasedMessageCount: recoveredMessages.count
        )
        telemetry?.recordConversationRecovery(recoveryEvent)

        return (recoveredNode, recoveredMessages, recoveryEvent)
    }

    private func recoverableProjectId(_ projectId: UUID?) throws -> UUID? {
        guard let projectId else { return nil }
        return try nodeStore.fetchProject(id: projectId) == nil ? nil : projectId
    }
}

extension ConversationSessionStore {
    /// Append a voice user message to the given conversation. Inserts into
    /// `messages` (with `source: .voice`) and updates `nodes.content` via
    /// `persistTranscript`. Throws `missingNode` if the conversation does
    /// not exist (e.g. user deleted it mid-session).
    func appendVoiceUserMessage(
        nodeId: UUID,
        text: String,
        timestamp: Date
    ) throws -> CommittedVoiceTurn {
        guard let node = try nodeStore.fetchNode(id: nodeId) else {
            throw ConversationSessionStoreError.missingNode(nodeId)
        }

        let userMessage = Message(
            nodeId: node.id,
            role: .user,
            content: text,
            timestamp: timestamp,
            source: .voice
        )
        try nodeStore.insertMessage(userMessage)

        let messagesAfterAppend = try nodeStore.fetchMessages(nodeId: node.id)
        let updatedNode = try persistTranscript(nodeId: node.id, messages: messagesAfterAppend)

        return CommittedVoiceTurn(
            node: updatedNode,
            userMessage: userMessage,
            messagesAfterAppend: messagesAfterAppend
        )
    }

    /// Append a voice assistant message to the given conversation. Inserts
    /// into `messages` (with `source: .voice`) and updates `nodes.content`
    /// via `persistTranscript`.
    func appendVoiceAssistantMessage(
        nodeId: UUID,
        text: String,
        timestamp: Date
    ) throws -> CommittedAssistantTurn {
        guard let node = try nodeStore.fetchNode(id: nodeId) else {
            throw ConversationSessionStoreError.missingNode(nodeId)
        }

        let assistantMessage = Message(
            nodeId: node.id,
            role: .assistant,
            content: text,
            timestamp: timestamp,
            source: .voice
        )
        try nodeStore.insertMessage(assistantMessage)

        let messagesAfterAppend = try nodeStore.fetchMessages(nodeId: node.id)
        let updatedNode = try persistTranscript(nodeId: node.id, messages: messagesAfterAppend)

        return CommittedAssistantTurn(
            node: updatedNode,
            assistantMessage: assistantMessage,
            messagesAfterAssistantAppend: messagesAfterAppend
        )
    }
}
