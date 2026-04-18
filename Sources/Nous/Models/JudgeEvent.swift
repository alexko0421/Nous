import Foundation

enum JudgeFeedback: String, Codable {
    case up
    case down
}

/// One row in the `judge_events` SQLite table. Append-once, feedback can be patched in later
/// via `GovernanceTelemetryStore.recordFeedback(eventId:feedback:)`.
struct JudgeEvent: Identifiable, Equatable {
    let id: UUID
    let ts: Date
    let nodeId: UUID
    /// nil if the judge failed before a reply was produced, or if the turn is still mid-flight.
    var messageId: UUID?
    let chatMode: ChatMode
    let provider: LLMProvider
    /// Full verdict as emitted by the judge, JSON-encoded. Kept as a blob so future fields
    /// added to `JudgeVerdict` are forward-compatible without schema migrations.
    let verdictJSON: String
    let fallbackReason: JudgeFallbackReason
    var userFeedback: JudgeFeedback?
    var feedbackTs: Date?
}
