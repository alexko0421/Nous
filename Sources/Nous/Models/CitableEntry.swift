import Foundation

/// The only entry shape the judge may cite. Built by `UserMemoryService.citableEntryPool(...)`
/// from raw `memory_entries` via node-hit bridging. The judge sees `id` + `text`; `scope`
/// is carried for telemetry and scope-boundary debugging, but the judge prompt does not
/// surface it.
struct CitableEntry: Equatable {
    let id: String
    let text: String
    let scope: MemoryScope
}
