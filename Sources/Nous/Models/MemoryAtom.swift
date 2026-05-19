import Foundation

enum MemoryAuthority: String, Codable, CaseIterable {
    case tentative
    case durable
}

enum MemoryAtomType: String, Codable, CaseIterable {
    case identity
    case preference
    case rule
    case boundary
    case constraint
    case goal
    case plan
    case proposal
    case decision
    case rejection
    case reason
    case belief
    case correction
    case pattern
    case event
    case insight
    case entity
    case task
    case currentPosition = "current_position"
}

struct MemoryAtom: Identifiable, Codable, Equatable {
    let id: UUID
    var type: MemoryAtomType
    var statement: String
    var normalizedKey: String?
    var scope: MemoryScope
    var scopeRefId: UUID?
    var status: MemoryStatus
    var authority: MemoryAuthority
    var confidence: Double
    var eventTime: Date?
    var validFrom: Date?
    var validUntil: Date?
    let createdAt: Date
    var updatedAt: Date
    var lastSeenAt: Date?
    var sourceNodeId: UUID?
    var sourceMessageId: UUID?
    var evidenceQuote: String?
    var captureReason: String?
    var correctsTarget: String?
    var embedding: [Float]?

    init(
        id: UUID = UUID(),
        type: MemoryAtomType,
        statement: String,
        normalizedKey: String? = nil,
        scope: MemoryScope,
        scopeRefId: UUID? = nil,
        status: MemoryStatus = .active,
        authority: MemoryAuthority = .durable,
        confidence: Double = 0.7,
        eventTime: Date? = nil,
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastSeenAt: Date? = nil,
        sourceNodeId: UUID? = nil,
        sourceMessageId: UUID? = nil,
        evidenceQuote: String? = nil,
        captureReason: String? = nil,
        correctsTarget: String? = nil,
        embedding: [Float]? = nil
    ) {
        self.id = id
        self.type = type
        self.statement = statement
        self.normalizedKey = normalizedKey
        self.scope = scope
        self.scopeRefId = scopeRefId
        self.status = status
        self.authority = authority
        self.confidence = confidence
        self.eventTime = eventTime
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSeenAt = lastSeenAt
        self.sourceNodeId = sourceNodeId
        self.sourceMessageId = sourceMessageId
        self.evidenceQuote = evidenceQuote
        self.captureReason = captureReason
        self.correctsTarget = correctsTarget
        self.embedding = embedding
    }
}
