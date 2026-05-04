import Foundation

enum ShadowPatternKind: String, Codable, CaseIterable {
    case thinkingMove = "thinking_move"
    case responseBehavior = "response_behavior"
}

enum ShadowPatternStatus: String, Codable, CaseIterable {
    case observed
    case soft
    case strong
    case fading
    case retired
}

enum LearningEventType: String, Codable, CaseIterable {
    case observed
    case reinforced
    case corrected
    case weakened
    case promoted
    case retired
    case revived
}

struct ShadowLearningPattern: Identifiable, Equatable, Codable {
    var id: UUID
    var userId: String
    var kind: ShadowPatternKind
    var label: String
    var summary: String
    var promptFragment: String
    var triggerHint: String
    var confidence: Double
    var weight: Double
    var status: ShadowPatternStatus
    var evidenceMessageIds: [UUID]
    var firstSeenAt: Date
    var lastSeenAt: Date
    var lastReinforcedAt: Date?
    var lastCorrectedAt: Date?
    var activeFrom: Date?
    var activeUntil: Date?
}

struct LearningEvent: Identifiable, Equatable, Codable {
    var id: UUID
    var userId: String
    var patternId: UUID?
    var sourceMessageId: UUID?
    var eventType: LearningEventType
    var note: String
    var createdAt: Date
}

struct ShadowLearningState: Equatable {
    var userId: String
    var lastRunAt: Date?
    var lastScannedMessageAt: Date?
    var lastScannedMessageId: UUID?
    var lastConsolidatedAt: Date?
}
