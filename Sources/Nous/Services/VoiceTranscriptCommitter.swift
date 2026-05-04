import Foundation

/// Glue between `VoiceCommandController` finalized transcript callbacks and
/// `ChatViewModel` voice append methods (which persist into the bound chat
/// and run housekeeping).
///
/// Owns a dedup set keyed by `VoiceTranscriptLine.id`. Resets the set
/// whenever the controller signals session termination via
/// `onVoiceSessionTerminated`.
@MainActor
final class VoiceTranscriptCommitter {
    private weak var voiceController: VoiceCommandController?
    private weak var chatViewModel: ChatViewModel?
    private(set) var committedLineIds: Set<UUID> = []

    init(voiceController: VoiceCommandController, chatViewModel: ChatViewModel) {
        self.voiceController = voiceController
        self.chatViewModel = chatViewModel
        voiceController.onUserUtteranceFinalized = { [weak self] line in
            self?.commit(line, expectedRole: .user)
        }
        voiceController.onAssistantUtteranceFinalized = { [weak self] line in
            self?.commit(line, expectedRole: .assistant)
        }
        voiceController.onVoiceSessionTerminated = { [weak self] in
            self?.committedLineIds.removeAll()
        }
    }

    // Note: deinit cannot reset the controller's closures because the
    // controller is @MainActor-isolated and `deinit` runs in a nonisolated
    // context. The closures captured `[weak self]`, so once this committer
    // deallocates, the closures become no-ops on their own.

    private func commit(_ line: VoiceTranscriptLine, expectedRole: VoiceTranscriptLine.Role) {
        guard line.role == expectedRole else { return }
        guard !committedLineIds.contains(line.id) else { return }
        guard let conversationId = voiceController?.boundConversationId else { return }
        guard let viewModel = chatViewModel else { return }

        do {
            switch line.role {
            case .user:
                try viewModel.appendVoiceMessage(
                    nodeId: conversationId,
                    text: line.text,
                    timestamp: line.createdAt
                )
            case .assistant:
                try viewModel.appendVoiceAssistantMessage(
                    nodeId: conversationId,
                    text: line.text,
                    timestamp: line.createdAt
                )
            }
            committedLineIds.insert(line.id)
        } catch ConversationSessionStoreError.missingNode {
            voiceController?.failVoiceSession(message: "Conversation deleted")
        } catch {
            // Phase 1 policy: log only, no retry.
            print("[VoiceTranscriptCommitter] commit failed: \(error)")
        }
    }
}
