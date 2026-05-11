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
