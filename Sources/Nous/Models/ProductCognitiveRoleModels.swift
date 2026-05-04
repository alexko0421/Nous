import Foundation

enum ProductCognitiveRole: String, Equatable {
    case memoryCurator = "memory_curator"
    case contextEvidenceSteward = "context_evidence_steward"
    case connectionJudge = "connection_judge"
}

enum MemoryCurationLifecycle: String, Equatable {
    case stable
    case ephemeral
    case rejected
    case consentRequired = "consent_required"
}

struct MemoryCurationAssessment: Equatable {
    let role: ProductCognitiveRole
    let lifecycle: MemoryCurationLifecycle
    let kind: MemoryKind?
    let persistenceDecision: MemoryPersistenceDecision
    let reason: String
}

enum ContextEvidenceDropReason: String, Equatable {
    case empty
    case offTopic = "off_topic"
    case staleWithoutOverlap = "stale_without_overlap"
    case duplicate
}

struct ContextEvidenceDrop: Equatable {
    let role: ProductCognitiveRole
    let label: String
    let reason: ContextEvidenceDropReason
}

struct ContextEvidenceAssessment: Equatable {
    let role: ProductCognitiveRole
    let keptLabels: [String]
    let drops: [ContextEvidenceDrop]
}

enum ConnectionJudgeDecision: String, Equatable {
    case accept
    case reject
    case deferred = "defer"
}

struct ConnectionJudgeAssessment: Equatable {
    let role: ProductCognitiveRole
    let decision: ConnectionJudgeDecision
    let reason: String
    let verdict: GalaxyRelationVerdict?
}
