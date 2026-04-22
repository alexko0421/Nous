import Foundation

enum JudgeFeedback: String, Codable {
    case up
    case down
}

enum JudgeFeedbackReason: String, Codable, CaseIterable, Identifiable {
    case wrongMemory = "wrong_memory"
    case wrongTiming = "wrong_timing"
    case tooForceful = "too_forceful"
    case tooRepetitive = "too_repetitive"
    case notUseful = "not_useful"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wrongMemory:
            return "Wrong memory"
        case .wrongTiming:
            return "Wrong timing"
        case .tooForceful:
            return "Too forceful"
        case .tooRepetitive:
            return "Too repetitive"
        case .notUseful:
            return "Not useful"
        }
    }
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
    var feedbackReason: JudgeFeedbackReason? = nil
    var feedbackNote: String? = nil
}
