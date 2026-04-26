import Foundation

enum ReflectionRunStatus: String, Codable {
    case success
    case rejectedAll = "rejected_all"
    case failed
}

enum ReflectionRejectionReason: String, Codable {
    case generic
    case unsupported
    case lowConfidence = "low_confidence"
    case apiError = "api_error"
    case singleConversationEvidence = "single_conversation_evidence"
}

enum ReflectionClaimStatus: String, Codable {
    case active
    case orphaned
    case superseded
}

/// One row per weekly reflection job. Unique per (projectId, weekStart, weekEnd)
/// so foreground-trigger and retry paths can safely no-op on duplicates.
struct ReflectionRun: Identifiable, Codable, Equatable {
    let id: UUID
    /// `nil` = free-chat scope (no project). Matches the nullable `project_id`
    /// column on `reflection_runs`, which reflects that most nodes in the real
    /// DB have `projectId IS NULL` (Alex's primary usage as of 2026-04-22).
    var projectId: UUID?
    var weekStart: Date
    var weekEnd: Date
    var ranAt: Date
    var status: ReflectionRunStatus
    var rejectionReason: ReflectionRejectionReason?
    var costCents: Int?

    init(
        id: UUID = UUID(),
        projectId: UUID? = nil,
        weekStart: Date,
        weekEnd: Date,
        ranAt: Date = Date(),
        status: ReflectionRunStatus,
        rejectionReason: ReflectionRejectionReason? = nil,
        costCents: Int? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.ranAt = ranAt
        self.status = status
        self.rejectionReason = rejectionReason
        self.costCents = costCents
    }
}

/// A validator-passed reflection claim. Evidence binding is one-to-many via
/// `ReflectionEvidence`. When cascading message deletes drop evidence below
/// the validator's minimum (2), app code flips `status` to `.orphaned` and
/// the claim falls out of retrieval.
struct ReflectionClaim: Identifiable, Codable, Equatable {
    let id: UUID
    var runId: UUID
    var claim: String
    var confidence: Double
    var whyNonObvious: String
    var status: ReflectionClaimStatus
    let createdAt: Date

    init(
        id: UUID = UUID(),
        runId: UUID,
        claim: String,
        confidence: Double,
        whyNonObvious: String,
        status: ReflectionClaimStatus = .active,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.runId = runId
        self.claim = claim
        self.confidence = confidence
        self.whyNonObvious = whyNonObvious
        self.status = status
        self.createdAt = createdAt
    }
}

/// Join row binding one claim to one supporting ChatMessage. Cascades from
/// both sides: delete the claim or the message and this row goes away.
struct ReflectionEvidence: Codable, Equatable, Hashable {
    var reflectionId: UUID
    var messageId: UUID
}
