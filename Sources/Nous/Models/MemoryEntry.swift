import Foundation

enum MemoryScope: String, Codable {
    case global
    case project
    case conversation
}

enum MemoryKind: String, Codable, CaseIterable {
    case identity
    case preference
    case constraint
    case relationship
    case thread
    case temporaryContext = "temporary_context"
}

enum MemoryStability: String, Codable, CaseIterable {
    case stable
    case temporary
}

enum MemoryStatus: String, Codable {
    case active
    case archived
    case conflicted
    case superseded
    case expired
}

/// Structured memory row. v2.2b writes one entry per scope+scopeRefId in
/// parallel with the existing v2.1 scope blob. Blob remains the read path.
/// v2.2c will flip the read path onto active entries per scope.
struct MemoryEntry: Identifiable, Codable {
    let id: UUID
    var scope: MemoryScope
    var scopeRefId: UUID?
    var kind: MemoryKind
    var stability: MemoryStability
    var status: MemoryStatus
    var content: String
    var confidence: Double
    var sourceNodeIds: [UUID]
    let createdAt: Date
    var updatedAt: Date
    var lastConfirmedAt: Date?
    var expiresAt: Date?
    var supersededBy: UUID?

    init(
        id: UUID = UUID(),
        scope: MemoryScope,
        scopeRefId: UUID? = nil,
        kind: MemoryKind,
        stability: MemoryStability,
        status: MemoryStatus = .active,
        content: String,
        confidence: Double = 0.8,
        sourceNodeIds: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastConfirmedAt: Date? = nil,
        expiresAt: Date? = nil,
        supersededBy: UUID? = nil
    ) {
        self.id = id
        self.scope = scope
        self.scopeRefId = scopeRefId
        self.kind = kind
        self.stability = stability
        self.status = status
        self.content = content
        self.confidence = confidence
        self.sourceNodeIds = sourceNodeIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastConfirmedAt = lastConfirmedAt
        self.expiresAt = expiresAt
        self.supersededBy = supersededBy
    }
}
