import Foundation

struct PreparedConversationTurn {
    let node: NousNode
    let userMessage: Message
    let messagesAfterUserAppend: [Message]
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

final class ConversationSessionStore {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
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
        let node = if let currentNode {
            currentNode
        } else {
            try startConversation(title: newConversationTitle, projectId: defaultProjectId)
        }

        let userMessage = Message(nodeId: node.id, role: .user, content: userMessageContent)
        try nodeStore.insertMessage(userMessage)

        let messagesAfterUserAppend = currentMessages + [userMessage]
        let updatedNode = try persistTranscript(nodeId: node.id, messages: messagesAfterUserAppend)
        return PreparedConversationTurn(
            node: updatedNode,
            userMessage: userMessage,
            messagesAfterUserAppend: messagesAfterUserAppend
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
}
