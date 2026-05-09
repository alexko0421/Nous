import Foundation

/// The only entry shape the judge may cite. Built by `UserMemoryService.citableEntryPool(...)`
/// from raw `memory_entries` plus contradiction-oriented sidecar facts. `promptAnnotation`
/// is prompt-only metadata (for example `contradiction-candidate`) and does not change the
/// judge verdict schema.
///
/// Atom-level metadata (`confidence`, `eventTime`, `sourceNodeId`, `atomType`, `recordedAt`)
/// is preserved when the entry originates from `memory_atoms`, `reflection_claim`, or any
/// source that carries provenance. CorpusCardFormatter renders these as
/// `[type · YYYY-MM-DD · conf 0.XX]` headers; absent fields render as plain entries.
/// All five are optional and additive — existing call sites that don't supply them
/// continue to compile unchanged.
struct CitableEntry: Equatable {
    let id: String
    let text: String
    let scope: MemoryScope
    let kind: MemoryKind?
    let promptAnnotation: String?
    let confidence: Double?
    let eventTime: Date?
    let sourceNodeId: UUID?
    let atomType: MemoryAtomType?
    let recordedAt: Date?

    init(
        id: String,
        text: String,
        scope: MemoryScope,
        kind: MemoryKind? = nil,
        promptAnnotation: String? = nil,
        confidence: Double? = nil,
        eventTime: Date? = nil,
        sourceNodeId: UUID? = nil,
        atomType: MemoryAtomType? = nil,
        recordedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.scope = scope
        self.kind = kind
        self.promptAnnotation = promptAnnotation
        self.confidence = confidence
        self.eventTime = eventTime
        self.sourceNodeId = sourceNodeId
        self.atomType = atomType
        self.recordedAt = recordedAt
    }
}
