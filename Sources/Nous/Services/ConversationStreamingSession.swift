import Foundation
import Observation

/// Per-conversation streaming state owner.
///
/// Holds the in-flight assistant turn `Task`, the partial streamed buffers
/// (response / thinking / agent trace), and the `hasUnseenCompletion` flag
/// that drives the LeftSidebar unread dot. One instance per conversation
/// that has ever started a turn in this app session, owned by
/// `ConversationSessionStore.streamingSessions`.
///
/// Threading: `@MainActor`. All mutations and reads happen on the main
/// actor. The held `Task` may run off-actor internally but all writes
/// through the `append*` helpers hop back to main.
@Observable
@MainActor
final class ConversationStreamingSession {

    let conversationId: UUID

    // Partial streaming buffers (mirror ChatViewModel's pre-refactor properties).
    var currentResponse: String = ""
    var currentThinking: String = ""
    var currentThinkingStartedAt: Date?
    var currentAgentTrace: [AgentTraceRecord] = []
    var isGenerating: Bool = false
    var didHitBudgetExhaustion: Bool = false

    // In-flight task ownership.
    @ObservationIgnored nonisolated(unsafe) var inFlightTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var inFlightTurnId: UUID?
    @ObservationIgnored nonisolated(unsafe) var inFlightAbortReason: TurnAbortReason?

    // Background completion tracking.
    var hasUnseenCompletion: Bool = false
    var lastError: Error?

    init(conversationId: UUID) {
        self.conversationId = conversationId
    }
}

extension ConversationStreamingSession {

    func beginTurn(turnId: UUID, task: Task<Void, Never>) {
        inFlightTurnId = turnId
        inFlightTask = task
        inFlightAbortReason = nil
        currentResponse = ""
        currentThinking = ""
        currentThinkingStartedAt = Date()
        currentAgentTrace = []
        didHitBudgetExhaustion = false
        isGenerating = true
    }

    func finishTurn(viewingNow: Bool) {
        isGenerating = false
        inFlightTask = nil
        inFlightTurnId = nil
        inFlightAbortReason = nil
        if !viewingNow {
            hasUnseenCompletion = true
        }
    }

    func failTurn(_ error: Error, viewingNow: Bool) {
        lastError = error
        finishTurn(viewingNow: viewingNow)
    }

    /// Cancels the in-flight task and clears the slots. The cancelled task's completion handler still routes through finishTurn/failTurn for the isGenerating reset.
    func cancel() {
        inFlightTask?.cancel()
        inFlightTask = nil
        inFlightTurnId = nil
    }

    /// Clears `hasUnseenCompletion` and returns the one-shot `lastError`
    /// (if any) so the caller can surface it once and then move on.
    @discardableResult
    func markViewed() -> Error? {
        hasUnseenCompletion = false
        let err = lastError
        lastError = nil
        return err
    }

    /// Marks this turn finished unless it has been superseded by a different
    /// in-flight turn on this session. A `nil` `inFlightTurnId` is treated as
    /// "no contention" — the slot may have been migrated to another session
    /// (see `bindStreamingSession` in `ChatViewModel`) and the originating
    /// session still owns the unseen-completion flag. Returns `lastError`
    /// if any.
    @discardableResult
    func captureFinish(turnId: UUID, viewingNow: Bool, error: Error? = nil) -> Error? {
        if let inFlight = inFlightTurnId, inFlight != turnId {
            return nil
        }
        if let error {
            failTurn(error, viewingNow: viewingNow)
        } else {
            finishTurn(viewingNow: viewingNow)
        }
        return viewingNow ? nil : lastError
    }
}
