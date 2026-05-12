import Foundation

/// Auto-fire trigger for per-conversation reflection. Sits in the post-turn
/// pipeline and decides whether to invoke `PerConversationReflectionService`
/// in the background:
///
/// 1. The conversation must hit `PerConversationReflectionPrompt.minimumTurnCount()`
///    (default 16; overridable via UserDefaults).
/// 2. No prior reflection run (success / rejected / failed) must exist for
///    the conversation — each conversation gets at most one auto-fire.
///    Subsequent reflections are manual `/reflect` only.
///
/// Errors are swallowed. The trigger is fire-and-forget; a failed background
/// run lands as a `.failed` row via the service's own error path so the
/// debug inspector still sees the attempt.
@MainActor
final class PerConversationReflectionAutoTrigger {

    private let nodeStore: NodeStore
    private let serviceFactory: () -> PerConversationReflectionService?
    private let logger: (String) -> Void

    init(
        nodeStore: NodeStore,
        serviceFactory: @escaping () -> PerConversationReflectionService?,
        logger: @escaping (String) -> Void = { print("[PerConvAutoFire] \($0)") }
    ) {
        self.nodeStore = nodeStore
        self.serviceFactory = serviceFactory
        self.logger = logger
    }

    /// Called from the post-turn hook. Performs cheap gating on the main
    /// actor (turn count + DB idempotency check) and spawns the LLM call
    /// detached so the chat UI does not wait.
    func considerFire(
        nodeId: UUID,
        projectId: UUID?,
        messages: [Message]
    ) {
        let threshold = PerConversationReflectionPrompt.minimumTurnCount()
        guard messages.count >= threshold else { return }

        let conversationTitle: String
        do {
            if try nodeStore.hasPerConversationReflectionRun(nodeId: nodeId) {
                return
            }
            conversationTitle = (try nodeStore.fetchNode(id: nodeId))?.title ?? ""
        } catch {
            logger("idempotency check failed: \(error.localizedDescription)")
            return
        }

        guard let service = serviceFactory() else { return }

        let snapshot = messages
        Task.detached(priority: .background) { [logger] in
            do {
                _ = try await service.run(
                    conversationId: nodeId,
                    conversationTitle: conversationTitle,
                    projectId: projectId,
                    messages: snapshot
                )
            } catch {
                logger("fire failed for node \(nodeId): \(error.localizedDescription)")
            }
        }
    }
}
