import Foundation

/// `CitableEntry` paired with the resolved `NousNode` for its `sourceNodeId`,
/// when one exists. Reflection claims and atoms whose source node has been
/// deleted carry `node: nil` (rendered non-clickable in `CorpusAtomCardListView`).
///
/// Built once per turn in `TurnMemoryContextBuilder` so the resolution is a
/// single batched read off the hot path; downstream view models stay
/// presentation-only and never reach into `NodeStore`.
struct ResolvedCitableEntry {
    let entry: CitableEntry
    let node: NousNode?
}
