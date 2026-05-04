import Foundation

struct MemoryAtomEmbeddingBackfillReport: Equatable {
    var scanned = 0
    var skippedAlreadyEmbedded = 0
    var skippedEmptyStatement = 0
    var embedded = 0
    var failed = 0
}

/// One-shot per-launch fill of the `embedding` column on `memory_atoms`
/// rows that don't have one yet. Without this, atoms written before the
/// embed function was wired (or before the embedding model loaded) stay
/// invisible to the planner's vector entry-point — they are findable
/// only through keyword cues. Idempotent: only touches rows where
/// `embedding IS NULL`. Bounded: the per-call `maxAtoms` cap keeps a
/// fresh launch with a large unembedded corpus from blocking the UI.
final class MemoryAtomEmbeddingBackfillService {
    private let nodeStore: NodeStore
    private let embed: (String) -> [Float]?

    init(
        nodeStore: NodeStore,
        embed: @escaping (String) -> [Float]? = { _ in nil }
    ) {
        self.nodeStore = nodeStore
        self.embed = embed
    }

    @discardableResult
    func runIfNeeded(maxAtoms: Int = 64) throws -> MemoryAtomEmbeddingBackfillReport {
        var report = MemoryAtomEmbeddingBackfillReport()
        guard maxAtoms > 0 else { return report }

        let atoms = try nodeStore.fetchMemoryAtoms()
        var processed = 0
        for var atom in atoms {
            if processed >= maxAtoms { break }
            report.scanned += 1

            guard atom.embedding == nil else {
                report.skippedAlreadyEmbedded += 1
                continue
            }

            let statement = atom.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statement.isEmpty else {
                report.skippedEmptyStatement += 1
                continue
            }

            guard let vector = embed(statement) else {
                report.failed += 1
                continue
            }

            atom.embedding = vector
            atom.updatedAt = Date()
            try nodeStore.updateMemoryAtom(atom)
            report.embedded += 1
            processed += 1
        }

        return report
    }
}
