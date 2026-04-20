import Foundation

/// The only entry shape the judge may cite. Built by `UserMemoryService.citableEntryPool(...)`
/// from raw `memory_entries` plus contradiction-oriented sidecar facts. `promptAnnotation`
/// is prompt-only metadata (for example `contradiction-candidate`) and does not change the
/// judge verdict schema.
struct CitableEntry: Equatable {
    let id: String
    let text: String
    let scope: MemoryScope
    let kind: MemoryKind?
    let promptAnnotation: String?

    init(
        id: String,
        text: String,
        scope: MemoryScope,
        kind: MemoryKind? = nil,
        promptAnnotation: String? = nil
    ) {
        self.id = id
        self.text = text
        self.scope = scope
        self.kind = kind
        self.promptAnnotation = promptAnnotation
    }
}
