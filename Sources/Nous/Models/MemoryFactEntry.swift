import Foundation

/// Sidecar fact row for contradiction-oriented recall. This preserves the
/// single-active-entry invariant of `memory_entries` while letting retrieval
/// keep typed decision/boundary/constraint facts.
struct MemoryFactEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var scope: MemoryScope
    var scopeRefId: UUID?
    var kind: MemoryKind
    var content: String
    var confidence: Double
    var status: MemoryStatus
    var stability: MemoryStability
    var sourceNodeIds: [UUID]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        scope: MemoryScope,
        scopeRefId: UUID? = nil,
        kind: MemoryKind,
        content: String,
        confidence: Double = 0.8,
        status: MemoryStatus = .active,
        stability: MemoryStability,
        sourceNodeIds: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.scope = scope
        self.scopeRefId = scopeRefId
        self.kind = kind
        self.content = content
        self.confidence = confidence
        self.status = status
        self.stability = stability
        self.sourceNodeIds = sourceNodeIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
